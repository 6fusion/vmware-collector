# Ruby script to provision a VMware vCenter with data from a Google spreadsheet.
# vCenter address and credentials are extracted from sheet
# 5/1/15. Bob S.

#require 'google/api_client'
#require 'google/api_client/client_secrets'
require 'google/api_client/auth/file_storage'
require 'google/api_client/auth/installed_app'
require 'google_drive'
require 'rbvmomi'
require 'roo-google'
require 'pry'

# Setup your shared Google spreadsheet document key
# (ex: 'Vcenter Test Config')
# vCenter 5.x config
Document_key = "1qTagd2J3zEj8bL8ekj00agkeXUNb5IkXDRTkASNHEqk"
# vCenter 6.0 config
#Document_key = "1f1aGjk-OQ2c0L65mFNYDsddCH98dyuucnGuvyMyrTiM"

# Spreadsheet row indexes
LoginRow = 3;      DataCenterRow = 4;      HeaderRow = 7;

# Spreadsheet column indexes
VcenterIp = 1;      UserName = 4;      Passwd = 6;          DefaultDC = 1

Operation  = 0;     NewDataCenter=1;   HostName = 2;        NewFolderName = 3;  NewVmName = 4;
TmplDataCenter=5;   TmplFolderName=6;  TemplateMachine = 7;           
CdromAttach = 8;    Orphan = 9;        DisconnectHost = 10; MachineState = 11;  IpAddress = 12;
 
# To colorize log output
class String
    def red;    "\033[31m#{self}\033[0m" end
    def green;  "\033[32m#{self}\033[0m" end
end

# Handles authentication of a google user and returns an oauth2 token. Requires that file exists containing
# oauth2 'secrets'
def get_goog_auth_token()
    credential_storage_file = "#{$0}-oauth2.json"
    secrets_file = 'client_secrets.json'

    # Make sure client_secrets.json file exists
    if File.file?(secrets_file) == false
        puts "Error: Can't find client secrets file '#{secrets_file}' to access google sheets!" 
        puts "       Use these instructions to get a 'client_id' and 'client_secrets'"
        puts "         https://developers.google.com/identity/protocols/OpenIDConnect"
        puts "       File format is here:"
        puts "         https://developers.google.com/api-client-library/dotnet/guide/aaa_client_secrets"
        abort
    end 

    client = Google::APIClient.new(:application_name => 'Google Docs Ruby Access',
          :application_version => '1.0.0')

    # FileStorage stores auth credentials in a file, so they survive multiple runs
    # of the application. This avoids prompting the user for authorization every
    # time the access token expires, by remembering the refresh token.
    # Note: If required, this will automatically open a browser window to authorize access to this program.
    #       If you change any of the code below, be sure to delete the 'CREDENTIAL_STORE_FILE'!!
    file_storage = Google::APIClient::FileStorage.new(credential_storage_file)
    if file_storage.authorization.nil?
        client_secrets = Google::APIClient::ClientSecrets.load
        flow = Google::APIClient::InstalledAppFlow.new(
            :client_id => client_secrets.client_id,
            :client_secret => client_secrets.client_secret,
            :scope => ['https://spreadsheets.google.com/feeds','https://www.googleapis.com/auth/drive']
        )
        client.authorization = flow.authorize(file_storage)
    else
        client.authorization = file_storage.authorization
    end

    return client.authorization.access_token
end

# Clone an existing machine
def clone_machine(connection, new_data_center, host_name, new_vm_folder, new_machine_name,
                  tmpl_datacenter, tmpl_foldername, machine_to_clone)

    if tmpl_foldername != nil
        machine_to_clone = tmpl_foldername + '/' + machine_to_clone
    end

    vm = tmpl_datacenter.find_vm(machine_to_clone) 

    if vm == nil
        puts "  Error: clone_machine: Machine '#{machine_to_clone } to clone not found".red
        return false
    end

    if host_name != nil
        host = connection.searchIndex.FindByDnsName(:dnsName => host_name, :vmSearch => false)
    end

    relocate_spec = RbVmomi::VIM::VirtualMachineRelocateSpec(:diskMoveType => :moveChildMostDiskBacking, :host => host)    
    spec = RbVmomi::VIM::VirtualMachineCloneSpec(:location => relocate_spec, :powerOn => false, :template => false)
    
    # Set folder for this VM
    if new_vm_folder == nil
        default_folder = new_data_center.vmFolder
        puts "clone_machine: Using root VM folder"
    else
        res, new_folder = create_folder(new_data_center, new_vm_folder)
        if res
            puts "clone_machine: folder '#{new_folder.name}' Created OK".green
        #else
            #puts "clone_machine: folder '#{new_folder.name}' Exists"
        end
        default_folder = new_folder
    end 

    puts "clone_machine: Creating machine: '#{new_machine_name}'"
    begin
        new_vm = vm.CloneVM_Task(:folder => default_folder, :name => new_machine_name , 
            :spec => spec).wait_for_completion
    rescue => e
        puts "  Error: clone_machine: #{e.message}".red
        puts e.backtrace
        return false
    end
    puts "clone_machine: Created #{new_machine_name} OK".green
    return new_vm
