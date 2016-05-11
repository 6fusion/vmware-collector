require 'global_configuration'
require 'hyper_client'
require 'infrastructure'
require 'inventoried_timestamp'
require 'logging'
require 'local_inventory'
require 'machine_reading'
require 'platform_remote_id'
require 'rbvmomi_extensions'
require 'reading'
require 'uri_enhancements'
require 'uc6_url_generator'

# Initialize Data UC6 -> Local Mongo
  # logger.info 'Initializing infrastructures data'
  # load_infrastructure_data

  # logger.info 'Initializing machines data'
  # load_machines_data

Thread.abort_on_exception = true

class UC6Connector
  include GlobalConfiguration
  include UC6UrlGenerator
  include Logging
  using RbVmomiExtensions

  def initialize
    logger.info 'Initializing UC6 Connector'
    @hyper_client = HyperClient.new
    @local_infrastructure_inventory = InfrastructureInventory.new(:name)
    @local_platform_remote_id_inventory = PlatformRemoteIdInventory.new
    @thread_pool = Concurrent::ThreadPoolExecutor.new(min_threads: 1,
                                                      max_threads: configuration[:uc6_api_threads],  # FIXME - 1 this
                                                      max_queue: configuration[:uc6_api_threads] + 1,
                                                      fallback_policy: :caller_runs)
  end

  def submit
    begin
      Mongoid::QueryCache.clear_cache  # rethink if we start using this in other places
      submit_infrastructure_creates
      handle_machine_failed_creates # Failed creates result from TimeOut errors; This must be BEFORE submit_machine_creates
      submit_machine_creates
      submit_reading_creates
      submit_machine_deletes
      submit_machine_updates # Currently handles Disk/Nic updates too
      submit_machine_disk_and_nic_deletes # Combined to go through documents with either or both changes once
      # block while thread pool finishes?
    rescue RestClient::TooManyRequests => e
      pause(Time.parse(e.response.headers[:x_rate_limit_reset]))
      retry
    rescue RestClient::ResourceNotFound => e  # Pause and retry if API is down and something 404s
      pause(Time.now + 1.minute)
      retry
    rescue RuntimeError => e
      if ( md = e.message.match(/No remote_id for machine: (.+)/) )
        errored_machine = Machine.find(platform_id: md[1])
        submit_machine_creates([errored_machine])
      else
        raise e
      end
    end
  end

  # Used by the registration process to update platform_remote_id with machine remote IDs (if they exist in UC6 prior to meter registration)
  def initialize_platform_ids
    Infrastructure.enabled.each do |infrastructure|
      local_inventory = MachineInventory.new(infrastructure)
      uc6_inventory = retrieve_machines(infrastructure){|msg| yield msg if block_given? } #this is so the registration wizard can scroll names as they're retrieved, I think
      local_inventory.each do |platform_id, local_machine|
        if ( uc6_inventory.has_key?(platform_id) )
          #!! if the machine exists in UC6, we need to get its status set to something other than 'created', so we don't create it again
          #  updated is good because if there are changes locally, we'll still push them up
          #  However, this process needs to be batched, or more ideally, the UC6 inventory should be pulled down and
          #  we compare and see what needs updating.
          #        yield local_machine if block_given?
          uc6_machine = uc6_inventory[local_machine.platform_id]
          yield "Syncing #{local_machine.name}" if block_given?

          unless ( @local_platform_remote_id_inventory["i:#{local_machine.infrastructure_platform_id}/m:#{local_machine.platform_id}"].present? )
            #!! check equality first
            local_machine.update_attribute(:record_status, 'updated')

            @local_platform_remote_id_inventory["i:#{local_machine.infrastructure_platform_id}/m:#{local_machine.platform_id}"] =
              PlatformRemoteId.new(infrastructure: local_machine.infrastructure_platform_id,
                                   machine: local_machine.platform_id,
                                   remote_id: uc6_machine.remote_id )
          end

          # Need to call #to_a on Mongoid collection to use find, otherwise doesn't work correctly
          # Need to map by name, only piece of info in UC6 that can use to map with VSphere result
          local_machine.disks.each do |local_disk|
            if ( remote_disk = uc6_machine.disks.to_a.find{|md| md.name.eql?(local_disk.name)} )
              disk_key = "i:#{local_machine.infrastructure_platform_id}/" \
                         "m:#{local_machine.platform_id}/" \
                         "d:#{local_disk.platform_id}"
              unless ( @local_platform_remote_id_inventory[disk_key].present? )
                @local_platform_remote_id_inventory[disk_key] =
                  PlatformRemoteId.new(infrastructure: local_machine.infrastructure_platform_id,
                                       machine: local_machine.platform_id,
                                       disk: local_disk.platform_id,
                                       remote_id: remote_disk.remote_id)
              end
            end
          end

          #  to call #to_a on Mongoid collection to use find, otherwise doesn't work correctly
          # Need to map by name, only piece of info in UC6 that can use to map with VSphere result
          local_machine.nics.each do |local_nic|
            if ( remote_nic = uc6_machine.nics.to_a.find{|md| md.name.eql?(local_nic.name)} )
              nic_key = "i:#{local_machine.infrastructure_platform_id}/" \
                        "m:#{local_machine.platform_id}/" \
                        "n:#{local_nic.platform_id}"
              unless ( @local_platform_remote_id_inventory[nic_key].present? )
                @local_platform_remote_id_inventory[nic_key] =
                  PlatformRemoteId.new(infrastructure: local_machine.infrastructure_platform_id,
                                       machine: local_machine.platform_id,
                                       nic: local_nic.platform_id,
                                       remote_id: remote_nic.remote_id)
              end
            end
          end
        end
      end
    end

    @local_platform_remote_id_inventory.save
  end

  def submit_reading_creates
    queued = Reading.where(record_status: 'created').count
    if ( queued == 0 )
      logger.debug 'No readings queued for submission'
    else
      logger.info "Preparing to submit #{queued} readings"

      start = Time.now
      # !! consider making this step one in a separate thread?
      Reading.group_for_submission

      MachineReading.no_timeout.each do |mr|
        @thread_pool.post do
          Thread.current.abort_on_exception = true
          # In spite of the abort_on_exception above, a begin/rescue wrapper seems to be necessary to get
          #  exceptions percolated outside of the thead pool into the main thread
          begin
            prep_and_post_reading(mr)
          rescue RestClient::TooManyRequests => e
            # TODO Not great having this in two places, but the alternative would be figure out the TODO below
            #   and shutting down / reinitalizing the threadpool here
            pause(Time.parse(e.response.headers[:x_rate_limit_reset]))
          rescue StandardError => e
            logger.error "Raising #{e.class}: #{e.message}"
            # TODO This doesn't seem to operate as desired; this seems to cause a jump to the "line" after the end of the "thread_pool do" code
            #  Exception handling in the main function doesn't seem to execute right away either; not till the end of machinereading.each
            Thread.main.raise e
          end
        end
      end

      logger.info "Completed submission of readings in #{Time.now - start} seconds"
    end

  end

  def submit_infrastructure_creates
    infrastructure_creates = Infrastructure.where(record_status: 'created')
    if ( infrastructure_creates.size > 0 )
      logger.info "Processing #{infrastructure_creates.size} new infrastructures for submission to UC6"
    else
      logger.debug 'No new infrastructures to submit to UC6'
    end

    @local_infrastructure_inventory = InfrastructureInventory.new(:name)

    infrastructure_creates.each do |infrastructure|
      infrastructure = infrastructure.submit_create
      if (infrastructure.remote_id)
        @local_platform_remote_id_inventory["i:#{infrastructure.platform_id}"] = PlatformRemoteId.new(infrastructure: infrastructure.platform_id,
                                                                                                      remote_id: infrastructure.remote_id)

        @local_infrastructure_inventory[infrastructure.name] = infrastructure
      else
        logger.error "No remote id returned for #{infrastructure.name}"
      end
    end
    # Batch save local inventories
    @local_infrastructure_inventory.save
    @local_platform_remote_id_inventory.save

  end

  private

  def prep_and_post_reading(machine_reading)
    mr = machine_reading
    infrastructure_prid = @local_platform_remote_id_inventory["i:#{mr.id[:infrastructure_platform_id]}"]
    machine_prid = @local_platform_remote_id_inventory["#{infrastructure_prid.platform_key}/m:#{mr.id[:machine_platform_id]}"]
    if ( machine_prid and infrastructure_prid )
      begin
        mr.readings.each do |reading|
          reading[:disk_metrics].each {|dm| #inject?
            dm[:remote_id] = @local_platform_remote_id_inventory["#{machine_prid.platform_key}/d:#{dm['platform_id']}"].remote_id } if reading[:disk_metrics].present?
          reading[:nic_metrics].each {|nm| #inject?
            nm[:remote_id] = @local_platform_remote_id_inventory["#{machine_prid.platform_key}/n:#{nm['platform_id']}"].remote_id } if reading[:nic_metrics].present?
        end
        mr.post_to_api(infrastructure_machine_readings_url(infrastructure_prid.remote_id,machine_prid.remote_id))
      rescue NoMethodError => e
        # This is a bit of cheat, but the only way to trigger a NoMethodError is if we call .remote_id on nil, which would
        #  indicate we have not created the corresponding disk or nic yet
        logger.info "Delaying submission of readings for machine #{mr.id[:machine_platform_id]} " \
                    "until corresponding UC6 machine disk and NIC resources have been created"
        logger.debug e.message
      end

    else
      logger.info "Delaying submission of readings for machine #{mr.id[:machine_platform_id]} "\
                  "until corresponding UC6 infrastructure #{machine_prid ? '' : 'and machine '}resources have been created"
    end

  end

  def load_infrastructure_data
    all_infrastructure_json = @hyper_client.get_all_resources(infrastructures_url)

    all_infrastructure_json.each do |json_batch|
      infrastructures = json_batch['embedded']['infrastructures']
      infrastructures.each do |inf|
        @local_infrastructure_inventory[inf['name']] = Infrastructure.new(name: inf['name'])
      end
    end
    @local_infrastructure_inventory.save
  end

  def submit_machine_creates(machine_creates = Machine.to_be_created)
    if ( machine_creates.size > 0 )
      logger.info "Processing #{machine_creates.size} new machines for submission to UC6"
    else
      logger.debug 'No new machines to submit to UC6'
    end

    machine_creates.each do |created_machine|
      begin
        infrastructure_prid = @local_platform_remote_id_inventory["i:#{created_machine.infrastructure_platform_id}"]

        if infrastructure_prid

          if ( @local_platform_remote_id_inventory.has_key?("i:#{created_machine.infrastructure_platform_id}/m:#{created_machine.platform_id}") )
            # in main loop, creates happen before updates, so this should get picked up immediately after all creates have been submitted
            created_machine.update_attribute(:record_status, 'updated')
            next
          end
          created_machine.submit_create

          if created_machine.record_status == 'verified_create'
            created_machine.save # Update status in mongo
            process_verified_machine_prids(created_machine)
          else
            logger.warn "Failed to create machine: #{created_machine.infrastructure_platform_id}:#{created_machine.name} (#{created_machine.record_status})"
          end
        else
          logger.info "Delaying submission of machine '#{created_machine.platform_id}' "\
                      "to UC6 API until parent infrastructure has been submitted"

        end
      rescue StandardError => e
        logger.error "Error creating machine: #{e.message}"
        logger.debug e
        raise e
      end
    end
    #    @local_platform_remote_id_inventory.save
  end

  def handle_machine_failed_creates
    machine_failed_creates = Machine.failed_creates.to_a
    if ( machine_failed_creates.size > 0 )
      logger.info "Processing #{machine_failed_creates.size} machines that did not successfully get created in UC6"
    else
      logger.debug 'No machines creation failures to process'
    end

    begin
      machine_failed_creates.each do |m_f_c|
        infrastructure_prid = @local_platform_remote_id_inventory["i:#{m_f_c.infrastructure_platform_id}"]

        if ( infrastructure_prid.nil? )
          logger.debug "Cannot handle_machine_failed_create for #{m_f_c.platform_id}. No prid because infrastructure_platform_id is nil"
          next
        end

        # Machines are unique by platform_id/virtual_name scoped to Infrastructure
        submit_url = infrastructure_machines_url(infrastructure_id: infrastructure_prid.remote_id)

        if m_f_c.already_submitted?(submit_url)
          m_f_c.update_attribute(:record_status, 'verified_create') # checks UC6 using virtual_name
          process_verified_machine_prids(m_f_c)
        else
          # If not already_submitted?, then mark as created so gets submitted as create next time around
          m_f_c.update_attribute(:record_status, 'created')
        end
      end
    rescue StandardError => e
      logger.error "Error handling machine failed_create: #{e.message}"
      logger.debug e
      raise e
    end
  end

  def submit_machine_deletes
    machine_deletes = Machine.to_be_deleted
    if ( machine_deletes.size > 0 )
      logger.info "Processing #{machine_deletes.size} machines that require deletion from UC6"
    else
      logger.debug 'No machines require deletion from UC6'
    end

    machine_deletes.each do |deleted_machine|
      submit_url = machine_url(deleted_machine)

      deleted_machine.submit_delete(submit_url)

      if deleted_machine.record_status == 'deleted'
        deleted_machine.save # Update status in mongo
      else
        logger.error "Error deleting machine: Database ID:#{submitted_machine.id}, Platform ID:#{submitted_machine.platform_id}"
      end
    end
  end

  def submit_machine_updates
    if ( InventoriedTimestamp.most_recent )
      updated_machines = Machine.to_be_updated #(latest_inventory.inventory_at)
      if ( updated_machines.size > 0 )
        logger.info "Processing #{updated_machines.size} machines that have configuration updates for UC6"
      else
        logger.debug 'No machines require updating in UC6'
      end

      updated_machines.each do |updated_machine|
        begin
          logger.debug "Before inject_machine_disk_nic_remote_ids \n\n"
          updated_machine = inject_machine_disk_nic_remote_ids(updated_machine)
          logger.debug "Updated machine #{updated_machine.inspect} \n"
          submit_url = machine_url(updated_machine) 
          submitted_machine = updated_machine.submit_update(submit_url)

          logger.debug "submitted_machine.record_status => #{submitted_machine.record_status} \n\n"
          # Note: Successfully updated machines record_status changes from "updated" to "verified_update"
          if submitted_machine.record_status == 'verified_update'
            submitted_machine.save # Save status in mongo
            process_verified_machine_prids(submitted_machine)
          else
            logger.error "Machine #{submitted_machine.name}/#{submitted_machine.platform_id} not updated."
          end
        rescue RestClient::TooManyRequests => e
          raise e
        rescue StandardError => e
          logger.debug e.backtrace.join("\n")
          logger.error "Error updating machine: #{e.message}"
        ensure
          # @local_platform_remote_id_inventory.save
        end
      end
    end
  end

  # Control function, submit disks/nics
  # Finds documents with nics or disks that need to be deleted, then calls specific delete functions
  def submit_machine_disk_and_nic_deletes
    machines_with_disk_or_nic_deletes = Machine.disks_or_nics_to_be_deleted

    machines_with_disk_or_nic_deletes.each do |machine|
      disk_deletes = machine.disks.select{|d| 'to_be_deleted' == d.record_status}
      nic_deletes = machine.nics.select{|n| 'to_be_deleted' == n.record_status}

      disk_deletes.each do |ddel|
        submit_machine_disk_delete(ddel)
      end

      nic_deletes.each do |ndel|
        submit_machine_nic_delete(ndel)
      end
    end
  end

  def submit_machine_disk_delete(disk)
    logger.debug "Processing disk that require UC6 deletion"

    submit_url = disk_url(disk)
    deleted_disk = disk.submit_delete(submit_url)

    if deleted_disk.record_status == 'verified_delete' || deleted_disk.record_status == 'unverified_delete'
      deleted_disk.save # Update status in mongo
    else
      logger.error "Error deleting disk: platform_id = #{disk.platform_id}, mongo _id = #{disk.id}, submit_url = #{submit_url}"
    end
  end

  def submit_machine_nic_delete(nic)
    logger.debug "Processing nic that require UC6 deletion"

    submit_url = nic_url(nic)
    deleted_nic= nic.submit_delete(submit_url)

    if deleted_nic.record_status == 'verified_delete' || deleted_nic.record_status == 'unverified_delete'
      deleted_nic.save # Update status in mongo
    else
      logger.error "Error deleting NIC: platform_id = #{nic.platform_id}, platform _id = #{nic.id}, submit_url = #{submit_url}"
    end
  end

  def inject_machine_disk_nic_remote_ids(machine)
    inject_machine_remote_id(machine)
    inject_machine_disks_remote_ids(machine)
    inject_machine_nics_remote_ids(machine)

    machine
  end

  def inject_machine_remote_id(machine)
    machine_platform_key = "i:#{machine.infrastructure_platform_id}/m:#{machine.platform_id}"

    unless machine.remote_id
      machine_prid = @local_platform_remote_id_inventory[machine_platform_key]
      logger.info "MACHINE PRID => #{machine_prid}\n\n"
      if machine_prid
        machine_remote_id = machine_prid.remote_id
        if !machine_remote_id
          logger.error "No remote_id for '#{machine.platform_id}' in @local_platform_remote_id_inventory"
        else
          machine.remote_id = machine_remote_id
        end
      else
        logger.error "No PRID for Machine #{machine.platform_id}" unless machine.record_status == 'created'
      end
    end

    machine
  end

  def inject_machine_disks_remote_ids(machine)
    machine_platform_key = "i:#{machine.infrastructure_platform_id}/m:#{machine.platform_id}"

    machine.disks.each do |d|
      next if d.remote_id
      unless d.platform_id
        logger.error "Disk has no platform_id for Machine #{machine.platform_id}"
        next
      end

      disk_platform_key = machine_platform_key + "/d:#{d.platform_id}"
      disk_prid = @local_platform_remote_id_inventory[disk_platform_key]
      logger.info "DISC PRID => #{disk_prid}\n\n"
      if disk_prid
        disk_remote_id = disk_prid.remote_id
        if !disk_remote_id
          logger.error "No disk.remote_id for Disk #{d.platform_id} for Machine #{machine.platform_id}"
        else
          d.remote_id = disk_remote_id
        end
      else
        # !!! Not sure whetehr to add record_status to disks
        logger.debug "No PRID for Disk #{d.platform_id} for Machine #{machine.platform_id}" # unless d.record_status == 'created'
      end
    end

    machine
  end

  def inject_machine_nics_remote_ids(machine)
    machine_platform_key = "i:#{machine.infrastructure_platform_id}/m:#{machine.platform_id}"

    machine.nics.each do |n|
      next if n.remote_id
      unless n.platform_id
        logger.error "Nic has no platform_id for Machine #{machine.platform_id}"
        next
      end

      nic_platform_key = machine_platform_key + "/n:#{n.platform_id}"
      nic_prid = @local_platform_remote_id_inventory[nic_platform_key]
      logger.info "NIC PRID => #{nic_prid}\n\n"
      if nic_prid
        nic_remote_id = nic_prid.remote_id
        if !nic_remote_id
          logger.error "No nic_remote_id for Nic #{n.platform_id} for Machine #{machine.platform_id}"
        else
          n.remote_id = nic_remote_id
        end
      else
        # !!! Not sure whether to add record_status to nics
        logger.debug "No PRID for Nic #{n.platform_id} for Machine #{machine.platform_id}" # unless n.record_status == 'created'
      end
    end

    machine
  end

  # Note: prid = platform remote id
  def process_verified_machine_prids(verified_machine)
    add_machine_prid(verified_machine)
    add_machine_disks_prids(verified_machine)
    add_machine_nics_prids(verified_machine)
  end

  def add_machine_prid(machine)
    raise "Machine '#{machine.platform_id}' does not have a remote_id" if machine.remote_id.nil?

    machine_prid = PlatformRemoteId.new(remote_id: machine.remote_id,
                                        infrastructure: machine.infrastructure_platform_id,
                                        machine: machine.platform_id)


    if ( @local_platform_remote_id_inventory.has_key?(machine_prid.platform_key) )
      unless ( @local_platform_remote_id_inventory[machine_prid.platform_key].remote_id == machine.remote_id )
        machine_prid.save
        @local_platform_remote_id_inventory[machine_prid.platform_key] = machine_prid
      end
    else
      machine_prid.save
      @local_platform_remote_id_inventory[machine_prid.platform_key] = machine_prid
    end

  end

  def add_machine_disks_prids(machine)
    machine.disks.each do |disk|
      if disk.remote_id
        disk_prid = PlatformRemoteId.new(remote_id: disk.remote_id,
                                         infrastructure: machine.infrastructure_platform_id,
                                         machine: machine.platform_id,
                                         disk: disk.platform_id)

        if ( @local_platform_remote_id_inventory.has_key?(disk_prid.platform_key) )
          unless ( @local_platform_remote_id_inventory[disk_prid.platform_key].remote_id == disk.remote_id )
            disk_prid.save
            @local_platform_remote_id_inventory[disk_prid.platform_key] = disk_prid
          end
        else
          disk_prid.save
          @local_platform_remote_id_inventory[disk_prid.platform_key] = disk_prid
        end
      end
    end
  end

  def add_machine_nics_prids(machine)
    machine.nics.each do |nic|
      if nic.remote_id
        nic_prid = PlatformRemoteId.new(remote_id: nic.remote_id,
                                        infrastructure: machine.infrastructure_platform_id,
                                        machine: machine.platform_id,
                                        nic: nic.platform_id)

        if ( @local_platform_remote_id_inventory.has_key?(nic_prid.platform_key) )
          unless ( @local_platform_remote_id_inventory[nic_prid.platform_key].remote_id == nic.remote_id )
            nic_prid.save
            @local_platform_remote_id_inventory[nic_prid.platform_key] = nic_prid
          end
        else
          nic_prid.save
          @local_platform_remote_id_inventory[nic_prid.platform_key] = nic_prid
        end
      end
    end
  end

  def retrieve_machines(infrastructure)
    machines_by_platform_id = Hash.new
    machines_json = @hyper_client.get_all_resources(infrastructure_machines_url(infrastructure_id: infrastructure.remote_id))
    machines_json.each do |json|
      remote_id = json['id']
      response = @hyper_client.get(retrieve_machine(remote_id))
      if ( response.code == 200 )
        machine_json = JSON.parse(response)
        machine = Machine.new(remote_id:     machine_json['id'],
                              name:          machine_json['name'],
                              virtual_name:  machine_json['custom_id'],
                              cpu_count:     machine_json['cpu_count'],
                              cpu_speed_mhz: machine_json['cpu_speed_hz'],
                              memory_bytes:  machine_json['memory_bytes'],
                              status:        machine_json['status'])
        yield "Retrieved #{machine.name}" if block_given?
        disks_json = machine_json['embedded']['disks']
        machine.disks = disks_json.map{|dj| Disk.new(remote_id: dj['id'],
                                                     name: dj['name'],
                                                     platform_id: dj['uuid'],
                                                     type: 'Disk',
                                                     size: dj['storage_bytes']) }

        nics_json = machine_json['embedded']['nics']
        machine.nics = nics_json.map{|nj| Nic.new(remote_id: nj['id'],
                                                  name: nj['name'],
                                                  kind: nj['kind'].eql?(0) ? 'lan' : 'wan',
                                                  ip_address: nj['ip_address'],
                                                  mac_address: nj['mac_address'])}

        machines_by_platform_id[machine_json['custom_id']] = machine #CHECK if this is uniq
      else
        #!!
      end
    end
    logger.debug "machines_by_platform_id = > #{machines_by_platform_id.inspect} \n\n"
    machines_by_platform_id
  end


  def load_machines_data
    all_machines_json = @hyper_client.get_all_resoures(machines_url)

    machines_to_save = []

    all_machines_json.each do |json_batch|
      machines = json_batch['embedded']['machines']

      machines_to_save << machines.map do |m|
        properties = {
          remote_id: m['remote_id'],
          name: m['name'],
          virtual_name: m['custom_id'],
          cpu_count: m['cpu_count'],
          cpu_speed_mhz: m['cpu_speed_mhz'],
          memory_bytes: m['memory_bytes'],
          status: m['status']
        }
        Machine.new(properties)
      end
    end

    Machine.collection.insert(machines_to_save.flatten.map(&:as_document))
    # !!! This won't work without MoRef
    # @local_machine_inventory['<MoRef>'] = Machine.new(properties)
    # @local_machine_inventory.save
  end

  def pause(reset_time)
    logger.warn 'API request limit reached'

    if ( reset_time )
      sleepy_time = (reset_time - Time.now).to_i
      if ( sleepy_time > 0 ) # pretty unlikely for this to be false
        logger.info "Waiting #{sleepy_time} seconds before reattempting API submissions"
        sleep(sleepy_time)
      else
        logger.warn "Received a rate_limit_reset in the past #{reset_time}. Waiting 60 seconds instead"
        sleep(60)
      end
    else
      sleep(60)
    end
  end

end
