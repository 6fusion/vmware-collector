#!/usr/bin/env ruby -W0
require 'set'

# load all required files
require './config/default_includes'

# load required executables for making the collector to work properly
require_relative 'executables/inventory'
require_relative 'executables/infrastructure'
require_relative 'executables/api_sync'
require_relative 'executables/missing_readings'
require_relative 'executables/missing_readings_cleaner'


Mongoid.load!('config/mongoid.yml', :default)
STDOUT.sync = true
$logger = Logger.new(STDOUT)
$logger.level = ENV['LOG_LEVEL'] || Logger::DEBUG

begin
  Mongoid::Tasks::Database::create_indexes
rescue
  # indexes may already exist
end

scheduler_1m = Rufus::Scheduler.new(max_work_threads: 1)
scheduler_5m = Rufus::Scheduler.new(max_work_threads: 1)

$logger.info 'API syncronization scheduled to run every minute'
on_prem_connector = OnPremConnector.new
scheduler_1m.every '1m' do
  on_prem_connector.submit
end

$logger.info 'Inventory and Infrastructure scheduled to run every 5 minutes'
inventory_collectors = Hash.new
infrastructure_collector = InfrastructureCollector.new
scheduler_5m.cron '*/5 * * * *' do |job|
  collection_time = Time.now.change(sec: 0)

  infrastructure_collector.run
  Infrastructure.each{|inf|
    inventory_collectors[inf.platform_id] ||= InventoryCollector.new(inf) }

  inventory_collectors.each_value{|collector|
    collector.run(collection_time)}
  # TODO may want to move this above collection with different status; if we crash during a run and find_or_initailize_by (cf vmware meter)
  #  we could blow away that inventory and re-collect
  InventoriedTimestamp.create(inventory_at: collection_time, record_status: 'inventoried')

end

[scheduler_1m, scheduler_5m].map(&:join)
