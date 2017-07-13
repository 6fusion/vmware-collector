require 'global_configuration'
require 'hyper_client'
require 'infrastructure'
require 'inventoried_timestamp'
require 'local_inventory'
require 'machine_reading'
require 'rbvmomi_extensions'
require 'reading'
require 'uri_enhancements'
require 'on_prem_url_generator'

Thread.abort_on_exception = true

class OnPremConnector
  include GlobalConfiguration
  include OnPremUrlGenerator
  using RbVmomiExtensions

  def initialize
    $logger.info 'Initializing OnPrem Connector'
    @hyper_client = HyperClient.new
    @local_infrastructure_inventory = InfrastructureInventory.new(:name)
    @max_threads = Integer(ENV['METER_API_THREADS'] || 10)
  end

  def submit
    Mongoid::QueryCache.clear_cache # rethink if we start using this in other places
    submit_infrastructure_creates
#    handle_machine_failed_creates # Failed creates result from TimeOut errors; This must be BEFORE submit_machine_creates
    submit_machine_creates
    submit_reading_creates
    submit_machine_disk_and_nic_deletes # Combined to go through documents with either or both changes once
    submit_machine_deletes
    submit_infrastructure_updates
    submit_machine_updates

      # Currently handles Disk/Nic updates too
      # block while thread pool finishes?
  # rescue RestClient::TooManyRequests => e
  #   pause(Time.parse(e.response.headers[:x_rate_limit_reset]))
  #   retry
  # rescue RuntimeError => e
  #   # if (md = e.message.match(/No remote_id for machine: (.+)/))
  #   #   errored_machine = Machine.find(platform_id: md[1])
  #   #   submit_machine_creates([errored_machine])
  #   # else
  #     raise e
  #   # end
  end

  def submit_reading_creates
    queued = Reading.where(record_status: 'created').count
    if queued == 0
      $logger.debug 'No readings queued for submission'
    else
      $logger.info "Preparing to submit #{queued} readings"

      start = Time.now
      # !! consider making this step one in a separate thread?
      Reading.group_for_submission

      thread_pool = Concurrent::ThreadPoolExecutor.new(min_threads: 1,
                                                       max_threads: @max_threads,
                                                       max_queue: @max_threads * 2,
                                                       fallback_policy: :caller_runs)

      MachineReading.no_timeout.each do |mr|
        thread_pool.post do
          Thread.current.abort_on_exception = true
        #   # In spite of the abort_on_exception above, a begin/rescue wrapper seems to be necessary to get
          #   #  exceptions percolated outside of the thead pool into the main thread
          begin
            prep_and_post_reading(mr)
          # rescue RestClient::TooManyRequests => e
          #   # TODO: Not great having this in two places, but the alternative would be figure out the TODO below
          #   #   and shutting down / reinitalizing the threadpool here
          #   pause(Time.parse(e.response.headers[:x_rate_limit_reset]))
          rescue StandardError => e
            $logger.error "Raising #{e.class}: #{e.message}"
            # TODO: This doesn't seem to operate as desired; this seems to cause a jump to the "line" after the end of the "thread_pool do" code
            #  Exception handling in the main function doesn't seem to execute right away either; not till the end of machinereading.each
            Thread.main.raise e
          end
        end
      end
      thread_pool.shutdown
      thread_pool.wait_for_termination

      $logger.info "Completed submission of readings in #{Time.now - start} seconds"
    end
  end

  def submit_infrastructure_creates
    infrastructure_creates = Infrastructure.where(record_status: 'created')
    if infrastructure_creates.empty?
      $logger.debug 'No new infrastructures to submit to OnPrem'
    else
      @local_infrastructure_inventory = InfrastructureInventory.new(:name)

      infrastructure_creates.each do |infrastructure|
        infrastructure = infrastructure.submit_create
        @local_infrastructure_inventory[infrastructure.name] = infrastructure
      end
      # Batch save local inventories
      @local_infrastructure_inventory.save
      $logger.info "Processing #{infrastructure_creates.size} new infrastructures for submission to OnPrem"
    end
  end

  def prep_and_post_reading(machine_reading)
    machine_reading.post_to_api#(infrastructure_machine_readings_url(machine_prid.remote_id))
  end


  def submit_machine_creates(machine_creates = Machine.to_be_created)
    if machine_creates.empty?
      $logger.debug { 'No new machines to submit to 6fusion Meter' }
    else
      $logger.info { "Processing #{machine_creates.size} new machines for submission to the 6fusion Meter API" }
      thread_pool = Concurrent::ThreadPoolExecutor.new(min_threads: 1,
                                                       max_threads: @max_threads,
                                                       max_queue: @max_threads * 2,
                                                       fallback_policy: :caller_runs)
      machine_creates.each do |created_machine|
        thread_pool.post {
          # catch resourcenotfound and flag infrastructure for create?
          created_machine.submit_create }

        thread_pool.shutdown
        thread_pool.wait_for_termination
      end
    end
  end


  def submit_machine_deletes
    machine_deletes = Machine.to_be_deleted
    if !machine_deletes.empty?
      $logger.info "Processing #{machine_deletes.size} machines that require deletion from OnPrem"
    else
      $logger.debug 'No machines require deletion from OnPrem'
    end

    machine_deletes.each do |deleted_machine|
      submit_url = machine_url(deleted_machine)
      deleted_machine.submit_delete(submit_url)

      if deleted_machine.record_status == 'deleted'
        deleted_machine.save # Update status in mongo
      else
        $logger.error "Error deleting machine: Database ID:#{deleted_machine.id}, Platform ID:#{deleted_machine.platform_id}"
      end
    end
  end

  def submit_machine_updates
