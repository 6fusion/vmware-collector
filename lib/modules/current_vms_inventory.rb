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
    inventory.each_slice(configuration[:uc6_machines_by_inv_timestamp].to_i).to_a
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
end