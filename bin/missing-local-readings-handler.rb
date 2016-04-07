#!/usr/bin/env ruby
require 'bundler'
Bundler.require(:default, ENV['METER_ENV'] || :development)
$:.unshift 'lib', 'lib/shared', 'lib/models'

require 'infrastructure'
require 'global_configuration'
require 'logging'
require 'missing_local_readings_handler'
require 'signal_handler'

include Logging
include SignalHandler

if ( ! GlobalConfiguration::GlobalConfig.instance.configured? )
  logger.info "Missing readings handler has not been configured. Please configure using the registration wizard."
  exit(0)
end

logger.info "Scheduling missing readings collection to run every 30 minutes"

loop do
  processSignals
  start_time = Time.now
  MissingLocalReadingsHandler.new.run
  logger.debug "Missing readings handler run took #{Time.now - start_time} seconds to complete"
  if ( (Time.now - start_time) < 30.minutes )
    sleep( 30.minutes - (Time.now - start_time) )
  end
end

logger.info "Shutting down missing readings handler."
