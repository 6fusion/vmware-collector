# Script to check log for vmware-meter errors
# 5/27/15, Bob S.
require 'rubygems'
require 'net/ssh'
require 'pry'
require 'trollop'

opts = Trollop.options do 
    banner <<-EOS

vm-meter_log_scan:  Scan a vm-meter log for errors
Usage:
    ruby vm-meter_log_scan.rb [options]

Where [options] are:
EOS
    opt :address, 'meter ssh address [required] ', :type => :string, :required => true
    opt :user, 'meter ssh user', :type => :string, :required => true
    opt :password, 'meter ssh password', :type => :string, :required => true
end

known_errors = [
    '429 Too Many Requests',
    '400 Bad Request',
    'ERROR -- :',
    'error:',
    'uc6-connector(ERROR)',
    'undefined method',
    'NoMethodError',
    'FATAL',
    'NotAuthenticated',
    'Problem:',
    'failed state'
]


#@cmd = "nohup /home/rgs/consume.sh 60"
#@cmd = "ls -la"

begin

    ssh = Net::SSH.start(opts[:address], opts[:user], :password => opts[:password])

    known_errors.each do |err|
    
        #res = ''
        @cmd = "journalctl  --no-tail | grep '#{err}' | wc -l"
        res = ssh.exec!(@cmd).strip

        if res != '0'
            puts "'#{err}':  #{res}"
        end

    end

    #ssh.exec @cmd
    ssh.close

rescue
    puts "Unable to connect to #{@hostname} using #{@username}/#{@password}"
end