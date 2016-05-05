#!/usr/bin/env ruby -W0
$:.unshift 'lib','lib/models', 'lib/shared'
require 'bundler'
Bundler.require(:default, ENV['METER_ENV'] || :development)

require 'inventoried_timestamp'
require 'metrics_collector'
require 'global_configuration'
require 'infrastructure'
require 'inventory_collector'
require 'local_inventory'
require 'logging'
require 'signal_handler'
require 'vsphere_session'
require 'collector_registration'
require 'collector_syncronization'


include Logging
include SignalHandler

Thread::abort_on_exception = true
registration = CollectorRegistration.new
registration.configure_uc6
registration.configure_vsphere
sync = CollectorSyncronization.new
sync.sync_data
if ( ! GlobalConfiguration::GlobalConfig.instance.configured? )
  logger.info "Metrics collector has not been configured. Please configure using the registration wizard."
  exit(0)
end


logger.info "Initializing metrics collector"

# We have to separate processes for collecting metrics due to the nature of how performance
#  metrics are gathered by vCenter. Metrics for ~ the past hour are retrieved directly from ESX
#  and are returned very quickly (~30 seconds for 10,000 VMs). Metrics for times past 1 hour
#  are queried from the vCenter database and can take significantly longer to gather (> 5 minutes),
#  depending on the performance of the vCenter host. Having two threads keeps the metrics collector from
#  becoming permanently backlogged.
current_collector, backlog_collector = begin
                                         [ MetricsCollector.new, MetricsCollector.new ]
                                       rescue StandardError => e
                                         logger.fatal "Unable to start metrics collection: #{e.message}"
                                         logger.debug e.backtrace
                                         exit(1)
                                       end

current_queue = Queue.new
backlog_queue = Queue.new

current_thread = Thread.new do
  Thread.current.priority = 1
  Thread.current.abort_on_exception = true
  loop do
    timestamp = current_queue.pop
    begin

      if ( timestamp.inventory_at < 55.minutes.ago )
        logger.debug "Moving #{timestamp.inventory_at} to backlog collector"
        backlog_queue << timestamp
        next
      end

      # collection shouldn't take longer than 5 minutes
      Timeout::timeout(300) do
        logger.debug "Running #{timestamp.inventory_at} in past-hour thread"
        current_collector.run(timestamp)
      end
    rescue Timeout::Error => e
      logger.error "Unable to collect consumption metrics for inventoried machines for time #{timestamp.inventory_at}. (timed out)"
    end
  end
end

backlog_thread = Thread.new do
  Thread.current.priority = -100
  Thread.current.abort_on_exception = true
  loop do
    timestamp = backlog_queue.pop
    begin
      if ( timestamp.inventory_at < 24.hours.ago )
        logger.warn "Skipping metrics collection for backlogged inventory at time #{timestamp.inventory_at}"
        next
      end
      # collection shouldn't take longer than 15 minutes
      Timeout::timeout(900) do
        logger.debug "Running #{timestamp.inventory_at} in backlog thread"
        backlog_collector.run(timestamp)
      end
    rescue Timeout::Error => e
      logger.error "Unable to collect consumption metrics for inventoried machines for time #{timestamp.inventory_at}. (timed out)"
    end
  end
end

debug_counter = 0
loop do
  processSignals
  debug_counter += 1

  if ( current_queue.empty? or backlog_queue.empty? )

    if ( debug_counter == 5 )  # reduce logging; every 30 seconds would be a bit much
      logger.debug "Checking for queued inventory to collect readings for"
      debug_counter = 0
    end

    # Iterate over timestamps (from oldest to newest).
    #  Queue is not being used here in the usual sense - its main concern is to provide a simple,
    #  thread-safe variable. We only enqueue when one is empty to keep the number of IventoriedTimestamps
    #  in the state of 'queued_for_metering' or 'metering' to a minimum. This reduces the amount
    #  of readings the missing readings handler will have to (needlessly) map/reduce as part of its job.
    InventoriedTimestamp.where(record_status: 'inventoried',
                               :inventory_at.lte => 6.minutes.ago,
                               :inventory_at.gte => 23.hours.ago)
                        .asc(:inventory_at).each do |it|

      # 55 minutes used to provide a bit of "wiggle room", and hopefully avoid attempting
      #  collection directly on the hour, when stats may be getting purged from ESX
      if ( it.inventory_at >= 55.minutes.ago )
        if ( current_queue.empty? )
          logger.debug "Enqueuing #{it.inventory_at} to past-hour queue"
          it.update_attribute(:record_status, 'queued_for_metering')
          current_queue << it
        end
      else
        if ( backlog_queue.empty? )
          logger.debug "Enqueuing #{it.inventory_at} to backlog queue"
          it.update_attribute(:record_status, 'queued_for_metering')
          backlog_queue << it
        end
      end

      # If both queues are full, don't bother iterating any further
      break unless current_queue.empty? or backlog_queue.empty?
    end

  end

  sleep 30

end

[current_thread, backlog_thread].map(&:join)

logger.info "Shutting down metrics collector"
