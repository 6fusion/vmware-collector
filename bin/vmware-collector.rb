#!/usr/bin/env ruby
require 'bundler'
Bundler.require(:default, ENV['METER_ENV'] || :development)
$:.unshift File.expand_path('lib'), File.expand_path('lib/shared'), File.expand_path('lib/models'), File.expand_path('lib/models/registration')
require 'timeout'

require 'global_configuration'
require 'infrastructure_collector'
require 'collector_registration'
require 'collector_syncronization'
require 'logging'
require 'signal_handler'

include Logging
include SignalHandler

Thread::abort_on_exception = true
registration = CollectorRegistration.new
registration.configure_uc6
registration.configure_vsphere
sync = CollectorSyncronization.new
sync.sync_data
