#!/usr/bin/env ruby -W0
require 'bundler'
Bundler.require(:default, ENV['METER_ENV'] || :development)
$:.unshift 'lib', 'lib/shared', 'lib/models', 'lib/modules'
require 'rake'

require 'global_configuration'
require 'logging'
require 'initialize_collector_configuration'
require 'signal_handler'
require 'uc6_connector'
require 'collector_registration'
require 'collector_syncronization'
require 'vmware_configuration'
include Logging
include SignalHandler
include InitializeCollectorConfiguration


init_configuration

if ( !VmwareConfiguration.first.configured )
  logger.info "UC6 connector has not been configured. Please configure using the registration wizard."
  exit(0)
end


logger.info "Initializing UC6Connector"
uc6_connector = begin
                  UC6Connector.new
                rescue Exception => e
                  logger.fatal "Unable to start UC6Connector: #{e.message}"
                  exit(1)
                end

logger.info "Scheduling UC6 submission checks to run every 30 seconds"

loop do
  processSignals
  uc6_connector.submit
  sleep 30
end

logger.info "Shutting down UC6 submission handler"

