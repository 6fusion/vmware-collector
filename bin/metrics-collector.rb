#!/usr/bin/env ruby -W0

# load all required files
require './config/default_includes'

# load required executables for making the collector to work properly
require_relative 'executables/metrics'

Thread.abort_on_exception = true

# def verify_collector_configuration
#   begin
#     logger.info 'Verifying configuration for Metrics process'
#     # set as timeout 100 seconds to wait for the configuration to finish its process
#     Timeout.timeout(TWO_MINUTES_IN_SECONDS) do
#       until configured
#         configured = VmwareConfiguration.first && VmwareConfiguration.first.configured
#         sleep DEFAULT_SLEEP_TIME unless configured
#       end
#     end
#   rescue Timeout::Error => e
#     logger.info 'Collector has not been configured. Please ensure to execute Inventory Collector first'
#     exit(0)
#   end
# end

# # always execute the process
# verify_collector_configuration

Mongoid.load!('config/mongoid.yml', :default)
$logger = Logger.new(STDOUT)
$logger.level = ENV['LOG_LEVEL'] || Logger::DEBUG
STDOUT.sync = true


scheduler_30s = Rufus::Scheduler.new(max_work_threads: 1)

$logger.info 'Metrics process scheduled to run every 30 seconds'
collector = MetricsCollector.new
scheduler_30s.every '30s' do
  InventoriedTimestamp.ready_for_metering.each do |it|
    it.update_attribute(:record_status, 'queued_for_metering')
    begin
      Timeout.timeout(300){  # TODO move to health check
        collector.run(it) }
    rescue Timeout::Error
      $logger.error "Unable to collect consumption metrics for inventoried machines for time #{it.inventory_at}. (timed out)"
    end
  end

end

scheduler_30s.join
