require 'vsphere_session'

def destroy_vm(vm_name = "TEST", datacenter='DC-Main')
  vim = VSphere::session
  dc = vim.serviceInstance.find_datacenter(datacenter) or abort "datacenter not found"
  vm = dc.find_vm(vm_name)
  vm.Destroy_Task.wait_for_completion unless vm.nil?
end

# May want to make datacenter_path configurable
# For some reason doesn't work here: vim.serviceInstance.find_datacenter(nil) or abort "datacenter not found"
def create_vm(vm_name = "TEST", datacenter='DC-Main')
  vim = VSphere::session
  dc = vim.serviceInstance.find_datacenter(datacenter) or abort "datacenter '#{datacenter}' not found."

  vm = dc.find_vm(vm_name)

  return vm if vm

  vmFolder = dc.vmFolder
  hosts = dc.hostFolder.children
  rp = hosts.first.resourcePool

  vm_path = dc.datastore.first.info.name

  vm_cfg = {
    name: vm_name,
    guestId: 'otherGuest',
    files: { vmPathName: "[#{vm_path}] #{vm_name}" },
    numCPUs: 1,
    memoryMB: 128,
    deviceChange: [
      {
        operation: :add,
        device: RbVmomi::VIM.VirtualLsiLogicController(
          key: 1000,
          busNumber: 0,
          sharedBus: :noSharing,
        )
      },
      {
        operation: :add,
        fileOperation: :create,
        device: RbVmomi::VIM.VirtualDisk(
          key: 0,
          backing: RbVmomi::VIM.VirtualDiskFlatVer2BackingInfo(
            fileName: "[#{vm_path}] #{vm_name}",
            diskMode: :persistent,
            thinProvisioned: true,
          ),
          controllerKey: 1000,
          unitNumber: 0,
          capacityInKB: 4000000,
        )
      },
      {
        operation: :add,
        device: RbVmomi::VIM.VirtualE1000(
          key: 0,
          deviceInfo: {
            label: 'Network Adapter 1',
            summary: 'VM Network',
          },
          backing: RbVmomi::VIM.VirtualEthernetCardNetworkBackingInfo(
            deviceName: 'VM Network',
          ),
          addressType: 'generated'
        )
      }
    ],
    extraConfig: [
      {
        key: 'bios.bootOrder',
        value: 'ethernet0'
      }
    ]
  }

  vmFolder.CreateVM_Task(:config => vm_cfg, :pool => rp).wait_for_completion
end

