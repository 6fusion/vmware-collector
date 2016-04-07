require 'feature_helper'
require 'missing_local_readings_handler'
using RbVmomiExtensions

#DatabaseCleaner.strategy = :truncation

describe MissingLocalReadingsHandler, :run do
  DATA_CENTER_NAME = 'DC-Main'

  before(:each) do
    DatabaseCleaner.clean
    @vm1 = create_vm('test_missing_read_vm_1', DATA_CENTER_NAME)
    @vm2 = create_vm('test_missing_read_vm_2', DATA_CENTER_NAME)
    @handler = MissingLocalReadingsHandler.new
  end

  after(:each) do
    DatabaseCleaner.clean
    destroy_vm('test_missing_read_vm_1', DATA_CENTER_NAME)
    destroy_vm('test_missing_read_vm_2', DATA_CENTER_NAME)
  end

  it 'should find and fill in gaps in the machine inventory' do
    time = Time.now
    times = [ time.change(min: time.min - (time.min % 5)) ] # Create a timestamp on a 5-minute interval

    sleep 2 # Sleep for a bit to allow vSphere events to percolate

    # Just fill in inventory for a 5-minute period
    @handler.stub(:all_timestamps_past_twenty_four_hours_five_min_intervals, times) do
      @handler.send(:backfill_inventory)
    end

    Machine.in(platform_id: [@vm1.moref, @vm2.moref]).size.must_equal(2)
  end

  it 'should fill in missing readings from orphaned metrics collection attempts' do
    # Create a "past" timestamp on a 5-minute interval
    # (can't be current as missing readings @handler skips initial 20 minutes of timestamps)
    time = 30.minutes.ago
    time = time.change(min: time.min - (time.min % 5))

    # Create some inventory
    Machine.new(inventory_at: time, platform_id: @vm1.moref).save
    Machine.new(inventory_at: time, platform_id: @vm2.moref).save

    # Create an "orphaned" (record_status 'metering') timestamp in the past
    InventoriedTimestamp.new(inventory_at: time, record_status: 'metering').save

    Reading.all.size.must_equal(0)

    @handler.send(:fill_in_missing_readings)

    Reading.all.size.must_equal(2)
  end
end
