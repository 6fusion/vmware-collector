module CurrentVmsInventory

  def configuration
    @configuration ||= GlobalConfiguration::GlobalConfig.instance
  end

  def retrieve_working_machines_morefs
    local_inventory = MachineInventory.new
    local_inventory.select do |_platform_id, machine|
      machine.record_status != 'incomplete'
    end.keys
  end

  def split_machine_inventory(inventory)
    inventory.each_slice(configuration[:on_prem_machines_by_inv_timestamp].to_i).to_a
  end

  def initialize_inventoried_timestamps_with_inventory_for(current_time)
    inventoried_timestamps = InventoriedTimestamp.where(inventory_at: current_time)
    if inventoried_timestamps.empty?
      return_array_of_inv_timestamps(current_time, retrieve_working_machines_morefs)
    else
      pending_inventory = retrieve_working_machines_morefs - (inventoried_timestamps.map &:machine_inventory).flatten 
      return_array_of_inv_timestamps(current_time, pending_inventory) if !pending_inventory.empty?
    end
  end

  def return_array_of_inv_timestamps(current_time,vms)
    split_machine_inventory(vms).map do |inventory|
      InventoriedTimestamp.new(inventory_at: current_time, machine_inventory: inventory)
    end
  end

  def create_inventory_timestamps_with_inventory_for(current_time)
    inventoried_timestamps = InventoriedTimestamp.where(inventory_at: current_time)
    if inventoried_timestamps.empty?
      InventoriedTimestamp.create(inventory_at: current_time, machine_inventory: retrieve_working_machines_morefs)
    else
      pending_inventory = retrieve_working_machines_morefs - (inventoried_timestamps.map &:machine_inventory).flatten
      InventoriedTimestamp.create(inventory_at: current_time, machine_inventory: pending_inventory) if !pending_inventory.empty?
    end
  end

  def retrieve_container_name
    stdout, stderr, status = Open3.capture3('hostname -f')
    stdout = stdout.chomp.strip
    if !stdout.empty? && stderr.empty?
      return stdout
    else
      raise 'Could not get the hostname of the current running container'
    end
  end

  def inventoried_timestamp_unlocked?(inv_timestamp)
    not inv_timestamp.locked ||
    (inv_timestamp.locked && inv_timestamp.locked_by == @container_name)
  end

  def inventoried_timestamp_free_to_meter?(inv_timestamp)
    inv_timestamp.reload
    inv_timestamp.locked &&
    inv_timestamp.locked_by == @container_name &&
    inv_timestamp.record_status == 'queued_for_metering'
  end

  def inventoried_timestamps_to_be_metered(container)
    InventoriedTimestamp.where(record_status: 'queued_for_metering',
      locked: true,
      locked_by: container)
    .asc(:inventory_at)
  end
end
