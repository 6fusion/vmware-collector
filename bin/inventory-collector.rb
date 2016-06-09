#!/usr/bin/env ruby -W0
require 'bundler'
Bundler.require(:default, ENV['METER_ENV'] || :development)
$:.unshift 'lib', 'lib/shared', 'lib/models', 'lib/modules'
require 'timeout'
require 'rake'

require 'global_configuration'
require 'infrastructure'
require 'inventory_collector'
require 'local_inventory'
require 'logging'
require 'initialize_collector_configuration'
require 'signal_handler'
require 'vsphere_session'
require 'collector_registration'
require 'collector_syncronization'
require 'vmware_configuration'
include Logging
include GlobalConfiguration
include SignalHandler
include InitializeCollectorConfiguration

require 'objspace'

init_configuration

def main
  if ( !VmwareConfiguration.first.configured )
    logger.info 'Inventory collector has not been configured. Please configure using the registration wizard.'
    exit(0)
  end

  scheduler = Rufus::Scheduler.new(max_work_threads: 1)

  logger.info 'Scheduling infrastructure collection to run every 5 minutes'

  scheduler.cron '*/5 * * * *' do |job|
    processSignals
    current_time = Time.now.change(sec: 0) # chop off subseconds

    begin
      inventoried_timestamp = InventoriedTimestamp.find_or_initialize_by(inventory_at: current_time)
      # Handle the case where inventory was collected outside of this process (e.g., meter registration)
      if ( inventoried_timestamp.persisted? )
        job.unschedule
      else
        inventoried_timestamp.save
        collector_queue = active_collectors
        logger.debug 'No active datacenters configured. No machine inventory will be collected.' if collector_queue.empty?
        # Give up after 9 minutes (this keeps us from falling behind by more than one run)
        Timeout::timeout(9*60) do
          threads = []
          queue_size = collector_queue.size
          queue_size.times {
            #   thread_pool.process {
            threads << Thread.new{ collector_queue.pop.run(current_time) }
          #     collector_queue.pop.run(current_time)
          #   }
          }
          #thread_pool.wait

          # FIXME put back thread pool
          threads.map(&:join)

          # If we succuesfully update the DB, update the inventoried status
          inventoried_timestamp.update_attribute(:record_status, 'inventoried')
        end
      end
    rescue Timeout::Error => e
      logger.error "Error collecting inventory for #{current_time}. Collection timed out."
    rescue StandardError => e
      logger.fatal "Encountered unhandled exception: #{e.message}."
      logger.debug e
      scheduler.shutdown
      exit(1)
    end

  end

  scheduler.join
  logger.info 'Shutting down inventory collector'
end



# These helper methods keep our active collectors in sync with the status
#  of the meter/infrastructure in mongo. i.e., if a meter gets disabled, the collector
#  corresponding to that infrastructure will go away, and vice versa
$collector_hash = Hash.new
def activate(infrastructure)
  begin
    unless $collector_hash[infrastructure.platform_id].present?
      logger.info "Intializing inventory collector for data center: #{infrastructure.name}"
      $collector_hash[infrastructure.platform_id] = InventoryCollector.new(infrastructure)
    end
  rescue StandardError => e
    logger.fatal "Unable to initialize inventory collection for data center: #{infrastructure.name}"
    logger.debug e
    raise e
  end
end
def deactivate(infrastructure)
  logger.debug "Skipping inventory collection for deactivated data center: #{infrastructure.name}"
  $collector_hash.delete(infrastructure.platform_id)
end
def active_collectors
  # If a data center is passed into the container, only hit that one. Otherwise, intstantiate a collector
  #  for each active infrastructure/datacenter/meter
  infrastructures = configuration.present_value?(:data_center) ?
                      InfrastructureInventory.new.select{|key,inf| inf.name.eql?(configuration[:data_center])} :
                      InfrastructureInventory.new

  infrastructures.each_value {|infrastructure|
    infrastructure.enabled? ? activate(infrastructure) : deactivate(infrastructure) }
  # Remove any that we know about, but are no longer returned by InfrastructureInventory (which filters out disabled)
  $collector_hash.each{|platform_id, collector|
    deactivate(collector.infrastructure) unless infrastructures.has_key?(platform_id)
  }
  queue = Queue.new
  $collector_hash.values.each{|collector| queue << collector }
  queue
end
def thread_limit
  if ( configuration[:vsphere_session_limit] and
       configuration[:vsphere_session_limit] > 4 )
    configuration[:vsphere_session_limit] - 3
  else
    1
  end
end


main
