require 'timeout'

require 'inventoried_timestamp'
require 'local_inventory'
require 'machine'
require 'rbvmomi_extensions'
require 'vsphere_session'

class InventoryCollector
  using RbVmomiExtensions

  attr_reader :infrastructure #? wtf

  def initialize(infrastructure)
    @version = ''
    @infrastructure = infrastructure
    @local_inventory = MachineInventory.new(infrastructure)
    @vsphere_session = VSphere::VSphereSession.new.session


    @data_center = @vsphere_session.rootFolder.childEntity.grep(RbVmomi::VIM::Datacenter).find { |dc| dc.moref == infrastructure.platform_id }
    # Note: rbvmomi's find_datacenter method must be avoided as it can require excessive privileges due to search index utilization

    # Currently the app does not support datacenter deletions, not even how to detect if they were deleted
    # so we added a validation @data_center.present? && @data_center.vmFolder.present?
    VSphere.wrapped_vsphere_request do
      @vsphere_session.propertyCollector.CreateFilter(spec: InventoryCollector.vm_filter_spec(
                                                        InventoryCollector.vm_properties, @data_center.vmFolder),
                                                      partialUpdates: false)
    end if @data_center.present? && @data_center.vmFolder.present?
    # These two maps are needed to get cpu_speed_hz from Hosts for Machines
    @hosts_cpu_hz_map = {}
    @vm_hosts_map = {}
    $logger.debug { "Initializing machine inventory collector for #{infrastructure.name}" }
  end

  def run(time_to_query)
    first_run = @version.eql?('')
    $logger.info {  "Collecting inventory for #{@infrastructure.platform_id} at #{time_to_query}" }
    results = VSphere.wrapped_vsphere_request do
      @vsphere_session.propertyCollector.WaitForUpdatesEx(version: @version,
                                                          options: {maxWaitSeconds: 0})
    end
    collected_machines = []
    vm_folders = {}
    vm_resource_pools = {}
    vm_vapps = {}
    vm_clusters = {}

    while results
      results.filterSet.each do |fs|
        # Collect host cpu_hz from HostSystem objects, then get correct value for each VM by host moref
        fs.objectSet.each do |os|
          begin

            # if os.obj.is_a?(RbVmomi::VIM::ComputeResource)
            #   binding.pry
            # end


            if os.obj.is_a?(RbVmomi::VIM::ResourcePool)
              if os.obj.is_a?(RbVmomi::VIM::VirtualApp)
                name = os.obj.name
                os.obj.vm.each{|vm|
                  vm_vapps[vm.moref] = name }
              else
                # binding.pry
              end
            end

            if os.obj.is_a?(RbVmomi::VIM::Folder)
              folder_name = os.obj.name
              os.obj.childEntity.select{|child| child.is_a?(RbVmomi::VIM::VirtualMachine)}.each {|vm|
                $logger.debug { "Putting #{vm.moref} into folder #{folder_name}" }
                vm_folders[vm.moref] = folder_name }
            end

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
              $logger.debug { "Processing update: #{machine.name}/#{machine.platform_id} for infrastructure #{@infrastructure.platform_id}" }

              machine.tags += ["datacenter:#{@infrastructure.platform_id}"]

              # If we don't already know resourcePool...
              unless vm_clusters[os.moref]
                resource_pool = os.obj.resourcePool
                if resource_pool
                  ccr = resource_pool.owner.name
                  rp = resource_pool.name
                  # go ahead and fill in cache wither other discoverable VMs to reduce API calls
                  resource_pool.vm.each{|vm|
                    vm_resource_pools[vm.moref] = rp
                    vm_clusters[vm.moref] = ccr }
                end
              end

              # The Folder object logic several lines up is more efficient, but not always available; this is sort of a backup method
              unless vm_folders[os.moref]
                if folder = os.obj.parent
                  name = folder.name
                  folder
                    .children
                    .select{|child| child.is_a?(RbVmomi::VIM::VirtualMachine)}
                    .each{|vm|
                      $logger.debug { "Putting #{vm.moref} into folder #{name}" }
                      vm_folders[vm.moref] = name }
                elsif v_app = os.obj.parentVApp
                  name = v_app.name
                  v_app.vm.each{|vm|
                    vm_vapps[vm.moref] = name }
                end
              end

              if vm_resource_pools[os.moref]
                machine.tags += ["type:virtual machine", "clusterComputeResource:#{vm_resource_pools[os.moref]}", "resourcePool:#{vm_resource_pools[os.moref]}"]
              else
                if os.obj.config.template == true
                  machine.tags += ["type:virtual machine template"]
                end
              end

              machine.infrastructure_platform_id = @infrastructure.platform_id
              machine.infrastructure_custom_id = @infrastructure.custom_id
              machine.inventory_at = time_to_query

              if (machine.name.nil? or machine.name.empty?)
                $logger.debug { "Machine with no name: #{machine.inspect}" }
              end

              if machine.record_status == 'incomplete'
                $logger.debug { "Incomplete machine update: #{machine}" }

                if @local_inventory.key?(machine.platform_id)
                  previous_version = @local_inventory[machine.platform_id]

                  machine.merge(previous_version) # Fill in the missing attributes for this incomplete with previous
                  # during migrations, disks and nics are often missing from the change set, so we just put the disks/nics from our previous save onto this instance
                  machine.disks = previous_version.disks if machine.disks.empty?
                  machine.nics = previous_version.nics if machine.nics.empty?

                  collected_machines << machine

                  # If a machine is incomplete, but not poweredOff, it's probably migrating. If so,
                  #  we just ignore the update (which will in turn use the previous record for this machine)
                  #  (The events generated by a migration don't easily allow us to actually determine if that is what is going on)
                else # this is an incomplete record for a machine we don't know about/haven't seen before
                  unless machine.name.blank? || machine.platform_id.blank?
                    # TODO what happens if we don't update the @version token, and just ask vsphere for the same changeset set again?
                    machine.status ||= 'incomplete'
                    # merge in preexisting machine if available
                    collected_machines << machine
                  end
                end
              else
                collected_machines << machine
                # @local_inventory[os.moref] = machine
              end
            end

          rescue RbVmomi::Fault => e

            if e.fault.is_a?(RbVmomi::VIM::ManagedObjectNotFound) or e.fault.is_a?(MangedObjectNotFound)
              if @local_inventory[os.moref].present?
                $logger.info { "Deleting machine from inventory with moref: #{os.moref}" }
                machine = @local_inventory[os.moref].clone
                machine.status = 'deleted'
                collected_machines << machine
              end
            else
              $logger.error { e.message }
              $logger.debug { e.class }
              $logger.debug { e.backtrace.join("\n") }
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

    if first_run
      missing_inventory = @local_inventory.keys - collected_machines.map(&:virtual_name)
      missing_inventory.each do |moref|
        machine = @local_inventory[moref].clone
        machine.status = 'deleted'
        collected_machines << machine
      end
    end

    collected_machines.each do |collected_machine|
      # Get machine's cpu_speed_hz from vm_hosts_map
      if collected_machine.status != 'deleted'
        machine_host = @vm_hosts_map[collected_machine.platform_id]
        cpu_hz = @hosts_cpu_hz_map[machine_host]

        # Note: Machine cpu_speed_hz defaults to 1 (api will not accept 0 values right now)
        # So use the default unless cpu_hz is greater than 0

        collected_machine.cpu_speed_hz = cpu_hz.present? && cpu_hz > 0 ? cpu_hz : 1

        if vm_folders[collected_machine.platform_id]
          $logger.debug { "Tagging #{collected_machine.platform_id} with folder #{vm_folders[collected_machine.platform_id]}" }
          collected_machine.tags += ["folder:#{vm_folders[collected_machine.platform_id]}"]
        end
        # else
        #   if @local_inventory[collected_machine.platform_id]
        #     previous_folder = @local_inventory[collected_machine.platform_id].tags.find{|t| t.start_with?('folder:')}
        #     if previous_folder
        #       $logger.debug {"Adding folder tag #{previous_folder} from previous run for #{collected_machine.platform_id}"}
        #       collected_machine.tags += [previous_folder]
        #     else
        #       $logger.warn {"Could not determine folder of #{collected_machine.platform_id}"}
        #     end
        #   end
        # end
        if vm_vapps[collected_machine.platform_id]
          $logger.debug { "Tagging #{collected_machine.platform_id} with vApp #{vm_vapps[collected_machine.platform_id]}" }
          collected_machine.tags += ["vApp:#{vm_vapps[collected_machine.platform_id]}"]
        end
      end

      # Set 'to_be_deleted' here to avoid overriding with record_status 'incomplete'
      # Status of 'incomplete' will merge attributes from previous collection to avoid validation issues when submitting (ex. presence of name)
      #collected_machine.record_status = 'to_be_deleted' if ( collected_machine.status == 'deleted' )

      # Add all machines to local inventory before save
      @local_inventory[collected_machine.platform_id] = collected_machine
    end

    first_run = false

    @local_inventory.save_a_copy_with_updates(time_to_query)
    $logger.info "Recording inventory of #{@local_inventory.size} machines for #{@infrastructure.name} at #{time_to_query}"

    $logger.debug 'Generating vSphere session activity with currentTime request'
    VSphere.wrapped_vsphere_request { VSphere.session.serviceInstance.CurrentTime }
  end

  private

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
      'parent',
      'resourcePool',
      'config.guestFullName', # !! This is throwing property error
      'config.instanceUuid',
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

    find_resource_pools = RbVmomi::VIM.TraversalSpec(
      name: 'visitResourcePools', type: 'ResourcePool', path: 'vm', skip: false,
      selectSet: [recurse_folders]
    )

    find_clusters = RbVmomi::VIM.TraversalSpec(
      name: 'visitClusters', type: 'ClusterComputeResource', path: 'resourcePool', skip: false,
      selectSet: [recurse_folders]
    )

    find_folders = RbVmomi::VIM.TraversalSpec(
        name: 'ParentFolder', type: 'Folder', path: 'childEntity', skip: false,
        selectSet: [recurse_folders, find_vapps, find_machines, find_vm_hosts, find_resource_pools]
    )

    RbVmomi::VIM.PropertyFilterSpec(
      objectSet: [
        obj: root_folder,
        selectSet: [
          find_folders,
        ]
      ],
      propSet: [
        { type: 'VirtualMachine', pathSet: properties },
        { type: 'HostSystem', pathSet: ['hardware.cpuInfo.hz'] },
        { type: 'Folder', pathSet: ['name', 'childEntity'] },
        { type: 'ResourcePool', pathSet: ['vm'] },
        { type: 'ClusterComputeResource', pathSet: ['resourcePool'] }
      ]
    )
  end
end
