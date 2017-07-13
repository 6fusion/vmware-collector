module Executables
  class Metrics
    include CurrentVmsInventory

    # We have to separate processes for collecting metrics due to the nature of how performance
    #  metrics are gathered by vCenter. Metrics for ~ the past hour are retrieved directly from ESX
    #  and are returned very quickly (~30 seconds for 10,000 VMs). Metrics for times past 1 hour
    #  are queried from the vCenter database and can take significantly longer to gather (> 5 minutes),
    #  depending on the performance of the vCenter host. Having two threads keeps the metrics collector from
    #  becoming permanently backlogged.
    def initialize(scheduler)
      $logger.debug 'Initializing Metrics gathering process'
      @scheduler = scheduler
      @container_name = ENV['HOSTNAME']
    end

    def execute
#      $logger.info '- Loading Metrics from Vsphere handler'

      begin
        main_thread
      rescue StandardError => e
        $logger.fatal "Encountered unhandled exception: #{e.message}."
        $logger.debug e.backtrace
        @scheduler.shutdown
        exit(1)
      end
#      $logger.info '- Metrics Loaded from Vsphere handler'
    end

    private

    def collector_creator
      MetricsCollector.new
    rescue StandardError => e
      $logger.fatal "Unable to start metrics collection: #{e.message}"
      $logger.debug e.backtrace
      @scheduler.shutdown
      exit(1)
    end

    def current_collector
      @current_collector ||= collector_creator
    end

    def main_thread
      # Iterate over timestamps (from oldest to newest).
      config = GlobalConfiguration::GlobalConfig.instance
      inventoried_timestamps = InventoriedTimestamp.unlocked_timestamps_for_day('inventoried')
      inventoried_timestamps.each do |it|
        if inventoried_timestamp_unlocked?(it)
          it.locked = true
          it.locked_by = @container_name
          it.record_status = 'queued_for_metering'
          it.save!
        end
      end
      inventoried_timestamps_to_be_metered(@container_name).sort_by(&:inventory_at).reverse.each do |it|
        next if not inventoried_timestamp_free_to_meter? it
        begin
          time = it.inventory_at < INVENTORY_WIGGLE_TIME.minutes.ago ? FITHTEEN_MINUTES_IN_SECONDS : FIVE_MINUTES_IN_SECONDS
          Timeout.timeout(time) do
            $logger.debug "Running ID => #{it._id} ==#{it.inventory_at} with inventory #{it.machine_inventory}"
            current_collector.run(it, it.machine_inventory)
          end
        rescue Timeout::Error
          $logger.error "Unable to collect consumption metrics for inventoried machines for time #{it.inventory_at}. (timed out)"
        end
      end
    end
  end
end
