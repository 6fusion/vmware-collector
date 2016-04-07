# Get current VM stats from vCenter for all VMs named in a text file
#   and output to screen in a real-time format.  Will run until interrupted (Ctrl-c)

require 'active_support/time'
require 'rbvmomi'
require 'pry'

unless ARGV.length == 2
    puts "Error: Wrong number of parameters!"
    puts "Usage: get_vCenter_stats.rb <data center> <VM name file>"
    exit
end
 
# Constants
Vcenter = '192.168.130.22'
User = 'administrator@vsphere.local'
Password = 'vmware'

# To colorize log output
class String
    def red;    "\033[31m#{self}\033[0m" end
    def green;  "\033[32m#{self}\033[0m" end
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

    datacenter = ARGV[0]
    filename = ARGV[1]
    if File.file?(filename) == false
        puts "Error: Can't find VM names file '#{filename}"
        abort "Aborting script"
    end
    vms = IO.readlines filename

    connection = RbVmomi::VIM.connect :host => Vcenter, :user => User, 
        :password => Password, :insecure => true
    dc = connection.serviceInstance.find_datacenter(datacenter) or abort "DataCenter not found, aborting script"

    # Clear terminal screen
    system "clear"

    # Print vCenter stats until terminated
    while (1)
        # Move terminal cursor to top left
        system "tput cup 0 0"
        line = sprintf("%20s%18s%8s%8s%12s%8s%8s%8s%8s%27s", 'NewVmName','IpAddress','cpuU',
        'cpuMhz','memory','vdiskR','vdiskW','netRx','netXt','timestamp').green
        puts line
 
        vms.each { |thisMachine| 
            thisMachine = thisMachine.strip

            vm = dc.find_vm(thisMachine) or abort "VM not found: #{thisMachine}"
            stats = get_stats(connection,vm)

            # Trunc folder/name for display
            if thisMachine.length > 20
                thisMachine = thisMachine.slice(-20, 20)
            end

            line = sprintf("%20s%18s%8d%8d%12d%8d%8d%8d%8d%27s", thisMachine,"na",stats['cpuUsage'],
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
