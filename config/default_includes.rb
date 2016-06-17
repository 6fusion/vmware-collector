#!/usr/bin/env ruby -W0
require 'bundler'

Bundler.require(:default, ENV['METER_ENV'] || :development)
$:.unshift 'lib', 'lib/shared', 'lib/models', 'lib/modules'
require 'timeout'
require 'rake'
require_relative 'app_constants'

# loading all lib files
Dir.glob("./lib/**/*.rb", &method(:require))

include Logging
include GlobalConfiguration
include SignalHandler
include InitializeCollectorConfiguration
include CurrentVmsInventory

require 'objspace'