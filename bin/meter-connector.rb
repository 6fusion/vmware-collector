#!/usr/bin/env ruby
require './config/default_includes'

Thread.abort_on_exception = true
Mongoid.load!('config/mongoid.yml', :default)
$logger = Logger.new(STDOUT)
$logger.level = ENV['LOG_LEVEL'] || Logger::INFO
STDOUT.sync = true

# This is an attempt to add some resiliency if we crash to do machine state not mirror what's in the API
$logger.info 'Ensuring local inventory is syncronized with API'
max_threads = Integer(ENV['METER_API_THREADS'] || 10)
thread_pool = Concurrent::ThreadPoolExecutor.new(min_threads: 1, max_threads: max_threads, max_queue: max_threads * 2, fallback_policy: :caller_runs)
Machine.distinct(:uuid).each do |machine|
  thread_pool.post { machine.submit_create unless machine.already_submitted? }
  thread_pool.shutdown
  thread_pool.wait_for_termination
end


$logger.info 'API syncronization scheduled to run every 30 seconds'
on_prem_connector = OnPremConnector.new
loop do
  on_prem_connector.submit
  sleep 30
end



