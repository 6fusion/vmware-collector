#!/usr/bin/env ruby
require './config/default_includes'
Thread.abort_on_exception = true

Mongoid.load!('config/mongoid.yml', :default)
$logger = Logger.new(STDOUT)
$logger.level = ENV['LOG_LEVEL'] || Logger::INFO
STDOUT.sync = true

$logger.info 'Metrics process scheduled to run every 30 seconds'
collector = MetricsCollector.new
loop do
  InventoriedTimestamp.ready_for_metering.each do |it|
    it.update_attribute(:record_status, 'queued_for_metering')
    begin
      Timeout.timeout(300){  # TODO move to health check
        collector.run(it) }
    rescue Timeout::Error
      $logger.error "Collecting metrics for machines at time #{it.inventory_at} timed out."
    end
  end
  sleep 30
end

