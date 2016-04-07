require 'rbvmomi'
require 'uuid'
require 'pry'

# Create orphan machine by deleting all VM's files
def orphan_vm(vm)
  # Find all VM's datastore files then delete
  files = vm.layoutEx.file.map { |f| [f.name][0] }
  fm = vm.datastore[0]._connection.serviceContent.fileManager
  files.each do |filepath|
    puts "Deleting: #{filepath}"
    fm.DeleteDatastoreFile_Task(:name => filepath, :datacenter => dc).wait_for_completion     
  end  
end


# Add a ISO backed CDROM to a VM
# https://www.snip2code.com/Snippet/83525/This-gist-will-add-a-cd-that-has-an-iso-
def add_cdrom (vm)

  machine_conf_spec = RbVmomi::VIM::VirtualMachineConfigSpec(
    :deviceChange => [{
      :operation => :edit,
      :device => RbVmomi::VIM::VirtualCdrom(
        :backing => RbVmomi::VIM.VirtualCdromIsoBackingInfo(
          :fileName => "[Shared-SAN] ISO/CentOS-6.6-x86_64-minimal.iso"
        ),
        :key => 3000,
        :controllerKey => 200,
        :connectable => RbVmomi::VIM::VirtualDeviceConnectInfo(
          :startConnected => true,
          :connected => true,
          :allowGuestControl => true)
      )
    }]
  )

  vm.ReconfigVM_Task(spec: machine_conf_spec).wait_for_completion
  puts "add_cdrom: Success"
end

# Check if a folder exists in a data center, if not, create it
def create_folder (dc, folder) 
  dc.vmFolder.childEntity.each do |childEntity|
    name, junk = childEntity.to_s.split('(')
    if name == 'Folder' && childEntity.name == folder
        #puts "Folder exists: " + x.name
        return false, childEntity
    end
  end
  # Create the folder
  return true, dc.vmFolder.CreateFolder(:name => folder).wait_for_completion    
end

# Change VM's power status
def vm_power (vm, cmd)
  case cmd
    when 'on'
      vm.PowerOnVM_Task.wait_for_completion
    when 'off'
      vm.PowerOffVM_Task.wait_for_completion
    when 'reset'
      vm.ResetVM_Task.wait_for_completion
    when 'suspend'
      vm.SuspendVM_Task.wait_for_completion
    when 'destroy'
      vm.Destroy_Task.wait_for_completion
    else
      puts "vm_power: invalid command"
      return false
  end
  puts "vm_power: machine status changed : '#{cmd}' OK"
  return true
end

# Clone an existing machine
def clone_machine(server, user, password, data_center, machine_to_clone, name_prefix, host_name, folder, number_of_times)
  begin
    connection = RbVmomi::VIM.connect :host => server, :user => user, :password => password, :insecure => true
    dc = connection.serviceInstance.find_datacenter(data_center) or abort "datacenter not found"
    vm = dc.find_vm(machine_to_clone) or abort "VM not found"
    host = connection.searchIndex.FindByDnsName(:dnsName => host_name, :vmSearch => false)
    parent_folder = vm.parent

    #binding.pry

    relocate_spec = RbVmomi::VIM::VirtualMachineRelocateSpec(:diskMoveType => :moveChildMostDiskBacking) 
    #                                                          :host => host)
    
    spec = RbVmomi::VIM::VirtualMachineCloneSpec(:location => relocate_spec,
                                                 :powerOn => true,
                                                 :template => false)
    
    # Set folder for this VM
    if folder == nil
      default_folder = parent_folder
        puts "Folder: Using cloned machine's parent"
    else
      res, new_folder = create_folder(dc, folder)
      if res
        puts "Folder: '#{new_folder.name}' Created"
      else
        puts "Folder: '#{new_folder.name}' Exists"
      end
      default_folder = new_folder
    end  

    number_of_times.times do
      new_vm_name =  name_prefix + UUID.new.generate
      puts "Creating #{new_vm_name}"
      new_vm = vm.CloneVM_Task(:folder => default_folder, :name => new_vm_name , :spec => spec).wait_for_completion
      puts "Successfully created #{new_vm_name}"

      # Change power status for this VM
      #vm_power(new_vm, 'off')

    end
  rescue => e
    puts e.message
    puts e.backtrace
  ensure
    connection.close
  end
end

# Edit an existing machine
def edit_machine (server, user, password, data_center, machine)
  begin
    connection = RbVmomi::VIM.connect :host => server, :user => user, :password => password, :insecure => true
    dc = connection.serviceInstance.find_datacenter(data_center) or abort "datacenter not found"
    vm = dc.find_vm(machine) or abort "edit_machine: VM not found"
    puts "edit_machine: Machine found: '#{vm.name}'"

    # Change power status for this VM
    #vm_power(vm, 'on')

    # Add a CDROM
    #add_cdrom(vm)

    # Dis/Reconnect this VM's host
    #host1 = dc.hostFolder.children.first.host
    # Find this VM's host
    #host = vm.runtime.host
    #host.DisconnectHost_Task.wait_for_completion
    #host.ReconnectHost_Task.wait_for_completion

    #cluster = host.parent
    host_name = 'esx27.dev.ral.6fusion.com'
    clusters = dc.hostFolder.children

    host = connection.searchIndex.FindByDnsName(
      :dnsName => host_name, :vmSearch => false
    )
    binding.pry

  rescue => e
    puts e.message
    puts e.backtrace
  ensure
    connection.close
  end

end


#Change the input parameters below
#clone_machine('<IP Address of vCenter>', '<vCenter Username>', '<vCenter Password>', '<Datacneter Name>', 
#    '<Name of an Existing Machine>','<Prefix of VM Name>', '<Folder Name> (or nil)', '<Number of VMs to Create>')
clone_machine('192.168.130.22', 'administrator@vsphere.local', 'vmware', 'DC-Main', 
    'Base03-VMtools','Bob-Script2-test-', 'esx27.dev.ral.6fusion.com', nil, 1)

#edit_machine('192.168.130.22', 'administrator@vsphere.local', 'vmware', 'DC-Main', 
#  'Bob-Script2-test-90c85340-b395-0132-5a86-406c8f4a61f3')
 

