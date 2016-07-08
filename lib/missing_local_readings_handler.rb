# Note: this class utilizes memoization in such a way that it should be reinstantiated for every run
require 'timeout'

require 'global_configuration'
require 'interval_time'
require 'inventoried_timestamp'
require 'local_inventory'
require 'logging'
require 'reading'
require 'vsphere_session'
require 'machine'
require 'machine_readings_with_missing'
require 'metrics_collector'
require 'vsphere_event_collector'

class MissingLocalReadingsHandler
  include GlobalConfiguration
  include Logging
  include MongoConnection
  using IntervalTime # provides the truncated method, utilized by this class to round times to 5-minute intervals

  def initialize
    initialize_mongo_connection
  end

  def run
    raise 'Do not call run multiple times - reinstantiate for each run' if defined?(@missing_inventory_timestamps)

    backfill_inventory if valid_history_range?

    backfill_readings
  end

  def unlock_old_inventory_timestamps
    orphaned_timestamps = InventoriedTimestamp.or({record_status: 'metering'}, record_status: 'queued_for_metering')
                              .and(locked: true).lt(inventory_at: 15.minutes.ago)
    orphaned_timestamps.each do |it|
      it.update_attributes(locked: false, locked_by: nil)
    end
  end

  #  private

  # Determine if there are gaps in the collected machine inventory.
  # If so:
  #   1)process vSphere events that occurred during that gap to determine
  #     if any machines were created/deleted
  #   2)Create inventory records in the database to fill the gap
  #     Note: machines created during this time will not have configuration or disk usage information available
  #   3)Add InventoriedTimestamp record to queue the inventory for processing by the Metrics Collector
  def backfill_inventory
    logger.info 'Checking for missing inventory'
    unless missing_inventory_timestamps.empty?
      local_inventory = MachineInventory.new
      logger.debug 'Instantiating VSphere Event Collector'
      event_collector = VSphere.wrapped_vsphere_request { VSphereEventCollector.new(start_time, end_time) }
      
      missing_inventory_timestamps.each do |missing_timestamp|
        local_inventory.at_or_before(missing_timestamp)
        # Add creates
        event_collector.events[missing_timestamp][:created].each do |moref|
          logger.debug "Inserting empty inventory creation record for VM: #{moref} at time #{missing_timestamp}"
          local_inventory[moref] = Machine.new(platform_id: moref,
                                               status: 'created')
        end # !! what's actual vsphere status? infer powerons as well?
        # Update status of deletes
        event_collector.events[missing_timestamp][:deleted].each do |moref|
          logger.info "Inserting inventory deletion record for missing VM: #{moref} at time #{missing_timestamp}"
          local_inventory.delete(moref)
        end

        local_inventory.save_a_copy_with_updates(missing_timestamp)

        create_inventory_timestamps_with_inventory_for(missing_timestamp)
      end
    end
  end

  # Determines if readings are missing for inventoried machines. If true, elucidates which morefs require metering and
  #  passes those to an instance of the Metrics Collector for processing
  def backfill_readings
    logger.info 'Checking for missing readings'
    # We're only interested in inventories with a status of metering; a status of 'inventoried', even for an older timestamp,
    #  will still get picked up by the normal Metrics Collector process.
    #  The intent here is to look for any InventoriedTimestamps "stuck" in the 'metering' status, which is a fairly unlikely scenario.
    orphaned_timestamps = InventoriedTimestamp.or({record_status: 'metering'}, record_status: 'queued_for_metering')
                              .and(locked: false).lt(inventory_at: 15.minutes.ago) # We want to make sure to not overlap with the actual metrics collector process
    orphaned_timestamps.group_by{|i| i.inventory_at}.each do |it|
      inv_timestamps = it[1]
      generate_machine_readings_with_missing(inv_timestamps[0].inventory_at) # Map-Reduce to build new collection
      logger.debug 'machine readings with missing map/reduce initialized'
      grouped_readings_by_timestamp = MachineReadingsWithMissing.collection.aggregate(
          [{'$group' => {'_id' => '$value.inventory_at',
                         data: {'$addToSet' =>
                                    {'moref' => '$value.platform_id'}}}}],
          'allowDiskUse' => true
      )
      logger.debug 'machine readings with missing map/reduce aggregated'
      # Remove when _id is nil, case where timestamp had all readings
      missing_machine_morefs_by_timestamp = grouped_readings_by_timestamp.reject { |data| !data['_id'] }
      missing_machine_morefs_by_timestamp.each do |missing_hash|
        time = missing_hash['_id']
        data = missing_hash['data']

        logger.info("Filling in missing readings for #{data.size} machines for time: #{inv_timestamps[0].inventory_at}")

        morefs_for_missing = data.map { |pair| pair['moref'] }
        recollect_missing_readings(inv_timestamps, morefs_for_missing)
      end
      if missing_machine_morefs_by_timestamp.blank?
        recollect_missing_readings(inv_timestamps, [])
      end
    end
  end
  #pending to modify
  def recollect_missing_readings(inv_timestamps, morefs_for_missing)
    morefs_pending = InventoriedTimestamp.or(record_status: "created").or(record_status: "inventoried").or( record_status: "metered").and(inventory_at: inv_timestamps[0].inventory_at)
    if morefs_pending.blank?
      counter = 0
      inv_timestamps.each do |dup|
        if counter == 0
          if inventoried_timestamp_unlocked? dup
            dup.locked = true
            dup.locked_by = @container_name
            dup.record_status = 'queued_for_metering'
            dup.save!
          end
          next if not inventoried_timestamp_free_to_meter? dup
          logger.debug "Running ID => #{dup._id} ==#{dup.inventory_at} with inventory #{dup.machine_inventory}"
          metrics_collector.run(dup, morefs_for_missing)
        else
          if inventoried_timestamp_unlocked? dup
            dup.locked = true
            dup.locked_by = @container_name
            dup.record_status = 'metered'
            dup.save!
          end
        end
        counter +=1
      end
    else
      inv_timestamps.each do |dup|
        if inventoried_timestamp_unlocked? dup
          dup.locked = true
          dup.locked_by = @container_name
          dup.record_status = 'queued_for_metering'
          dup.save!
        end
        next if not inventoried_timestamp_free_to_meter? dup
        logger.debug "Running ID => #{dup._id} ==#{dup.inventory_at} with inventory #{dup.machine_inventory}"
        metrics_collector.run(dup, dup.machine_inventory)
      end
    end
  end

  def missing_inventory_timestamps
    @missing_inventory_timestamps ||= timestamps_accountable_for - existing_machine_timestamps
  end

  def existing_machine_timestamps
    # :'inventory_at.gte' won't work; .gte is an actual method invocation; mongoid must be adding comparators as methods to the Symbol class @_@
    @existing_machine_timestamps ||= Machine.where(:inventory_at.gte => window_start_time).distinct('inventory_at')
  end

  # Window of time to check against for missing inventory/readings
  #  Note that we don't attempt to backfill to any time before the meter was registered
  #  Only going back 23 hours to provide "wiggle room" that should avoid collecting for time that vCenter is purging (i.e., typically at 24 hours)
  def window_start_time
    @window_start_time ||= begin
      if configuration.present_value?(:uc6_registration_date) # PENDING TO VALIDATE FORMAT
        registration_date = Time.parse(configuration[:uc6_registration_date])
        logger.info "REGISTRATION DATE #{registration_date}"
        ((registration_date > 23.hours.ago) ?
            (registration_date + 5.minutes) : # Add 5 minutes so we don't end up rounding down to a time before registration. e.g. 9:03 would truncate to 9:00
           23.hours.ago).truncated
      end
    end
  end

  # All the timestamps that should, in theory, exist for a given 24 hour window
  def timestamps_accountable_for
    # Start from window start, go up to 5 minutes ago to ensure we don't conflict with/duplicate efforts of the actual InventoryCollector process
    @timestamps_accountable_for = (window_start_time.to_i..5.minutes.ago.truncated.to_i).step(300).map { |seconds| Time.at(seconds).utc }
  end

  # Under specific circumstances, it is possible for the end_time to be farther back than the start_time, which obviously is not a valid history gap
  def valid_history_range?
    logger.debug "Start_time  => #{start_time} == End_time => #{end_time}"
    start_time < end_time
  end

  def start_time
    # Go back 5 minutes, as we want to ask vSphere for the history covering the gap *up to* the first missing timestamp
    @start_time ||= missing_inventory_timestamps.empty? ?
                      5.minutes.ago :
                      missing_inventory_timestamps.first - 5.minutes
  end

  def end_time
    # Less than this, and we could duplicate the efforts of the Inventory Collector
    @end_time ||= 10.minutes.ago.utc
  end

  def metrics_collector
    @metrics_collector ||= MetricsCollector.new
  end

  ####################################################################################################

  def generate_machine_readings_with_missing(timestamp)
    map1 = <<-MAP1_JAVASCRIPT
        function() {
          if ( this.status != 'deleted' ){
            emit(this._id, this); }
        }
    MAP1_JAVASCRIPT

    map2 = <<-MAP2_JAVASCRIPT
        function() {
          if ( this.machine_metrics ) {
            emit(this.machine_metrics.machine_id, this.machine_metrics);
          }
        }
    MAP2_JAVASCRIPT

    reduce = <<-REDUCE
      function(key, values) {
        return key;
      }
    REDUCE

    Machine.where(inventory_at: timestamp)
        .map_reduce(map1, reduce)
        .out(replace: 'machine_readings_with_missings').each { |_x|}

    Reading.map_reduce(map2, reduce)
        .out(merge: 'machine_readings_with_missings').each { |_x|}
  end
end
