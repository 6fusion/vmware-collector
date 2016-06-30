module Executables
  class Metrics
    # We have to separate processes for collecting metrics due to the nature of how performance
    #  metrics are gathered by vCenter. Metrics for ~ the past hour are retrieved directly from ESX
    #  and are returned very quickly (~30 seconds for 10,000 VMs). Metrics for times past 1 hour
    #  are queried from the vCenter database and can take significantly longer to gather (> 5 minutes),
    #  depending on the performance of the vCenter host. Having two threads keeps the metrics collector from
    #  becoming permanently backlogged.
    def initialize(scheduler)
      logger.info 'Initializing Metrics gathering process'
      @scheduler = scheduler
    end

    def execute
      logger.info '- Loading Metrics from Vsphere handler'

      begin
        main_thread
        [current_thread, backlog_thread].map(&:join)
      rescue StandardError => e
        logger.fatal "Encountered unhandled exception: #{e.message}."
        logger.debug e.backtrace
        @scheduler.shutdown
        exit(1)
      end
      logger.info '- Metrics Loaded from Vsphere handler'
    end

    private

    def collector_creator
      MetricsCollector.new
    rescue StandardError => e
      logger.fatal "Unable to start metrics collection: #{e.message}"
      logger.debug e.backtrace
      @scheduler.shutdown
      exit(1)
    end

    def current_collector
      @current_collector ||= collector_creator
    end

    def backlog_collector
      @backlog_collector ||= collector_creator
    end

    def current_queue
      @current_queue ||= Queue.new
    end

    def backlog_queue
      @backlog_queue ||= Queue.new
    end

    def main_thread
      if current_queue.empty? || backlog_queue.empty?
        # Iterate over timestamps (from oldest to newest).
        #  Queue is not being used here in the usual sense - its main concern is to provide a simple,
        #  thread-safe variable. We only enqueue when one is empty to keep the number of InventoriedTimestamps
        #  in the state of 'queued_for_metering' or 'metering' to a minimum. This reduces the amount
        #  of readings the missing readings handler will have to (needlessly) map/reduce as part of its job.
        inventoried_timestamps =  InventoriedTimestamp.where(record_status: 'inventoried',
                                                             locked: false,
                                                             :inventory_at.lte => 6.minutes.ago,
                                                             :inventory_at.gte => 23.hours.ago)
                                      .asc(:inventory_at)
        inventoried_timestamps.each do |it|
          # 55 minutes used to provide a bit of "wiggle room", and hopefully avoid attempting
          #  collection directly on the hour, when stats may be getting purged from ESX
          if it.inventory_at >= INVENTORY_WIGGLE_TIME.minutes.ago && current_queue.empty?
            begin
              it.with_lock do
                it.update_attributes(record_status: 'queued_for_metering', locked: true)
                logger.debug "Enqueuing #{it.inventory_at} to past-hour queue"
                current_queue << it
              end
            rescue Mongoid::Locker::LockError => e
              logger.debug "Could not get the #{it.inventory_at} with the inventory #{it.machine_inventory}, trying to get another inventory timestamp\n"
              next
            end
          elsif backlog_queue.empty?
            begin
              it.with_lock do
                it.update_attributes(record_status: 'queued_for_metering', locked: true)
                logger.debug "Enqueuing #{it.inventory_at} to backlog queue"
                backlog_queue << it
              end
            rescue Mongoid::Locker::LockError => e
              logger.debug "Could not get the #{it.inventory_at} with the inventory #{it.machine_inventory}, trying to get another inventory timestamp\n"
              next
            end
          end
          # If both queues are full, don't bother iterating any further
          break unless current_queue.empty? || backlog_queue.empty?
        end

      end
    end

    def current_thread
      Thread.new do
        Thread.current.priority = REGULAR_THREAD_PRIORITY
        Thread.current.abort_on_exception = true
        queue_size = current_queue.size
        queue_size.times do
          timestamp = current_queue.pop
          begin
            if timestamp.inventory_at < INVENTORY_WIGGLE_TIME.minutes.ago
              logger.debug "Moving #{timestamp.inventory_at} to backlog collector"
              backlog_queue << timestamp
              next
            end
            # collection shouldn't take longer than 5 minutes
            Timeout.timeout(FIVE_MINUTES_IN_SECONDS) do
              logger.debug "Running #{timestamp.inventory_at} in past-hour thread"
              current_collector.run(timestamp, timestamp.machine_inventory)
            end
          rescue Timeout::Error => e
            logger.error "Unable to collect consumption metrics for inventoried machines for time #{timestamp.inventory_at}. (timed out)"
          end
        end
      end
    end

    def backlog_thread
      Thread.new do
        Thread.current.priority = MINIMUM_THREAD_PRIORITY
        Thread.current.abort_on_exception = true
        queue_size = backlog_queue.size
        queue_size.times do
          timestamp = backlog_queue.pop
          begin
            if timestamp.inventory_at < HOURS_IN_DAY.hours.ago
              logger.warn "Skipping metrics collection for backlogged inventory at time #{timestamp.inventory_at}"
              next
            end
            # collection shouldn't take longer than 15 minutes
            Timeout.timeout(FITHTEEN_MINUTES_IN_SECONDS) do
              logger.debug "Running #{timestamp.inventory_at} in backlog thread"
              backlog_collector.run(timestamp, timestamp.machine_inventory)
            end
          rescue Timeout::Error => e
            logger.error "Unable to collect consumption metrics for inventoried machines for time #{timestamp.inventory_at}. (timed out)"
          end
        end
      end
    end
  end
end
