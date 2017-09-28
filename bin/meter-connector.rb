#!/usr/bin/env ruby
require './config/default_includes'

Thread.abort_on_exception = true
Mongoid.load!('config/mongoid.yml', :default)
$logger = Logger.new(STDOUT)
$logger.level = ENV['LOG_LEVEL'] || Logger::INFO
STDOUT.sync = true

$logger.info 'API syncronization scheduled to run every 30 seconds'
on_prem_connector = OnPremConnector.new
loop do
  on_prem_connector.submit
  sleep 30
end



