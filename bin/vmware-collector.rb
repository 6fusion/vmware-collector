#!/usr/bin/env ruby
require 'bundler'
Bundler.require(:default, ENV['METER_ENV'] || :development)
$:.unshift File.expand_path('lib'), File.expand_path('lib/shared'), File.expand_path('lib/models'), File.expand_path('lib/models/registration')
require 'timeout'

require 'global_configuration'
require 'infrastructure_collector'
require 'collector_registration'
require 'logging'
require 'signal_handler'

include Logging
include SignalHandler

Thread::abort_on_exception = true
registration = CollectorRegistration.new
registration.configure_uc6
print "\n Global Configuration Instance => \n #{GlobalConfiguration::GlobalConfig.instance.to_s}\n\n"