#    if InventoriedTimestamp.most_recent
      updated_machines = Machine.to_be_updated # (latest_inventory.inventory_at)
      if !updated_machines.empty?
        $logger.info "Processing #{updated_machines.size} machines that have configuration updates for OnPrem"
      else
        $logger.debug 'No machines require updating in OnPrem'
      end

      updated_machines.each do |updated_machine|
        begin
          #updated_machine = inject_machine_disk_nic_remote_ids(updated_machine)
          $logger.debug "Updated machine #{updated_machine.inspect} \n"
          submit_url = machine_url(updated_machine)
          submitted_machine = updated_machine.submit_update(submit_url)
          api_machine = retrieve_api_machine(updated_machine)
          verify_and_submit_nics_updates(submitted_machine, api_machine)
          verify_and_submit_disks_updates(submitted_machine, api_machine)
          $logger.debug "submitted_machine.record_status => #{submitted_machine.record_status} \n\n"
          # Note: Successfully updated machines record_status changes from "updated" to "verified_update"
          if submitted_machine.record_status == 'verified_update'
            submitted_machine.save # Save status in mongo
            # process_verified_machine_prids(submitted_machine)
          else
            $logger.error "Machine #{submitted_machine.name}/#{submitted_machine.platform_id} not updated."
          end
        rescue RestClient::TooManyRequests => e
          raise e
        rescue StandardError => e
          $logger.debug e.backtrace.join("\n")
          $logger.error "Error updating machine: #{e.message}"
        ensure
          # @local_platform_remote_id_inventory.save
        end
      end
 #   end
  end

  def submit_infrastructure_updates
#    if InventoriedTimestamp.most_recent
      updated_infrastructures = Infrastructure.where(record_status: 'updated') # (latest_inventory.inventory_at)
      if !updated_infrastructures.empty?
        $logger.info "Processing #{updated_infrastructures.size} infrastructures that have configuration updates for OnPrem"
      else
        $logger.debug 'No infrastructures require updating in OnPrem'
      end
      updated_infrastructures.each do |updated_infrastructure|
        begin
          submitted_infrastructure = updated_infrastructure.submit_update
          # Note: Successfully updated infrastructures record_status changes from "updated" to "verified_update"
          if submitted_infrastructure.record_status == 'verified_update'
            submitted_infrastructure.save # Save status in mongo
          else
            $logger.error "Infrastructure #{submitted_infrastructure.name}/#{submitted_infrastructure.platform_id} not updated."
          end
        rescue RestClient::TooManyRequests => e
          raise e
        rescue StandardError => e
          $logger.debug e.backtrace.join("\n")
          $logger.error "Error updating infrastructure: #{e.message}"
        end
      end
