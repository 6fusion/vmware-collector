#!/usr/bin/env ruby
require 'bundler'
Bundler.require(:default, ENV['METER_ENV'] || :development)
$:.unshift File.expand_path('lib'), File.expand_path('lib/shared'), File.expand_path('lib/models'),File.expand_path('lib/modules')
require 'timeout'
require 'rake'

require 'global_configuration'
require 'infrastructure_collector'
require 'logging'
require 'initialize_collector_configuration'
require 'signal_handler'
require 'collector_registration'
require 'collector_syncronization'
require 'vmware_configuration'
include Logging
include SignalHandler
include InitializeCollectorConfiguration

init_configuration

if ( ! VmwareConfiguration.first.configured )
  logger.info 'Infrastructure collector has not been configured. Please configure using the registration wizard.'
  exit(0)
end

collector = begin
              InfrastructureCollector.new
            rescue StandardError => e
              logger.fatal "Unable to start infrastructure collection. #{e.message}"
              logger.debug e
              exit(1)
            end

# Since same vSphere session is reused with every run (and the collector hasn't been written with theading in mind),
#  we don't want to have more than one run occur at a time
scheduler = Rufus::Scheduler.new(max_work_threads: 1)
logger.info 'Scheduling infrastructure collection to run every 5 minutes'

scheduler.cron '*/5 * * * *' do
  begin
    processSignals
    # Give up after 9 minutes (this keeps us from falling behind by more than one run)
    Timeout::timeout(9*60) do
      collector.run
    end
  rescue Timeout::Error => e
    logger.error 'Unable to collect information infrastructure; process timed out.'
  rescue StandardError => e
    logger.debug e
  end
end

scheduler.join
logger.info 'Shutting down infrastructure collector'

