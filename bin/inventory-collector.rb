#!/usr/bin/env ruby -W0

# load all required files
require './config/default_includes'

# load required executables for making the collector to work properly
require_relative 'executables/inventory'
require_relative 'executables/infrastructure'
require_relative 'executables/api_sync'
require_relative 'executables/missing_readings'
require_relative 'executables/missing_readings_cleaner'

init_configuration

logger.debug "Syncronization complete"

unless VmwareConfiguration.first and VmwareConfiguration.first.configured
  logger.info 'Inventory collector has not been configured. Please configure using the registration wizard.'
  exit(0)
end

scheduler_30s = Rufus::Scheduler.new(max_work_threads: 1)
scheduler_5m = Rufus::Scheduler.new(max_work_threads: 1)
scheduler_15m = Rufus::Scheduler.new(max_work_threads: 1)
scheduler_30m = Rufus::Scheduler.new(max_work_threads: 1)

logger.info 'API syncronization scheduled to run every 30 seconds'
scheduler_30s.every '30s' do
  processSignals
  Executables::ApiSync.new(scheduler_30s).execute
end

logger.info 'Inventory and Infrastructure scheduled to run every 5 minutes'

hak = Executables::Inventory.new
scheduler_5m.cron '*/5 * * * *' do |job|
  processSignals
  hak.execute
  Executables::Infrastructure.new(scheduler_5m).execute
end

logger.info 'Metrics missing locked cleaning process scheduled to run every 15 minutes'
scheduler_15m.every '15m' do
  processSignals
  Executables::MissingReadingsCleaner.new(scheduler_15m).execute
end

logger.info 'Metrics missing readings scheduled to run every 30 minutes'
scheduler_30m.every '30m' do
  processSignals
  Executables::MissingReadings.new(scheduler_30m).execute
end

[scheduler_30s, scheduler_5m, scheduler_15m, scheduler_30m].map(&:join)
