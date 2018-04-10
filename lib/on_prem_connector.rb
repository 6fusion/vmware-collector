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
    $logger.info { 'Initializing 6fusion Meter Connector' }
    @hyper_client = HyperClient.new
    @local_infrastructure_inventory = InfrastructureInventory.new(:name)
    @max_threads = Integer(ENV['METER_API_THREADS'] || 20)
    @thread_pool = Concurrent::ThreadPoolExecutor.new(min_threads: 1,
                                                     max_threads: @max_threads,
                                                     max_queue: @max_threads * 2,
                                                     fallback_policy: :caller_runs)
  end

  def submit
    Mongoid::QueryCache.clear_cache # rethink if we start using this in other places
    submit_infrastructure_creates
    submit_machine_creates
    submit_reading_creates

    submit_infrastructure_updates
    submit_machine_updates

    # FIXME since deletes are updates, this is obsolete?
    submit_machine_disk_and_nic_deletes # Combined to go through documents with either or both changes once
    submit_machine_deletes
  end

  def submit_infrastructure_creates
    infrastructure_creates = Infrastructure.where(record_status: 'created')
    if infrastructure_creates.empty?
      $logger.debug { 'No new infrastructures to submit to 6fusion Meter' }
    else
      @local_infrastructure_inventory = InfrastructureInventory.new(:name)
      infrastructure_creates.each do |infrastructure|
        infrastructure.valid? ?
          infrastructure.post_to_api :
          $logger.warn { "Not saving infrastructure #{infrastructure.name} to Meter: #{infrastructure.errors.full_messages}" }
        @local_infrastructure_inventory[infrastructure.name] = infrastructure
      end
      @local_infrastructure_inventory.save
      $logger.info { "Processing #{infrastructure_creates.size} new infrastructures for submission to 6fusion Meter" }
    end
  end

  def submit_machine_creates(machine_creates = Machine.to_be_created)
    if machine_creates.empty?
      $logger.debug { 'No new machines to submit to 6fusion Meter' }
    else
      $logger.info { "Processing #{machine_creates.size} new machines for submission to the 6fusion Meter" }
      machine_creates.each do |machine|
        @thread_pool.post do
          begin
            # TODO catch resourcenotfound and flag infrastructure for create?
            machine.valid? ?
              machine.post_to_api :
              $logger.warn { "Not saving machine #{machine.name} to Meter: #{machine.errors.full_messages}" }
          rescue => e
            Thread.main.raise e
          end
        end
      end
      @thread_pool.shutdown
      @thread_pool.wait_for_termination
    end
  end

  def submit_reading_creates
    queued = Reading.where(record_status: 'created').count
    if queued == 0
      $logger.debug { 'No readings queued for submission' }
    else
      start = Time.now
      hyperclient = HyperClient.new

      Reading.where(record_status: 'created').no_timeout.each do |reading|
        @thread_pool.post do
          begin
            reading.valid? ?
              reading.post_to_api(hyperclient) :
              $logger.warn { "Skipping sample for #{reading.machine_platform_id}: #{reading.errors.full_messages}" }
          rescue StandardError => e
            $logger.error { "Raising #{e.class}: #{e.message}" }
            if e.message.match(/unable to find/i)
              $logger.info { "Attempting to create missing resources in Meter API" }
              Machine.find({uuid: reading.machine_custom_id})&.post_to_api
            end
            # TODO: This doesn't seem to operate as desired; this seems to cause a jump to the "line" after the end of the "thread_pool do" code
            Thread.main.raise e
          end
        end
      end

      @thread_pool.shutdown
      @thread_pool.wait_for_termination

      $logger.info { "Completed submission of #{queued} readings in #{Time.now - start} seconds" }
    end
  end


  def submit_machine_deletes
    machine_deletes = Machine.to_be_deleted
    if machine_deletes.empty?
      $logger.debug { 'No machines require deletion from the 6fusion Meter' }
    else
      $logger.info { "Processing #{machine_deletes.size} machines that require deletion from the 6fusion Meter" }
    end
    # FIXME lots of room for optimization here. probably pull disks/nics out to top levle docs
    machine_deletes.each do |machine|
      @thread_pool.post do
        machine.disks.select{|d| d.status.eql?('active')}.each{|d|
          d.record_status = 'to_be_deleted' }
        machine.nics.select{|n| n.status.eql?('active')}.each{|n|
          n.record_status = 'to_be_deleted' }
        machine.save
        submit_machine_disk_and_nic_deletes
        machine.submit_delete
      end
    end
    @thread_pool.shutdown
    @thread_pool.wait_for_termination
  end

  def submit_machine_updates
    updated_machines = Machine.to_be_updated
    if updated_machines.empty?
      $logger.debug { 'No machines require updating in the 6fusion Meter' }
    else
      $logger.info { "Syncing #{updated_machines.size} machine configurations with the 6fusion Meter" }
    end
    updated_machines.each do |machine|
      @thread_pool.post do
        begin
          machine.valid? ?
            machine.patch_to_api :
            $logger.warn { "Not updating machine #{machine.name} in Meter: #{machine.errors.full_messages}" }
        rescue => e
          Thread.main.raise e
        end
      end
    end
    @thread_pool.shutdown
    @thread_pool.wait_for_termination
  end

  def submit_infrastructure_updates
    updated_infrastructures = Infrastructure.where(record_status: 'updated') # (latest_inventory.inventory_at)
    if !updated_infrastructures.empty?
      $logger.info { "Processing #{updated_infrastructures.size} infrastructures that have configuration updates for 6fusion Meter" }
    else
      $logger.debug { 'No infrastructures require updating in the 6fusion Meter' }
    end
    updated_infrastructures.each {|infrastructure|
      # FIXME log
      infrastructure.patch_to_api if infrastructure.valid? }
  end

  def prep_and_post_reading(machine_reading)
    machine_reading.post_to_api
  end

  # Control function, submit disks/nics
  # Finds documents with nics or disks that need to be deleted, then calls specific delete functions
  def submit_machine_disk_and_nic_deletes
    machines_with_disk_or_nic_deletes = Machine.disks_or_nics_to_be_deleted

    machines_with_disk_or_nic_deletes.each do |machine|
      disk_deletes = machine.disks.select { |d| 'to_be_deleted' == d.record_status }
      nic_deletes = machine.nics.select { |n| 'to_be_deleted' == n.record_status }

      disk_deletes.each do |disk|
        $logger.debug { "Deleting disk #{disk.name}/#{disk.platform_id} form machine #{machine.name}" }
        disk.status = 'deleted'
        begin
          @hyper_client.put_disk(disk.api_format)
          disk.update_attribute(:record_status, 'verified_delete')
        rescue RestClient::ResourceNotFound => _
          disk.update_attribute(:record_status, 'verified_delete')
        end
      end

      nic_deletes.each do |nic|
        $logger.debug { "Deleting nic #{nic.name}/#{nic.platform_id} form machine #{machine.name}" }
        nic.status = 'deleted'
        begin
          @hyper_client.put_nic(nic.api_format)
          nic.update_attribute(:record_status, 'verified_delete')
        rescue RestClient::ResourceNotFound => _
          nic.update_attribute(:record_status, 'verified_delete')
        end
      end
    end
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

  def verify_and_submit_nic_updates(machine, api_machine)
    remote_nics = {}
    api_machine['embedded']['nics'].each{|n| remote_nics[n['custom_id']] = Nic.new(platform_id: n['custom_id'],
                                                                                   name:        n['name'])}

    machine.nics.reject{|n| remote_nics.keys.include?(n.custom_id)}.each{|nic|
      create_nic(machine, nic)
      remote_nics[nic.custom_id] = nic}

    # TODO utilize matchable? id could be a problem...
    machine.nics
      .select{|n| (remote_nics[n.custom_id].name != n.name) or
                  (remote_nics[n.custom_id].status != n.status)}
      .each{|nic| update_nic(nic) }
  end

  def create_nic(machine, nic)
    $logger.info "Creating NIC #{nic.name}/#{nic.custom_id} in the 6fusion Meter"
    response = @hyper_client.post_nic(machine.custom_id, nic.api_format)
    nic.update_attribute(:record_status, 'verified_create') if response.code == 200
  end
  def update_nic(nic)
    $logger.info "Updating nic #{nic.name}/#{nic.custom_id} in the 6fusion Meter"
    response = @hyper_client.put_nic(nic.api_format)
    nic.update_attribute(:record_status, 'verified_update') if response.code == 200
  end

  def verify_and_submit_disk_updates(machine, api_machine)
    remote_disks = {}
    api_machine['embedded']['disks'].each{|d| remote_disks[d['custom_id']] = Disk.new(platform_id: d['custom_id'],
                                                                                      name:        d['name'],
                                                                                      size:        d['storage_bytes'])}
    machine.disks
      .reject{|d| remote_disks.keys.include?(d.custom_id)}
      .each{|disk|
        create_disk(machine, disk)
        remote_disks[disk.custom_id] = disk}

    machine.disks
      .select{|d| d.status.eql?('updated')}
      .select{|d| (remote_disks[d.custom_id].name != d.name) or (remote_disks[d.custom_id].size != d.size) }
      .each{|disk|
        update_disk(disk) }
  end

  def update_disk(disk)
    $logger.info "Updating disk #{disk.name}/#{disk.custom_id} in the 6fusion Meter"
    response = @hyper_client.put_disk(disk.api_format)
    disk.update_attribute(:record_status, 'verified_update') if response.code == 200
  end

  def create_disk(machine, disk)
    $logger.info "Creating disk #{disk.name}/#{disk.custom_id} in the 6fusion Meter"
    response = @hyper_client.post_disk(machine.custom_id, disk.api_format)
    disk.update_attribute(:record_status, 'verified_create') if response.code == 200
  end

  def retrieve_api_machine(updated_machine)
    api_machine = @hyper_client.get(machine_url(updated_machine))
    api_machine.json if api_machine && api_machine.code == 200
  end

end