end

# Change VM's power status
def vm_power (vm, cmd)

    current_state = vm.runtime.powerState
    name = vm.name

    begin
        case cmd
            when 'on'
                if current_state != 'poweredOn'
                    vm.PowerOnVM_Task.wait_for_completion
                end
            when 'off'
                if current_state != 'poweredOff'
                    vm.PowerOffVM_Task.wait_for_completion
                end
            when 'reset'
                vm.ResetVM_Task.wait_for_completion
            when 'suspend'
                if current_state != 'suspended'
                    # Machine must be powered on before it can be suspended
                    if current_state != 'poweredOn'
                        vm.PowerOnVM_Task.wait_for_completion
                    end  
                    vm.SuspendVM_Task.wait_for_completion
                end
            when 'destroy'
                vm.Destroy_Task.wait_for_completion
        else
            puts "vm_power: invalid command: '#{cmd}'"
            return false
        end
    rescue => e
        puts "  Error: vm_power: #{e.message}".red
        return false
    end
    puts "vm_power: machine '#{name}' status set: '#{cmd}' OK".green
    return true
end

# Add a ISO backed CDROM to a VM
# https://www.snip2code.com/Snippet/83525/This-gist-will-add-a-cd-that-has-an-iso-
def add_cdrom (vm)

    machine_conf_spec = RbVmomi::VIM::VirtualMachineConfigSpec(
        :deviceChange => [{
            :operation => :add,
            :device => RbVmomi::VIM::VirtualCdrom(
                :backing => RbVmomi::VIM.VirtualCdromIsoBackingInfo(
                :fileName => "[Shared-SAN] ISO/CentOS-6.6-x86_64-minimal.iso"
            ),
            :key => 3002,
            :controllerKey => 200,
            :connectable => RbVmomi::VIM::VirtualDeviceConnectInfo(
                :startConnected => true,
                :connected => true,
                :allowGuestControl => true)
            )
        }]
    )

    begin
        vm.ReconfigVM_Task(spec: machine_conf_spec).wait_for_completion
    rescue => e
        puts "  Error: add_cdrom: #{e.message}".red
        return false
    end
    puts "add_cdrom: CDROM added OK".green
    return true
end

# Check if a folder exists in a data center, if not, create it
def create_folder (dc, folder_name) 

    dc.vmFolder.childEntity.each do |childEntity|
        name, junk = childEntity.to_s.split('(')
        if name == 'Folder' && childEntity.name == folder_name
            #puts "Folder exists: " + x.name
            return false, childEntity
        end
    end
        
    # Create the folder
    begin
        folder = dc.vmFolder.CreateFolder(:name => folder_name)   
    rescue => e
        puts "  Error: create_folder: #{e.message}".red
        return false, nil
    end
    puts "create_folder: Folder '#{folder_name} created OK".green
    return true, folder
end

# Create orphan machine by deleting all VM's files
def orphan_vm(dc, vm)

    # Find all VM's datastore files then delete
    files = vm.layoutEx.file.map { |f| [f.name][0] }
    fm = vm.datastore[0]._connection.serviceContent.fileManager
    files.each do |filepath|
    puts "orphan_vm: '#{vm.name}' Deleting file: #{filepath}"
    fm.DeleteDatastoreFile_Task(:name => filepath, :datacenter => dc).wait_for_completion     
    end 
    
    begin
        # For some reason this marks the machine as '(orphaned)' in vCenter and allows the next
        # Destroy_Task to remove this VM
        vm.Destroy_Task.wait_for_completion 
    rescue => e
        # This throws a FileNotFound error (that will be ignored) the first time a destroy is attempted
        #   The machine can be deleted on the second attempt.
        #puts "  Error: orphan_vm: #{e.message}".red
    end
    puts "orphan_vm: Machine '#{vm.name}' orphaned OK".green
end


