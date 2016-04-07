require 'feature_helper'
require 'metrics_collector'
using RbVmomiExtensions

describe MetricsCollector, :run do
  DATA_CENTER_NAME = 'DC-Main'

  before(:all) do
    DatabaseCleaner.clean
  end

  after(:all) do
    DatabaseCleaner.clean
  end

  it 'works properly' do
    # MiniTest will not run any code after failed expectation
    # Extra VMs on VSphere from failures is very annoying...
    begin
      vm1 = create_vm('test1_metrics', DATA_CENTER_NAME)
      vm2 = create_vm('test2_metrics', DATA_CENTER_NAME)

      inventory_at = Time.now
      it = InventoriedTimestamp.new({inventory_at: inventory_at,
                                   record_status: 'created'})
      it.save

      # Setup 2 machines for which to collect readings
      # (metrics collector uses morefs from Machine inventory)
      machine1 = Machine.new({platform_id: vm1.moref,
                           inventory_at: inventory_at}).save
      machine2 = Machine.new({platform_id: vm2.moref,
                           inventory_at: inventory_at}).save

      mc = MetricsCollector.new
      prior_readings = Reading.all.size
      mc.run(it)

      Reading.all.size.must_equal(prior_readings + 2)
    ensure
      destroy_vm('test1_metrics', DATA_CENTER_NAME)
      destroy_vm('test2_metrics', DATA_CENTER_NAME)
    end
  end
end
