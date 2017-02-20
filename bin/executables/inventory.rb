module Executables
  class Inventory
    def initialize #(scheduler, job)
      # @scheduler = scheduler
      # @job = job
      @collector_hash = {}
    end

    def execute
      logger.info 'Starting inventory collector'
      current_time = Time.now.change(sec: 0) # chop off subseconds

      begin
        inventory_data(current_time)
      rescue Timeout::Error
        logger.error "Error collecting inventory for #{current_time}. Collection timed out."
      rescue StandardError => e
        logger.fatal "Encountered unhandled exception: #{e.message}."
        logger.debug e.backtrace
#        @scheduler.shutdown
        exit(1)
      end
      logger.info 'Shutting down inventory collector'
    end

    private

    def inventory_data(ctime)
      inv_timestamps = initialize_inventoried_timestamps_with_inventory_for(ctime)
      # Handle the case where inventory was collected outside of
      # this process (e.g., meter registration)
      inv_timestamps.each do |inv|
        if inv.persisted?
#          @job.unschedule
        else
          inv.save
          collector_queue = active_collectors
          if collector_queue.empty?
            logger.debug 'No active datacenters configured. No machine inventory will be collected.'
          end
          # Give up after 9 minutes (avoid falling behind by more than one run)
          Timeout.timeout(NINE_MINUTES_IN_SECONDS) do
            inventory_threading(collector_queue, ctime, inv)
          end
        end
      end if inv_timestamps
    end

    def inventory_threading(c_queue, current_time, inventoried_timestamp)
      # Adding a limited thread pool (no more than 4 threads running at a time)
      workers = (0...thread_limit).map do |_worker|
        # Do not rescue any exception here so that the main catcher captures it
        Thread.new do
          begin
            # Assign the value
            while collector_elem = c_queue.pop(true)
              collector_elem.run(current_time)
            end
          rescue ThreadError => e
            # thread execution will always throw an error when elements on queue
            unless e.message == 'queue empty'
              logger.error e.inspect
              logger.error e.backtrace
              exit(1)
            end
          end
        end
      end
      workers.map(&:join)
      # If we succuesfully update the DB, update the inventoried status
      inventoried_timestamp.update_attribute(:record_status, 'inventoried')
    end

    # These helper methods keep our active collectors in sync with the status
    #  of the meter/infrastructure in mongo. i.e., if a meter gets disabled, the collector
    #  corresponding to that infrastructure will go away, and vice versa
    def activate(infrastructure)
      unless @collector_hash[infrastructure.platform_id].present?
        logger.info "Intializing inventory collector for data center: #{infrastructure.name}"
        @collector_hash[infrastructure.platform_id] = InventoryCollector.new(infrastructure)
      end
    rescue StandardError => e
      logger.fatal "Unable to initialize inventory collection for data center: #{infrastructure.name}"
      logger.debug e
      raise e
    end

    def deactivate(infrastructure)
      logger.debug "Skipping inventory collection for deactivated data center: #{infrastructure.name}"
      @collector_hash.delete(infrastructure.platform_id)
    end

    def active_collectors
      # If a data center is passed into the container, only hit that one.
      # Otherwise, instantiate a collector for each active infrastructure/datacenter/meter
      infrastructures = configuration.present_value?(:data_center) ?
          InfrastructureInventory.new.select { |_key, inf| inf.name.eql?(configuration[:data_center]) } :
          InfrastructureInventory.new

      infrastructures.each_value do |infrastructure|
        infrastructure.enabled? ? activate(infrastructure) : deactivate(infrastructure)
      end
      # Remove any that we know about, but are no longer returned by InfrastructureInventory (which filters out disabled)
      @collector_hash.each do |platform_id, collector|
        deactivate(collector.infrastructure) unless infrastructures.key?(platform_id)
      end
      queue = Queue.new
      @collector_hash.values.each { |collector| queue << collector }
      queue
    end

    def thread_limit
      if configuration[:vsphere_session_limit] &&
          configuration[:vsphere_session_limit] > VSPHERE_CONNECTIONS_THRESHOLD
        configuration[:vsphere_session_limit] - VSPHERE_CONNECTIONS_LOOSENESS
      else
        MINIMUM_VSPHERE_CONNECTIONS
      end
    end
  end
end
