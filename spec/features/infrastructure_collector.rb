require 'feature_helper'
require 'infrastructure_collector'

# These tests are STATIC and assume using vcn13.dev.ral.6fusion.com
# Doesn't seem to be a way to use RbvMomi to create datacenters, so must hard code for now
# Doesn't test for every property, but should be enough to detect if something's broken

describe InfrastructureCollector do
  DATA_CENTER_NAME = 'DC-Main'
  TEMP_MACHINES = ['ex_inv_1', 'ex_inv_2']

  before(:all) do
    DatabaseCleaner.clean

    TEMP_MACHINES.each {|temp_machine| create_vm(temp_machine, DATA_CENTER_NAME) }
    collector = InfrastructureCollector.new
    collector.run
    @infrastructures = Infrastructure.all.to_a
    @infrastructure = Infrastructure.first
  end

  after(:all) do
    TEMP_MACHINES.each {|temp_machine| destroy_vm(temp_machine, DATA_CENTER_NAME)}
    DatabaseCleaner.clean
  end

  # All expectations are in one it here to avoid hitting vSphere too many times
  # Not necessary to split these up
  it "works properly" do
    @infrastructures.size.must_equal 1

    @infrastructure.name.must_equal DATA_CENTER_NAME
    @infrastructure.platform_id.must_equal 'datacenter-2758'
    @infrastructure.record_status.must_equal 'created'

    @infrastructure.hosts.size.must_equal 1
    host = @infrastructure.hosts.first

    host.name.must_equal 'test-host-1'

    inventory = host.inventory
    inventory.must_be_kind_of Array
    inventory.size.must_equal 2
    inventory.select{|inv| inv[/vm-*/]}.size.must_equal inventory.size

    @infrastructure.networks.size.must_equal 1
    network = @infrastructure.networks.first
    network.name.must_equal 'VM Network'
    network.kind.must_equal 'LAN'

    meter_instance = @infrastructure.meter_instance
    meter_instance.name.must_equal "#{DATA_CENTER_NAME} meter"
    meter_instance.status.must_equal 'online'
    meter_instance.enabled.must_equal true
  end
end
