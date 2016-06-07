require 'logger'

require 'inventory_collector'
require 'local_inventory'
require 'rbvmomi_extensions'
require 'vsphere_session'

class Registration
  include GlobalConfiguration
  using RbVmomiExtensions

  # Map existing machine inventory in UC6 to existing machine inventory in vSphere
  #  using machine names. Expects the UC6 connector to have already retrieved the inventory
  #  from the UC6 API and populated the local data store with it.
  def self.initialize_platform_ids
    inventory = MachineInventory.new(nil, :name)
    result = VSphere.session.propertyCollector.RetrievePropertiesEx(specSet: [InventoryCollector.vm_filter_spec(['name'])],
                                                                    partialUpdates: false,
                                                                    options: {})
    loop do
      result.objects.each do |object_content|
        machine = inventory[object_content.propSet[0].val]
        machine.update_attribute(:platform_id, object_content.moref) if machine
      end
      break unless result.token
      result = VSphere.session.propertyCollector.ContinueRetrievePropertiesEx(token: result.token)
    end
  end
end
