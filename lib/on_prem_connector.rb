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
require 'on_prem_url_generator'

Thread.abort_on_exception = true

class OnPremConnector
  include GlobalConfiguration
  include OnPremUrlGenerator
  include Logging
  using RbVmomiExtensions

  def initialize
    logger.info 'Initializing OnPrem Connector'
    @hyper_client = HyperClient.new
    @local_infrastructure_inventory = InfrastructureInventory.new(:name)
    @local_platform_remote_id_inventory = PlatformRemoteIdInventory.new
    @thread_pool = Concurrent::ThreadPoolExecutor.new(min_threads: 1,
                                                      max_threads: configuration[:on_prem_api_threads], # FIXME: - 1 this
                                                      max_queue: configuration[:on_prem_api_threads] + 1,
                                                      fallback_policy: :caller_runs)
  end

  def submit
    Mongoid::QueryCache.clear_cache # rethink if we start using this in other places
    submit_infrastructure_creates
    handle_machine_failed_creates # Failed creates result from TimeOut errors; This must be BEFORE submit_machine_creates
    submit_machine_creates
    submit_reading_creates
    submit_machine_disk_and_nic_deletes # Combined to go through documents with either or both changes once
    submit_machine_deletes
    sleep(1) # Needed so that the status changed to deleted doesnt give error 422
    submit_infrastructures_updates
    submit_machine_updates

      # Currently handles Disk/Nic updates too
      # block while thread pool finishes?
  rescue RestClient::TooManyRequests => e
    pause(Time.parse(e.response.headers[:x_rate_limit_reset]))
    retry
  rescue RestClient::ResourceNotFound => e # Pause and retry if API is down and something 404s
    pause(Time.now + 1.minute)
    retry
  rescue RuntimeError => e
    if (md = e.message.match(/No remote_id for machine: (.+)/))
      errored_machine = Machine.find(platform_id: md[1])
      submit_machine_creates([errored_machine])
    else
      raise e
    end
  end

  # Used by the registration process to update platform_remote_id with machine remote IDs (if they exist in OnPrem prior to meter registration)
  def initialize_platform_ids
    Infrastructure.enabled.each do |infrastructure|
      local_inventory = MachineInventory.new(infrastructure)
      on_prem_inventory = retrieve_machines(infrastructure) { |msg| yield msg if block_given? } # this is so the registration wizard can scroll names as they're retrieved, I think
      local_inventory.each do |platform_id, local_machine|
        next unless on_prem_inventory.key?(platform_id)
        # !! if the machine exists in OnPrem, we need to get its status set to something other than 'created', so we don't create it again
        #  updated is good because if there are changes locally, we'll still push them up
        #  However, this process needs to be batched, or more ideally, the OnPrem inventory should be pulled down and
        #  we compare and see what needs updating.
        #        yield local_machine if block_given?
        on_prem_machine = on_prem_inventory[local_machine.platform_id]
        yield "Syncing #{local_machine.name}" if block_given?

        unless @local_platform_remote_id_inventory["i:#{local_machine.infrastructure_platform_id}/m:#{local_machine.platform_id}"].present?
          # !! check equality first
          local_machine.update_attribute(:record_status, 'updated')

          @local_platform_remote_id_inventory["i:#{local_machine.infrastructure_platform_id}/m:#{local_machine.platform_id}"] =
              PlatformRemoteId.new(infrastructure: local_machine.infrastructure_platform_id,
                                   machine: local_machine.platform_id,
                                   remote_id: on_prem_machine.remote_id)
        end

        # Need to call #to_a on Mongoid collection to use find, otherwise doesn't work correctly
        # Need to map by name, only piece of info in OnPrem that can use to map with VSphere result
        local_machine.disks.each do |local_disk|
          next unless (remote_disk = on_prem_machine.disks.to_a.find { |md| md.name.eql?(local_disk.name) })
          disk_key = "i:#{local_machine.infrastructure_platform_id}/" \
                     "m:#{local_machine.platform_id}/" \
                     "d:#{local_disk.platform_id}"
          next if @local_platform_remote_id_inventory[disk_key].present?
          @local_platform_remote_id_inventory[disk_key] =
              PlatformRemoteId.new(infrastructure: local_machine.infrastructure_platform_id,
                                   machine: local_machine.platform_id,
                                   disk: local_disk.platform_id,
                                   remote_id: remote_disk.remote_id)
        end

        #  to call #to_a on Mongoid collection to use find, otherwise doesn't work correctly
        # Need to map by name, only piece of info in OnPrem that can use to map with VSphere result
        local_machine.nics.each do |local_nic|
          next unless (remote_nic = on_prem_machine.nics.to_a.find { |md| md.name.eql?(local_nic.name) })
          nic_key = "i:#{local_machine.infrastructure_platform_id}/" \
                    "m:#{local_machine.platform_id}/" \
                    "n:#{local_nic.platform_id}"
          next if @local_platform_remote_id_inventory[nic_key].present?
          @local_platform_remote_id_inventory[nic_key] =
              PlatformRemoteId.new(infrastructure: local_machine.infrastructure_platform_id,
                                   machine: local_machine.platform_id,
                                   nic: local_nic.platform_id,
                                   remote_id: remote_nic.remote_id)
        end
      end
    end

    @local_platform_remote_id_inventory.save
  end

  def submit_reading_creates
    queued = Reading.where(record_status: 'created').count
    if queued == 0
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
            # TODO: Not great having this in two places, but the alternative would be figure out the TODO below
            #   and shutting down / reinitalizing the threadpool here
            pause(Time.parse(e.response.headers[:x_rate_limit_reset]))
          rescue StandardError => e
            logger.error "Raising #{e.class}: #{e.message}"
            # TODO: This doesn't seem to operate as desired; this seems to cause a jump to the "line" after the end of the "thread_pool do" code
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
    if !infrastructure_creates.empty?
      logger.info "Processing #{infrastructure_creates.size} new infrastructures for submission to OnPrem"
    else
      logger.debug 'No new infrastructures to submit to OnPrem'
    end

    @local_infrastructure_inventory = InfrastructureInventory.new(:name)

    infrastructure_creates.each do |infrastructure|
      infrastructure = infrastructure.submit_create
      if infrastructure.remote_id
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
    if machine_exists?(mr)
      if machine_prid && infrastructure_prid
        begin
          mr.post_to_api(infrastructure_machine_readings_url(machine_prid.remote_id))
        rescue NoMethodError => e
          # This is a bit of cheat, but the only way to trigger a NoMethodError is if we call .remote_id on nil, which would
          #  indicate we have not created the corresponding disk or nic yet
          logger.info "Delaying submission of readings for machine #{mr.id[:machine_platform_id]} " \
                      'until corresponding OnPrem machine disk and NIC resources have been created'
          logger.debug e.message
        end
      else
        logger.info "Delaying submission of readings for machine #{mr.id[:machine_platform_id]} "\
                    "until corresponding OnPrem infrastructure #{machine_prid ? '' : 'and machine '}resources have been created"
      end
    else
      mr.update_readings_status('machine_deleted')
      logger.info "Machine with platform_id #{mr.id[:machine_platform_id]} has been deleted, so its readings are not going to be submitted to OnPrem"
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
    if !machine_creates.empty?
      logger.info "Processing #{machine_creates.size} new machines for submission to OnPrem"
    else
      logger.debug 'No new machines to submit to OnPrem'
    end

    machine_creates.each do |created_machine|
      begin
        infrastructure_prid = @local_platform_remote_id_inventory["i:#{created_machine.infrastructure_platform_id}"]

        if infrastructure_prid

          if @local_platform_remote_id_inventory.key?("i:#{created_machine.infrastructure_platform_id}/m:#{created_machine.platform_id}")
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
                      'to OnPrem API until parent infrastructure has been submitted'

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
    if !machine_failed_creates.empty?
      logger.info "Processing #{machine_failed_creates.size} machines that did not successfully get created in OnPrem"
    else
      logger.debug 'No machines creation failures to process'
    end

    begin
      machine_failed_creates.each do |m_f_c|
        infrastructure_prid = @local_platform_remote_id_inventory["i:#{m_f_c.infrastructure_platform_id}"]

        if infrastructure_prid.nil?
          logger.debug "Cannot handle_machine_failed_create for #{m_f_c.platform_id}. No prid because infrastructure_platform_id is nil"
          next
        end

        # Machines are unique by platform_id/virtual_name scoped to Infrastructure
        submit_url = infrastructure_machines_url(infrastructure_id: infrastructure_prid.remote_id)

        if m_f_c.already_submitted?(submit_url)
          m_f_c.update_attribute(:record_status, 'verified_create') # checks OnPrem using virtual_name
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
    if !machine_deletes.empty?
      logger.info "Processing #{machine_deletes.size} machines that require deletion from OnPrem"
    else
      logger.debug 'No machines require deletion from OnPrem'
    end

    machine_deletes.each do |deleted_machine|
      submit_url = machine_url(deleted_machine)
      deleted_machine.submit_delete(submit_url)

      if deleted_machine.record_status == 'deleted'
        deleted_machine.save # Update status in mongo
      else
        logger.error "Error deleting machine: Database ID:#{deleted_machine.id}, Platform ID:#{deleted_machine.platform_id}"
      end
    end
  end

  def submit_machine_updates
    if InventoriedTimestamp.most_recent
      updated_machines = Machine.to_be_updated # (latest_inventory.inventory_at)
      if !updated_machines.empty?
        logger.info "Processing #{updated_machines.size} machines that have configuration updates for OnPrem"
      else
        logger.debug 'No machines require updating in OnPrem'
      end

      updated_machines.each do |updated_machine|
        begin
          updated_machine = inject_machine_disk_nic_remote_ids(updated_machine)
          logger.debug "Updated machine #{updated_machine.inspect} \n"
          submit_url = machine_url(updated_machine)
          submitted_machine = updated_machine.submit_update(submit_url)
          api_machine = retrieve_api_machine(updated_machine)
          verify_and_submit_nics_updates(submitted_machine, api_machine)
          verify_and_submit_disks_updates(submitted_machine, api_machine)
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

  def submit_infrastructures_updates
    if InventoriedTimestamp.most_recent
      updated_infrastructures = Infrastructure.where(record_status: 'updated') # (latest_inventory.inventory_at)
      if !updated_infrastructures.empty?
        logger.info "Processing #{updated_infrastructures.size} infrastructures that have configuration updates for OnPrem"
      else
        logger.debug 'No infrastructures require updating in OnPrem'
      end
      updated_infrastructures.each do |updated_infrastructure|
        begin
          submitted_infrastructure = updated_infrastructure.submit_update
          # Note: Successfully updated infrastructures record_status changes from "updated" to "verified_update"
          if submitted_infrastructure.record_status == 'verified_update'
            submitted_infrastructure.save # Save status in mongo
          else
            logger.error "Infrastructure #{submitted_infrastructure.name}/#{submitted_infrastructure.platform_id} not updated."
          end
        rescue RestClient::TooManyRequests => e
          raise e
        rescue StandardError => e
          logger.debug e.backtrace.join("\n")
          logger.error "Error updating infrastructure: #{e.message}"
        end
      end
    end
  end

  # Control function, submit disks/nics
  # Finds documents with nics or disks that need to be deleted, then calls specific delete functions
  def submit_machine_disk_and_nic_deletes
    machines_with_disk_or_nic_deletes = Machine.disks_or_nics_to_be_deleted
    machines_with_disk_or_nic_deletes.each do |machine|
      disk_deletes = machine.disks.select { |d| 'to_be_deleted' == d.record_status }
      nic_deletes = machine.nics.select { |n| 'to_be_deleted' == n.record_status }

      disk_deletes.each do |ddel|
        submit_machine_disk_delete(ddel)
      end

      nic_deletes.each do |ndel|
        submit_machine_nic_delete(ndel)
      end
    end
  end

  def submit_machine_disk_delete(disk)
    logger.debug 'Processing disk that require OnPrem deletion'

    submit_url = disk_url(disk)
    deleted_disk = disk.submit_delete(submit_url)
    if deleted_disk.record_status == 'verified_delete' || deleted_disk.record_status == 'unverified_delete'
      deleted_disk.save # Update status in mongo
      disk_machine = disk.machine
      disk_prid = @local_platform_remote_id_inventory["i:#{disk_machine.infrastructure_platform_id}/m:#{disk_machine.platform_id}/d:#{disk.platform_id}"]
      disk_prid.delete if disk_prid
      @local_platform_remote_id_inventory = PlatformRemoteIdInventory.new
    else
      logger.error "Error deleting disk: platform_id = #{disk.platform_id}, mongo _id = #{disk.id}, submit_url = #{submit_url}"
    end
  end

  def submit_machine_nic_delete(nic)
    logger.debug 'Processing nic that require OnPrem deletion'

    submit_url = nic_url(nic)
    deleted_nic = nic.submit_delete(submit_url)
    if deleted_nic.record_status == 'verified_delete' || deleted_nic.record_status == 'unverified_delete'
      deleted_nic.save # Update status in mongo
      nic_machine = nic.machine
      nic_prid = @local_platform_remote_id_inventory["i:#{nic_machine.infrastructure_platform_id}/m:#{nic_machine.platform_id}/n:#{nic.platform_id}"]
      nic_prid.delete if nic_prid
      @local_platform_remote_id_inventory = PlatformRemoteIdInventory.new
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

    if @local_platform_remote_id_inventory.key?(machine_prid.platform_key)
      unless @local_platform_remote_id_inventory[machine_prid.platform_key].remote_id == machine.remote_id
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
      next unless disk.remote_id
      disk_prid = PlatformRemoteId.new(remote_id: disk.remote_id,
                                       infrastructure: machine.infrastructure_platform_id,
                                       machine: machine.platform_id,
                                       disk: disk.platform_id)

      if @local_platform_remote_id_inventory.key?(disk_prid.platform_key)
        unless @local_platform_remote_id_inventory[disk_prid.platform_key].remote_id == disk.remote_id
          disk_prid.save
          @local_platform_remote_id_inventory[disk_prid.platform_key] = disk_prid
        end
      else
        disk_prid.save
        @local_platform_remote_id_inventory[disk_prid.platform_key] = disk_prid
      end
    end
  end

  def add_machine_nics_prids(machine)
    machine.nics.each do |nic|
      next unless nic.remote_id
      nic_prid = PlatformRemoteId.new(remote_id: nic.remote_id,
                                      infrastructure: machine.infrastructure_platform_id,
                                      machine: machine.platform_id,
                                      nic: nic.platform_id)

      if @local_platform_remote_id_inventory.key?(nic_prid.platform_key)
        unless @local_platform_remote_id_inventory[nic_prid.platform_key].remote_id == nic.remote_id
          nic_prid.save
          @local_platform_remote_id_inventory[nic_prid.platform_key] = nic_prid
        end
      else
        nic_prid.save
        @local_platform_remote_id_inventory[nic_prid.platform_key] = nic_prid
      end
    end
  end

  def retrieve_machines(infrastructure)
    machines_by_platform_id = {}
    machines_json = @hyper_client.get_all_resources(infrastructure_machines_url(infrastructure_id: infrastructure.remote_id))
    machines_json.each do |json|
      remote_id = json['id']
      response = @hyper_client.get(retrieve_machine(remote_id))
      next unless response.code == 200
      machine_json = JSON.parse(response)
      machine = Machine.new(remote_id: machine_json['id'],
                            name: machine_json['name'],
                            virtual_name: machine_json['custom_id'],
                            cpu_count: machine_json['cpu_count'],
                            cpu_speed_hz: machine_json['cpu_speed_hz'],
                            memory_bytes: machine_json['memory_bytes'],
                            status: machine_json['status'])
      yield "Retrieved #{machine.name}" if block_given?
      disks_json = machine_json['embedded']['disks']
      machine.disks = disks_json.map { |dj|
        Disk.new(remote_id: dj['id'],
                 name: dj['name'],
                 platform_id: dj['uuid'],
                 type: 'Disk',
                 size: dj['storage_bytes'])
      }

      nics_json = machine_json['embedded']['nics']
      machine.nics = nics_json.map { |nj|
        Nic.new(remote_id: nj['id'],
                name: nj['name'],
                kind: nj['kind'].eql?(0) ? 'lan' : 'wan',
                ip_address: nj['ip_address'],
                mac_address: nj['mac_address'])
      }

      machines_by_platform_id[machine_json['custom_id']] = machine # CHECK if this is uniq
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
            cpu_speed_hz: m['cpu_speed_hz'],
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

    if reset_time
      sleepy_time = (reset_time - Time.now).to_i
      if sleepy_time > 0 # pretty unlikely for this to be false
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

  def verify_and_submit_nics_updates(updated_machine, _api_machine)
    to_be_created = (updated_machine.nics.map &:api_format).select { |n| n[:id].nil? && n[:name].present? }
    create_nics(to_be_created, updated_machine) if to_be_created.present?
  end

  def create_nics(nics, machine)
    submit_url = machine_nics_url(machine.remote_id)
    nics.each do |nic|
      response = @hyper_client.post(submit_url, nic)
      if response && response.code == 200
        current_nic = machine.nics.select { |n| n if n.name == nic[:name] }.first
        current_nic.update_attributes(remote_id: response.json['id'], record_status: 'verified_create')
        logger.debug "Successfully created nic #{nic[:name]} for machine #{machine.name}"
      else
        machine.update_attributtes(record_status: 'updated')
        logger.error "Couldn't create nic #{nic[:name]} for machine #{machine.name}"
      end
    end
  end

  def verify_and_submit_disks_updates(updated_machine, api_machine)
    local_disks = (updated_machine.disks.map &:api_format).select { |n| n if n[:name].present? }
    remote_disks = api_machine['embedded']['disks'].map { |d| {id: d['id'], name: d['name'], storage_bytes: d['storage_bytes'], kind: 'disk'} }
    local_disks_ids = local_disks.map { |n| n[:id] if !n[:name].nil? && n[:id].present? }.compact
    remote_disks_ids = remote_disks.map { |n| n[:id] }
    to_be_created = (updated_machine.disks.map &:api_format).select { |n| n[:id].nil? && n[:name].present? }
    create_disks(to_be_created, updated_machine) if to_be_created.present?
    if local_disks_ids.sort == remote_disks_ids.sort
      disks_to_update = (local_disks - remote_disks).select { |n| n if n[:id].present? }
      update_disks(disks_to_update, updated_machine)
    end
  end

  def update_disks(disks, machine)
    disks.each do |disk|
      update_url = disk_url_for(disk[:id])
      response = @hyper_client.put(update_url, disk)
      if response.code == 200
        logger.debug "Successfully updated disk #{disk[:name]} for machine #{machine.name}"
      else
        machine.update_attributes(record_status: 'updated')
        logger.error "Couldn't update disk #{disk[:name]} for machine #{machine.name}"
      end
    end
  end

  def create_disks(disks, machine)
    submit_url = machine_disks_url(machine.remote_id)
    disks.each do |disk|
      response = @hyper_client.post(submit_url, disk)
      if response && response.code == 200
        current_disk = machine.disks.select { |d| d if d.name == disk[:name] }.first
        current_disk.update_attributes(remote_id: response.json['id'], record_status: 'verified_create')
        logger.debug "Successfully created disk #{disk[:name]} for machine #{machine.name}"
      else
        machine.update_attributtes(record_status: 'updated')
        logger.error "Couldn't create disk #{disk[:name]} for machine #{machine.name}"
      end
    end
  end

  def retrieve_api_machine(updated_machine)
    api_machine = @hyper_client.get(machine_url(updated_machine))
    api_machine.json if api_machine && api_machine.code == 200
  end

  def machine_exists?(machine_reading)
    machine_platform_id = machine_reading.id[:machine_platform_id]
    deleted_machines = Machine.where(record_status: 'deleted').map &:platform_id
    !deleted_machines.include?(machine_platform_id)
  end
end
