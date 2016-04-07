# Get current VM stats from vCenter for all VMs in config google sheet that have IP's associated
#   and output to screen in a real-time format.  Will run until interrupted (Ctrl-c)

require 'roo'
require 'active_support/time'
require 'rbvmomi'
require 'pry'

unless ARGV.length == 2
    puts "Error: Wrong number of parameters!"
    puts "Usage: get_vCenter_stats.rb <google user> <google password>"
    exit
end
 
# Setup your spreadsheet document key and credentials
key = "1qTagd2J3zEj8bL8ekj00agkeXUNb5IkXDRTkASNHEqk"
# NOTE:  This probably wont work after 5/5/15! 
#    https://developers.google.com/google-apps/spreadsheets/#about_authorization_protocols
user = ARGV[0]
password = ARGV[1]

# Config Spreadsheet row indexes
LoginRow = 3;      DataCenterRow = 4;      HeaderRow = 7;

# Spreadsheet column indexes
VcenterIp = 1;      UserName = 4;      Passwd = 6;          DefaultDC = 1

Operation  = 0;     NewDataCenter=1;   HostName = 2;        NewFolderName = 3;  NewVmName = 4;
TmplDataCenter=5;   TmplFolderName=6;  TemplateMachine = 7;           
CdromAttach = 8;    Orphan = 9;        DisconnectHost = 10; MachineState = 11;  IpAddress = 12;


# Open the google sheet
puts "\nOpening google sheet"
begin
    gsheet = Roo::Google.new(key, user: user, password: password)
rescue => e
    puts "  Error: opening google sheet: #{e.message}"
    abort "Aborting script"
end

def get_stats (connection, vm)
    pm = connection.serviceInstance.content.perfManager

    stats = pm.retrieve_stats([vm], ['cpu.usage', 'cpu.usagemhz', 'mem.consumed', 'virtualDisk.read', 
        'virtualDisk.write', 'net.received', 'net.transmitted'])
    metric = stats.first[1][:metrics]

    perfStats = {
        "cpuUsage" =>       metric['cpu.usage'][0],
        "cpuMhz" =>         metric['cpu.usagemhz'][0],
        "memConsumed" =>    metric['mem.consumed'][0],
        "vdiskRead" =>      metric['virtualDisk.read'][0],
        "vdiskWrite" =>     metric['virtualDisk.write'][0],
        "netRx" =>          metric['net.received'][0],
        "netXmit" =>        metric['net.transmitted'][0],
        "timestamp" =>      stats.first[1][:sampleInfo][0][:timestamp]
    }
    return perfStats
end


##################  Main Loop #################
begin
    # Widen the scope of vars used in loops
    server = nil;   userid = nil;   passwd = nil;   datacenter = nil; connection = nil;
    dc = nil;  vm = nil?

    configRows = gsheet.sheet('Config').first_row .. gsheet.sheet('Config').last_row
    vms = Array.new

    configRows.each do |row|
        rowData = gsheet.sheet('Config').row(row)

        # Extract connection and data center info
        if row == LoginRow 
            server = rowData[VcenterIp]
            userid = rowData[UserName]
            passwd = rowData[Passwd]
            print "Connecting to vCenter: #{server}, "
        end

        if row == DataCenterRow 
            datacenter = rowData[DefaultDC]
            puts "Data Center: #{datacenter}"

            connection = RbVmomi::VIM.connect :host => server, :user => userid, 
                :password => passwd, :insecure => true
            dc = connection.serviceInstance.find_datacenter(rowData[DefaultDC]) or abort "DataCenter not found, aborting script"
        end

        # Get machines from the Config sheet that have an ip address recorded and save in an array
        if rowData[IpAddress] =~ /\d+\./ and row > HeaderRow
            #puts "IP: #{rowData[IpAddress]}"

            # Add folder name to VM if defined
            if rowData[NewFolderName].to_s.empty?
                machine = rowData[NewVmName]
            else
                machine = "#{rowData[NewFolderName]}/#{rowData[NewVmName]}"
            end

            vms.push(machine)
        end
    end

    # Clear terminal screen
    system "clear"

    # Print vCenter stats until terminated
    while (1)
        # Move terminal cursor to top left
        system "tput cup 0 0"
        line = sprintf("%15s%18s%8s%8s%12s%8s%8s%8s%8s%27s", 'NewVmName','IpAddress','cpuU',
        'cpuMhz','memory','vdiskR','vdiskW','netRx','netXt','timestamp').green
        puts line
 
        vms.each { |thisMachine| 

            vm = dc.find_vm(thisMachine) or abort "edit_machine: VM not found"
            stats = get_stats(connection,vm)

            # Chop off folder name if present
            if thisMachine.length > 15
                thisMachine = thisMachine.slice(-15, 15)
            end
            line = sprintf("%15s%18s%8d%8d%12d%8d%8d%8d%8d%27s", thisMachine,"na",stats['cpuUsage'],
                stats['cpuMhz'],stats['memConsumed'],stats['vdiskRead'],stats['vdiskWrite'],stats['netRx'],
                stats['netXmit'],stats['timestamp'])
            puts line
        }
        # vCener updates stats every 20 secs.
        sleep 20
    end

#binding.pry

rescue => e
    puts "  Error: #{e.message}"
    puts e.backtrace
ensure
    puts "\nClosing vCenter connection"
    connection.close
end
