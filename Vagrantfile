# -*- mode: ruby -*-
# # vi: set ft=ruby :

require 'base64'
require 'fileutils'
require 'open-uri'
require 'tempfile'
require 'yaml'

Vagrant.require_version ">= 1.6.0"

$update_channel = "alpha"

CLUSTER_IP="10.3.0.1"
NODE_IP = "172.17.4.99"
NODE_MEMORY_SIZE = 2048
USER_DATA_PATH = File.expand_path("user-data")


Vagrant.configure("2") do |config|
  # always use Vagrant's insecure key
  config.ssh.insert_key = false

  config.vm.box = "coreos-%s" % $update_channel
  config.vm.box_version = ">= 1122.0.0"
  config.vm.box_url = "http://%s.release.core-os.net/amd64-usr/current/coreos_production_vagrant.json" % $update_channel

  config.vm.provider :virtualbox do |v|
    v.cpus = 1
    v.gui = false
    v.memory = NODE_MEMORY_SIZE

    # On VirtualBox, we don't have guest additions or a functional vboxsf
    # in CoreOS, so tell Vagrant that so it can be smarter.
    v.check_guest_additions = false
    v.functional_vboxsf     = false
  end

  unless File.exists?('ssl/ca.pem')
    system("mkdir -p ssl && ./init-ssl-ca ssl") or abort ("failed generating SSL CA artifacts")
    system("./init-ssl ssl apiserver controller IP.1=#{NODE_IP},IP.2=#{CLUSTER_IP}") or abort ("failed generating SSL certificate artifacts")
    system("./init-ssl ssl admin kube-admin") or abort("failed generating admin SSL artifacts")
  end
  config.vm.provision :shell, inline: 'mkdir -p /etc/kubernetes/ssl'
  config.vm.synced_folder 'ssl', '/etc/kubernetes/ssl', id: "ssl", nfs: true, :mount_options => ['nolock,vers=3,udp']

  config.vm.provision :file, :source => USER_DATA_PATH, :destination => "/tmp/vagrantfile-user-data"
  config.vm.provision :shell, :inline => "mv /tmp/vagrantfile-user-data /var/lib/coreos-vagrant/", :privileged => true

  config.vm.provision :shell, inline: 'mkdir -p /home/core/app/lib'
  config.vm.synced_folder 'lib', '/home/core/app/lib', id: "lib", nfs: true, :mount_options => ['nolock,vers=3,udp']
  config.vm.provision :shell, inline: 'mkdir -p /home/core/app/bin'
  config.vm.synced_folder 'bin', '/home/core/app/bin', id: "bin", nfs: true, :mount_options => ['nolock,vers=3,udp']

  # plugin conflict
  if Vagrant.has_plugin?("vagrant-vbguest") then
    config.vbguest.auto_update = false
  end

  config.vm.network :private_network, ip: NODE_IP

  config.vm.provision :shell, inline: 'mkdir -p /opt/bin'
  config.vm.provision :shell, inline: '[ -e /opt/bin/kubectl ] || curl -s -o /opt/bin/kubectl https://storage.googleapis.com/kubernetes-release/release/v1.3.4/bin/linux/amd64/kubectl'
  config.vm.provision :shell, inline: 'chmod 755 /opt/bin/kubectl'


  # Load in vmware collector kubernetes definitions
  #  Inject development configuration
  #  Mount src directories into containers for faster/live development (i.e., changes are picked up with a pod
  main_yaml = YAML::load_stream(File.read("vmwarecollector.yaml"))
  api_yaml = YAML::load_file('config/development/api.yaml')
  api_yaml['data'].each{|k,v|
    api_yaml['data'][k] = Base64.encode64(v.to_s) }
  vsphere_yaml = YAML::load_file('config/development/vsphere.yaml')
  vsphere_yaml['data'].each{|k,v|
    vsphere_yaml['data'][k] = Base64.encode64(v.to_s) }

  # inventory collector RC
  main_yaml[5]['spec']['template']['spec']['containers'][0]['volumeMounts'] << { 'name' => 'lib', 'mountPath' => '/usr/src/app/lib' }
  main_yaml[5]['spec']['template']['spec']['volumes'] << { 'name' => 'lib', 'hostPath' => { 'path' => '/home/core/app/lib' } }
  main_yaml[5]['spec']['template']['spec']['containers'][0]['volumeMounts'] << { 'name' => 'bin', 'mountPath' => '/usr/src/app/bin' }
  main_yaml[5]['spec']['template']['spec']['volumes'] << { 'name' => 'bin', 'hostPath' => { 'path' => '/home/core/app/bin' } }

  # metrics collector RC
  main_yaml[6]['spec']['template']['spec']['containers'][0]['volumeMounts'] << { 'name' => 'lib', 'mountPath' => '/usr/src/app/lib' }
  main_yaml[6]['spec']['template']['spec']['volumes'] << { 'name' => 'lib', 'hostPath' => { 'path' => '/home/core/app/lib' } }
  main_yaml[6]['spec']['template']['spec']['containers'][0]['volumeMounts'] << { 'name' => 'bin', 'mountPath' => '/usr/src/app/bin' }
  main_yaml[6]['spec']['template']['spec']['volumes'] << { 'name' => 'bin', 'hostPath' => { 'path' => '/home/core/app/bin' } }

  # Update secrets
  main_yaml[2] = api_yaml
  main_yaml[3] = vsphere_yaml
  main_yaml_string = ""
  main_yaml.each{|doc| main_yaml_string += "#{doc.to_yaml}\n---" }
  cmd = "echo '#{main_yaml_string}' > vmwarecollector.yaml"
  config.vm.provision :shell, inline: cmd

end
