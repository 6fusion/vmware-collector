#!/usr/bin/env ruby -W0

# load all required files
require './config/default_includes'

# load required executables for making the collector to work properly
require_relative 'executables/metrics'

Rake.load_rakefile('Rakefile')
Rake.application['create_indexes'].invoke((ENV['METER_ENV'] || :development).to_s)
Thread.abort_on_exception = true

def verify_collector_configuration
  configured = false
  begin
    logger.info 'Verifying configuration for Metrics process'
    # set as timeout 100 seconds to wait for the configuration to finish its process
    Timeout.timeout(TWO_MINUTES_IN_SECONDS) do
      until configured
        configured = VmwareConfiguration.first && VmwareConfiguration.first.configured
        sleep DEFAULT_SLEEP_TIME unless configured
      end
    end
  rescue Timeout::Error => e
    logger.info 'Collector has not been configured. Please ensure to execute Inventory Collector first'
    exit(0)
  end
end

# always execute the process
verify_collector_configuration

scheduler_30s = Rufus::Scheduler.new(max_work_threads: 1)

logger.info 'Metrics process scheduled to run every 30 seconds'
scheduler_30s.every '30s' do
  processSignals
  Executables::Metrics.new(scheduler_30s).execute
end

scheduler_30s.join
