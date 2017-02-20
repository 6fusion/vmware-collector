#!/usr/bin/env ruby
# Get current VM usage stats from vCenter for all VMs named in a YAML config file
#   and output to screen in a real-time format.  Will run until interrupted (Ctrl-c)
# 8/23/2016 - Bob S.

require 'active_support/time'
require 'rbvmomi'
require 'pry'
require 'psych'
require 'trollop'
 
Yaml_file = "get_vcenter_stats.yml"

opts = Trollop.options do 
    banner <<-EOS

get_vcenter_stats: Get current VM stats from vCenters. Configuration YAML file required.
                   Stats are listed in columns and refreshed each period.  
Usage:
    ruby get_vcenter_stats.rb [options]

Where [options] are:
EOS
    opt :file, "YAML file that contains VSphere config", :type => :string, :default => Yaml_file
    opt :period, "Update period in seconds (20 sec. minimum)", :type => :int, :default => 20
    opt :clear, "Clear screen each period", :default => true 
end

# Constants
# Load yaml config file
VC_config = Psych.load_file(opts[:file]).deep_symbolize_keys
Vspheres = VC_config[:vspheres]
Line_format = "%12s%30s%20s%8s%8s%12s%8s%8s%8s%8s%27s"

# To colorize log output
class String
    def red;    "\033[31m#{self}\033[0m" end
    def green;  "\033[32m#{self}\033[0m" end
end

def get_stats (connection, vsphere, dc, dcname, vms)

    vms.each do |thisMachine| 
        thisMachine = thisMachine.strip

        vm = dc.find_vm(thisMachine) or abort "VM not found: #{thisMachine}"

        pm = connection.serviceInstance.content.perfManager

        stats = pm.retrieve_stats([vm], ['cpu.usage', 'cpu.usagemhz', 'mem.consumed', 'virtualDisk.read', 
            'virtualDisk.write', 'net.received', 'net.transmitted'])
        metric = stats.first[1][:metrics]

        stats = {
            "cpuUsage" =>       metric['cpu.usage'][0],
            "cpuMhz" =>         metric['cpu.usagemhz'][0],
            "memConsumed" =>    metric['mem.consumed'][0],
            "vdiskRead" =>      metric['virtualDisk.read'][0],
            "vdiskWrite" =>     metric['virtualDisk.write'][0],
            "netRx" =>          metric['net.received'][0],
            "netXmit" =>        metric['net.transmitted'][0],
            "timestamp" =>      stats.first[1][:sampleInfo][0][:timestamp]
        }

        # Trunc folder/name for display
        if thisMachine.length > 20
            thisMachine = thisMachine.slice(-20, 20)
        end

        puts sprintf(Line_format, vsphere[:name],dcname,thisMachine,stats['cpuUsage'],
            stats['cpuMhz'],stats['memConsumed'],stats['vdiskRead'],stats['vdiskWrite'],stats['netRx'],
            stats['netXmit'],stats['timestamp'])
    end
end

def open_vcenter (vcenter)

     connection = RbVmomi::VIM.connect :host => vcenter[:access][:address], :user => vcenter[:access][:user], 
        :password => vcenter[:access][:password], :insecure => true
end


##################  Main Loop #################
begin

    begin

        system "clear"
        puts sprintf(Line_format, 'VSphere', 'DataCenter','VmName','cpuU',
        'cpuMhz','memory','vdiskR','vdiskW','netRx','netXt','timestamp').green

        while(1)

            if opts[:clear]
                system "clear" 
                puts sprintf(Line_format, 'VSphere', 'DataCenter','VmName','cpuU',
                'cpuMhz','memory','vdiskR','vdiskW','netRx','netXt','timestamp').green
            end

            Vspheres.each  do |vkey, vcenter|

                # Connect to this vcenter
                connection = open_vcenter (vcenter)

                vcenter[:datacenters].each do |dkey, datacenter|

                    # Find this datacenter
                    dc = connection.serviceInstance.find_datacenter(datacenter[:name]) or abort "DataCenter '#{datacenter[:name]}' not found, aborting script"

                    # Get and put stats for each machine
                    get_stats(connection, vcenter, dc, datacenter[:name], datacenter[:vms])
                end

                connection.close

            end

            # Sleep between cycles (new VCenter data is only avail every 20 secs)
            if opts[:period] > 20
                sleep opts[:period]
            else
                sleep 20
            end

        end
            
    rescue => e
        puts "  Error: #{e.message}"
        puts e.backtrace
    end

rescue Exception
    puts "\nGood bye"
end

