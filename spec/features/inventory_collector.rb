require 'feature_helper'
require 'infrastructure_collector'
require 'inventory_collector'
require 'rbvmomi_extensions'
require 'vsphere_session'
require 'interval_time'

using IntervalTime
using RbVmomiExtensions

# Note: These tests are  Currently hard-coded for DC-Main on vcn16.dev.ral.6fusion.com
describe "Inventory Collector" do
  before(:all) do
    DatabaseCleaner.clean
    create_vm('test_vm_1', 'DC-Main')
    create_vm('test_vm_2', 'DC-Main')

    infrastructure_collector = InfrastructureCollector.new
    infrastructure_collector.run

    @inf_1 = Infrastructure.where(name: "DC-Main").first
    collector = InventoryCollector.new(@inf_1)
    time_to_query = Time.now.truncated
    collector.run(time_to_query)
    @machines = Machine.all.to_a
  end

  after(:all) do
    DatabaseCleaner.clean
    destroy_vm('test_vm_1', 'DC-Main')
    destroy_vm('test_vm_2', 'DC-Main')
  end

  # All expectations are in one it block to only hit vSphere once
  # Unfortunately, no clear way to do before/after for all tests (currently, only supports each test)
  it "works properly" do
    @machines = Machine.all.to_a
    @machines.size.must_equal 2
    @machines.map(&:platform_id).select{|m| m[/vm-*/]}.size.must_equal @machines.size
    @machines.map(&:name).sort.must_equal ["test_vm_1", "test_vm_2"]
    @machines.map(&:record_status).uniq.first.must_equal "created"
    @machines.map(&:infrastructure_platform_id).uniq.first.must_equal @inf_1.platform_id
  end
end