##################  Main Loop #################
begin

    # Widen the scope of vars used in loops
    server = nil;   userid = nil;   passwd = nil;   datacenter = nil; connection = nil;
    dc = nil;  vm = nil?

    puts "\nOpening google sheet"
    gsheet = Roo::Google.new(Document_key, access_token: get_goog_auth_token)
    #gsheet = Roo::Google.new(key, user: user, password: password)

    rows = gsheet.sheet('Config').first_row .. gsheet.sheet('Config').last_row
 
    rows.each do |row|
        rowData = gsheet.sheet('Config').row(row)

        # Extract connection and data center info
        if row == LoginRow 
            server = rowData[VcenterIp]
            userid = rowData[UserName]
            passwd = rowData[Passwd]
            print "Connecting to vCenter: #{server}, "
        end

        if row == DataCenterRow 
            defaultDC = rowData[DefaultDC]
            puts "Default Data Center: #{defaultDC}"

            Timeout::timeout(10) {
                connection = RbVmomi::VIM.connect :host => server, :user => userid, 
                :password => passwd, :insecure => true
            }
        end

        # Extract machine data, abort if Operation isn't set
        break if rowData[Operation].to_s.empty? and row > HeaderRow
        
        if row > HeaderRow 

            # Set defaults for empty cells
            rowData[HostName].to_s.empty?       ? hostname = nil              : hostname = rowData[HostName]
            rowData[NewFolderName].to_s.empty?  ? new_foldername = nil        : new_foldername = rowData[NewFolderName]
            rowData[NewDataCenter].to_s.empty?  ? new_datacenter = defaultDC  : new_datacenter = rowData[NewDataCenter]
            rowData[TmplFolderName].to_s.empty? ? tmpl_foldername = nil       : tmpl_foldername = rowData[TmplFolderName]
            rowData[TmplDataCenter].to_s.empty? ? tmpl_datacenter = defaultDC : tmpl_datacenter = rowData[TmplDataCenter]

            dc = connection.serviceInstance.find_datacenter(new_datacenter) or abort "New DataCenter not found, aborting script"
            tmpl_dc = connection.serviceInstance.find_datacenter(tmpl_datacenter) or abort "Template DataCenter not found, aborting script"
            vm_path = "#{new_foldername}/#{rowData[NewVmName]}"

            case rowData[Operation]
            when 'add'
                puts "Adding machine at row: #{row}: '#{vm_path}'"

                vm = clone_machine(connection, dc, hostname, new_foldername, rowData[NewVmName], tmpl_dc, tmpl_foldername, rowData[TemplateMachine])

                if vm != false

                    if rowData[CdromAttach] == 'yes'
                        add_cdrom(vm)
                    end

                    if rowData[Orphan] == 'yes'
                        orphan_vm(dc, vm)
                        gsheet.set(row, IpAddress+1, '??')
                    end

                    if rowData[DisconnectHost] == 'yes'
                        this_host = vm.runtime.host
                        puts "Disconnecting host: '#{this_host.name}'"
                        this_host.DisconnectHost_Task.wait_for_completion
                        gsheet.set(row, IpAddress+1, '??')
                    end

                    if rowData[MachineState].to_s.empty? == false
                        vm_power(vm, rowData[MachineState])
                    end
                end
                gsheet.set(row, IpAddress+1, '??')

            when 'delete'
                puts "Deleting machine at row: #{row}: '#{vm_path}'"
                vm = dc.find_vm(vm_path)
                if vm == nil
                    puts "  Error: Delete VM, machine #{vm_path} not found".red
                else
                    vm_power(vm, 'off')
                    vm_power(vm, 'destroy')
                    gsheet.set(row, IpAddress+1, '??')
                end 

            when 'get_ip_address'
                puts "Getting IP Address, row: #{row}"
                vm = dc.find_vm(vm_path)
                if vm == nil
                    puts "  Error: Get IP Address, machine #{vm_path} not found".red
                    gsheet.set(row, IpAddress+1, '??')
                else
                    vm_ip = vm.guest_ip
                    if vm_ip == nil
                        vm_ip = '??'
                    end
                    puts "Machine: '#{rowData[NewVmName]}' IP Address: #{vm_ip}"
                    gsheet.set(row, IpAddress+1, vm_ip)
                end 

            when 'on'
                puts "Powering on machine at row: #{row}: '#{vm_path}'"
                vm = dc.find_vm(vm_path)
                if vm == nil
                    puts "  Error: Power on VM, machine #{vm_path} not found".red
                else
                    vm_power(vm, 'on')
                    gsheet.set(row, IpAddress+1, '??')
                end 

            when 'off'
                puts "Powering off machine at row: #{row}: '#{vm_path}'"
                vm = dc.find_vm(vm_path)
                if vm == nil
                    puts "  Error: Power off VM, machine #{vm_path} not found".red
                else
                    vm_power(vm, 'off')
                    gsheet.set(row, IpAddress+1, '??')
                end 

            when 'skip'
                puts "Skipping machine at row: #{row}: '#{vm_path}'"
            else 
                puts "  Error: Invalid operation: '#{rowData[Operation]}' on row #{row}".red
                #break
            end
        end
    end

    #puts "Test: #{gsheet.cell(1,"A",gsheet.sheets[1])}"

rescue => e
    puts "  Error: #{e.message}".red
    puts e.backtrace
ensure
    if connection.nil?
        puts "Done!"
    else
        puts "Closing vCenter connection"
        connection.close
    end
end

#binding.pry