#    end
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
    $logger.debug 'Processing disk that require OnPrem deletion'

    submit_url = disk_url(disk)
    deleted_disk = disk.submit_delete(submit_url)
    if deleted_disk.record_status == 'verified_delete' || deleted_disk.record_status == 'unverified_delete'
      deleted_disk.save # Update status in mongo
    else
      $logger.error "Error deleting disk: platform_id = #{disk.platform_id}, mongo _id = #{disk.id}, submit_url = #{submit_url}"
    end
  end

  def submit_machine_nic_delete(nic)
    $logger.debug 'Processing nic that require OnPrem deletion'

    submit_url = nic_url(nic)
    deleted_nic = nic.submit_delete(submit_url)
    if deleted_nic.record_status == 'verified_delete' || deleted_nic.record_status == 'unverified_delete'
      deleted_nic.save # Update status in mongo
    else
      $logger.error "Error deleting NIC: platform_id = #{nic.platform_id}, platform _id = #{nic.id}, submit_url = #{submit_url}"
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
#    $logger.debug "machines_by_platform_id = > #{machines_by_platform_id.inspect} \n\n"
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
    $logger.warn 'API request limit reached'

    if reset_time
      sleepy_time = (reset_time - Time.now).to_i
      if sleepy_time > 0 # pretty unlikely for this to be false
        $logger.info "Waiting #{sleepy_time} seconds before reattempting API submissions"
        sleep(sleepy_time)
      else
        $logger.warn "Received a rate_limit_reset in the past #{reset_time}. Waiting 60 seconds instead"
        sleep(60)
      end
    else
      sleep(60)
    end
  end

  def verify_and_submit_nics_updates(updated_machine, _api_machine)
    to_be_created = (updated_machine.nics.map(&:api_format)).select { |n| n[:id].nil? && n[:name].present? }
    create_nics(to_be_created, updated_machine) if to_be_created.present?
  end

  def create_nics(nics, machine)
    submit_url = machine_nics_url(machine.remote_id)
    nics.each do |nic|
      response = @hyper_client.post(submit_url, nic)
      if response && response.code == 200
        current_nic = machine.nics.select { |n| n if n.name == nic[:name] }.first
        current_nic.update_attributes(remote_id: response.json['id'], record_status: 'verified_create')
        $logger.debug "Successfully created nic #{nic[:name]} for machine #{machine.name}"
      else
        machine.update_attributtes(record_status: 'updated')
        $logger.error "Couldn't create nic #{nic[:name]} for machine #{machine.name}"
      end
    end
  end

  def verify_and_submit_disks_updates(machine, api_machine)
    remote_disks = {}
    api_machine['embedded']['disks'].each{|d| remote_disks[d['custom_id']] = Disk.new(platform_id: d['custom_id'],
                                                                                      name:        d['name'],
                                                                                      size:        d['storage_bytes'])}

    machine.disks.reject{|d| remote_disks.keys.include?(d.custom_id)}.each{|disk|
      create_disk(machine, disk)
      remote_disks[disk.custom_id] = disk}

    machine.disks.select{|d| (remote_disks[d.custom_id].name != d.name) or (remote_disks[d.custom_id].size != d.size) }.each{|disk|
      update_disk(disk) }

  end

  def update_disk(disk)
    $logger.info "Updating #{disk.name}/#{disk.custom_id} in 6fusion Meter"
    response = @hyper_client.put_disk(disk.api_format)
    disk.update_attribute(:record_status, 'verified_update') if response.code == 200
  end

  def create_disk(machine, disk)
    $logger.info "Creating #{disk.name}/#{disk.custom_id} in 6fusion Meter"
    response = @hyper_client.post_disk(machine.custom_id, disk.api_format)
    disk.update_attribute(:record_status, 'verified_create') if response.code == 200
  end

  def retrieve_api_machine(updated_machine)
    api_machine = @hyper_client.get(machine_url(updated_machine))
    api_machine.json if api_machine && api_machine.code == 200
  end

  def machine_exists?(machine_reading)
    machine_platform_id = machine_reading.id[:machine_platform_id]
    deleted_machines = Machine.where(record_status: 'deleted').map(&:platform_id)
    !deleted_machines.include?(machine_platform_id)
  end
end
