require 'rubygems'
require 'net/ssh'

@hostname = "172.20.2.215"
@username = "rgs"
@password = "vmware"
@cmd = "/home/rgs/consume.sh 1m"

 begin
    ssh = Net::SSH.start(@hostname, @username, :password => @password)
    res = ssh.exec!(@cmd)
    ssh.close
    puts res
  rescue
    puts "Unable to connect to #{@hostname} using #{@username}/#{@password}"
  end