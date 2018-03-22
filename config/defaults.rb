require 'bundler'

Bundler.require(:default, ENV['METER_ENV'] || :development)
$:.unshift 'lib', 'lib/shared', 'lib/models', 'lib/modules'

require 'timeout'
require 'rake'
require_relative 'app_constants'

# loading all lib files
Dir.glob("./lib/**/*.rb", &method(:require))

Mongoid.load!('config/mongoid.yml', :default)
STDOUT.sync = true
$logger = Logger.new(STDOUT)
$logger.level = ENV['LOG_LEVEL'] || Logger::DEBUG
$hyper_client = HyperClient.new
