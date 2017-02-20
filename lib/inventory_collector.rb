require 'timeout'

require 'global_configuration'
require 'inventoried_timestamp'
require 'local_inventory'
require 'logging'
require 'machine'
require 'rbvmomi_extensions'
require 'vsphere_session'
require 'objspace'

class InventoryCollector
  include GlobalConfiguration
  include Logging
  using RbVmomiExtensions

  attr_reader :infrastructure

  def initialize(infrastructure)
    @version = ''
    @infrastructure = infrastructure
    @local_inventory = MachineInventory.new(infrastructure)
    @vsphere_session = VSphere::VSphereSession.new.session

    @data_center = @vsphere_session.rootFolder.childEntity.grep(RbVmomi::VIM::Datacenter).find { |dc| dc.name == infrastructure.name }
    # Note: rbvmomi's find_datacenter method must be avoided as it can require excessive privileges due to search index utilization

    # Currently the app does not support datacenter deletions, not even how to detect if they were deleted
    # so we added a validation @data_center.present? && @data_center.vmFolder.present?
    VSphere.wrapped_vsphere_request do
      @vsphere_session.propertyCollector.CreateFilter(spec: InventoryCollector.vm_filter_spec(
          InventoryCollector.vm_properties, @data_center.vmFolder
      ),
                                                      partialUpdates: false)
    end if @data_center.present? && @data_center.vmFolder.present?
    # These two maps are needed to get cpu_speed_hz from Hosts for Machines
    @hosts_cpu_hz_map = {}
    @vm_hosts_map = {}
    logger.debug "Initializing machine inventory collector for #{infrastructure.name}"
  end

  def run(time_to_query)
    logger.info "Collecting inventory for #{@infrastructure.name} at #{time_to_query}"
    results = VSphere.wrapped_vsphere_request do
      @vsphere_session.propertyCollector.WaitForUpdatesEx(version: @version,
                                                          options: {maxWaitSeconds: 0})
    end
    collected_machines = []
    while results
      results.filterSet.each do |fs|
        # Collect host cpu_hz from HostSystem objects, then get correct value for each VM by host moref
        fs.objectSet.each do |os|
          begin
            if os.obj.is_a?(RbVmomi::VIM::HostSystem)
              # Host cpu_hz map, before save use to associate cpu_hz with vm/machine
              host_cpu_speed_change_set = os.changeSet.first
              @hosts_cpu_hz_map[os.obj.moref] = host_cpu_speed_change_set ? host_cpu_speed_change_set.val : nil
            end

            if os.obj.is_a?(RbVmomi::VIM::VirtualMachine)
              # Map of vm moref => host moref (needed to get host cpu from hosts_cpu_hz map)
              runtime_host = os.changeSet.select { |cs| cs.name =~ /runtime.host/ }.first
              if runtime_host && runtime_host.val
                @vm_hosts_map[os.obj.moref] = runtime_host.val.moref
              end

              machine = Machine.build_from_vsphere_vm(os.machine_properties)
              machine.infrastructure_platform_id = @infrastructure.platform_id
              machine.infrastructure_remote_id = @infrastructure.remote_id

              machine.inventory_at = time_to_query

              # machine.cpu_speed_hz = @infrastructure.cpu_speed_for(machine.platform_id)
              machine.assign_fake_disk if machine.disks.empty?
              machine.assign_fake_nic if machine.nics.empty?
              machine.tags << 'type:virtual machine'
              machine.tags << 'platform:VMware'
              if machine.record_status == 'incomplete'
                if @local_inventory.key?(machine.platform_id)
                  previous_version = @local_inventory[machine.platform_id]

                  machine.merge(previous_version) # Fill in the missing attributes for this incomplete with previous

                  # The 2 reasons for using the previous version's disks/nics are:
                  # 1. API requires nics/disks for machine updates (this needs to be fixed)
                  # 2. Machines occasionally migrate, which leads to some empty properties
                  # Should look into if possible to get full information from migrated machine data
                  # Also, API updates to not require at least 1 disk/nic will eliminate need for fakes

                  # If a machine has any fake nic, it may be during a migration -- so the machine actually has disks/nics
                  # So, safer to just use previous
                  machine.disks = previous_version.disks if machine.disks.select { |d| d.name == 'fake' }.any?
                  machine.nics = previous_version.nics if machine.nics.select { |n| n.name == 'fake' }.any?

                  collected_machines << machine
                  # @local_inventory[machine.platform_id] = machine

                  # If a machine is incomplete, but not poweredOff, it's probably migrating. If so,
                  #  we just ignore the update (which will in turn use the previous record for this machine)
                  #  (The events generated by a migration don't easily allow us to actually determine if that is what is going on)
                else # this is an incomplete record for a machine we don't know about/haven't seen before
                  unless machine.name.blank? || machine.platform_id.blank?
                    machine.status ||= 'incomplete'

                    collected_machines << machine
                    # @local_inventory[machine.platform_id] = machine
                  end
                end
              else
                collected_machines << machine
                # @local_inventory[os.moref] = machine
              end
            end

          rescue RbVmomi::Fault => e
            logger.error e.message
            logger.debug e.class
            logger.debug e.backtrace.join("\n")

            if e.fault.is_a?(RbVmomi::VIM::ManagedObjectNotFound)
              if @local_inventory[os.moref].present?
                logger.info "Deleting machine from inventory with moref: #{os.moref}"
                @local_inventory[os.moref].update_attribute(:status, 'deleted') # !! Get a better status  #!! overwrites "current" time #!! batch?
              end
            else
              raise e
            end
          end
        end
      end
      @version = results.version

      results = VSphere.wrapped_vsphere_request do
        @vsphere_session.propertyCollector.WaitForUpdatesEx(version: @version,
                                                            options: {maxWaitSeconds: 0})
      end
    end

    collected_machines.each do |collected_machine|
      # Get machine's cpu_speed_hz from vm_hosts_map
      machine_host = @vm_hosts_map[collected_machine.platform_id]
      cpu_hz = @hosts_cpu_hz_map[machine_host]

      # Note: Machine cpu_speed_hz defaults to 1 (api will not accept 0 values right now)
      # So use the default unless cpu_hz is greater than 0

      collected_machine.cpu_speed_hz = cpu_hz.present? && cpu_hz > 0 ? cpu_hz : 1
      # if cpu_hz && cpu_hz > 0 # Commented all fo this as now there is not cpu_speed_mhz, as on prem only has cpu_speed_hz
      #   cpu_mhz = cpu_hz / 1_000_000
      #   collected_machine.cpu_speed_hz = cpu_hz
      # end

      # Set 'to_be_deleted' here to avoid overriding with record_status 'incomplete'
      # Status of 'incomplete' will merge attributes from previous collection to avoid validation issues when submitting (ex. presence of name)
      collected_machine.record_status = 'to_be_deleted' if ( collected_machine.status == 'deleted' )

      # Add all machines to local inventory before save
      @local_inventory[collected_machine.platform_id] = collected_machine
    end

    @local_inventory.save_a_copy_with_updates(time_to_query)
    logger.info "Recording inventory of #{@local_inventory.size} machines for #{@infrastructure.name} at #{time_to_query}"

    logger.debug 'Generating vSphere session activity with currentTime request'
    VSphere.wrapped_vsphere_request { VSphere.session.serviceInstance.CurrentTime }
  end

  private

  def define_values_for_tags(path, folder)
    @vmpath = path
    resource_pool = folder.resourcePool
    @vmresourcepool = resource_pool.to_s.split(/"/)[1] if resource_pool
    true
  end

  # Note: We can expose more of the propSpecs as needed
  # May want to move this into another class
  # instance_uuid, string (ex. '502f5ce9-4c65-af38-9287-704da09a127f')
  # returns vm of class RbVmomi::VIM::VirtualMachine
  def find_vm_by_instance_uuid(instance_uuid, dc)
    propSpecs = {
        entity: RbVmomi::VIM::Folder, uuid: instance_uuid, instanceUuid: true,
        vmSearch: true, datacenter: dc
    }
    @vsphere_session.serviceInstance.content.rootFolder._connection.searchIndex.FindByUuid(propSpecs)
  end

  def self.vm_properties
    [ # Machine Attributes
        'name',
        'config.guestFullName', # !! This is throwing property error
        #      'config.instanceUuid',
        'summary.config.numCpu',
        'summary.config.memorySizeMB',
        'summary.runtime.powerState',
        'runtime.host',
        # -- Disks
        'config.hardware.device',
        'layoutEx.disk',
        'layoutEx.file',
        # -- Nics
        'guest.net'
    ]
  end

  def self.vm_filter_spec(properties = vm_properties, root_folder = VSphere.root_folder)
    recurse_folders = RbVmomi::VIM.SelectionSpec(name: 'ParentFolder')

    find_machines = RbVmomi::VIM.TraversalSpec(
        name: 'Datacenters', type: 'Datacenter', path: 'vmFolder', skip: false,
        selectSet: [recurse_folders]
    )

    find_vapps = RbVmomi::VIM.TraversalSpec(
        name: 'visitVapps', type: 'VirtualApp', path: 'vm', skip: false,
        selectSet: [recurse_folders]
    )

    find_vm_hosts = RbVmomi::VIM.TraversalSpec(
        name: 'foo', type: 'VirtualMachine', path: 'runtime.host', skip: false
    )

    find_folders = RbVmomi::VIM.TraversalSpec(
        name: 'ParentFolder', type: 'Folder', path: 'childEntity', skip: false,
        selectSet: [recurse_folders, find_vapps, find_machines, find_vm_hosts]
    )

    RbVmomi::VIM.PropertyFilterSpec(
      objectSet: [
        obj: root_folder,
        selectSet: [
          find_folders,
          # RbVmomi::VIM.TraversalSpec(
          #   name: 'tsDatacenterVMFolder',
          #   type: 'Datacenter',
          #   path: 'vmFolder',
          #   skip: true,
          #   selectSet: [ RbVmomi::VIM.SelectionSpec(name: 'tsFolder') ] ),
          # RbVmomi::VIM.TraversalSpec(
          #   name: 'tsFolder',
          #   type: 'Folder',
          #   path: 'childEntity',
          #   skip: false,
          #   selectSet: [
          #     RbVmomi::VIM.SelectionSpec(name: 'tsDatacenterVMFolder')] )
        ]
      ],
      propSet: [
        { type: 'VirtualMachine', pathSet: properties },
        { type: 'HostSystem', pathSet: ['hardware.cpuInfo.hz'] }
      ]
    )
  end
end
