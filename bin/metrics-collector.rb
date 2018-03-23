#!/usr/bin/env ruby
require './config/default_includes'
Thread.abort_on_exception = true

$logger.info { 'Metrics collector will check for new inventory every 30 seconds' }
collector = MetricsCollector.new
loop do
  InventoriedTimestamp.ready_for_metering.each do |it|
    it.update_attribute(:record_status, 'queued_for_metering')
    begin
      Timeout.timeout(300){  # TODO move to health check
        collector.run(it) }
    rescue Timeout::Error
      $logger.error { "Collecting metrics for machines at time #{it.inventory_at} timed out." }
    end
  end
  sleep 30
end

