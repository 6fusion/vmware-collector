require 'global_configuration'
require 'inventoried_timestamp'
require 'local_inventory'
require 'logging'
require 'rbvmomi_extensions'
require 'reading'
require 'vsphere_session'
class MetricsCollector
  include GlobalConfiguration
  include Logging
  using RbVmomiExtensions

  def initialize
    @local_inventory = MachineInventory.new
    @readings = ReadingInventory.new
    @performance_manager = VSphere.wrapped_vsphere_request { VSphere.session.serviceInstance.content.perfManager }

    # !! load profile abilities ?
    confirm_statistics_level
  end

  def run(inventoried_time, morefs_to_meter = [])
    confirm_statistics_level
    machine_morefs = []

    time_to_query = inventoried_time.inventory_at.to_time.utc
    collected_time = time_to_query
    @local_inventory.set_to_time(time_to_query)
    # If no morefs were passed in, use all inventory morefs present for the desired timestamp
    machine_morefs = morefs_to_meter.blank? ? filtered_inventory_morefs : morefs_to_meter
    morefs_present_in_results = []

    logger.info "Collecting consumption metrics for machines inventoried at #{time_to_query}"
    machine_morefs.each_slice(configuration[:vsphere_readings_batch_size]).each do |morefs|
      results = custom_retrieve_stats(morefs,
                                      Reading.metrics,
                                      interval: '300',
                                      start_time: time_to_query,
                                      end_time: (time_to_query + 5.minutes))
      results.each do |vm, result|
        next if @local_inventory[vm.moref].blank?
        morefs_present_in_results << vm.moref
        reading_timestamps = { start_time: time_to_query, end_time: (time_to_query + 5.minutes) }
        reading = Reading.build_from_result(result, @local_inventory[vm.moref], reading_timestamps)
        if reading.end_time
          collected_time = reading.end_time # Save this for faked readings below (in case it somehow inexplicably doesn't match time_to_query)
        end
        @readings << reading
      end
    end

    @readings.each { |r| r.end_time ||= collected_time }
    (machine_morefs - @readings.map(&:machine_platform_id)).each do |moref|
      machine = @local_inventory[moref]
      next if machine.blank?
      reading = Reading.new(infrastructure_platform_id: machine.infrastructure_platform_id,
                            machine_platform_id: machine.platform_id,
                            end_time: collected_time,
                            start_time: (collected_time - 5.minutes),
                            machine_metrics: { cpu_usage_percent: 0,
                                               memory_bytes: 0 })

      reading.machine_platform_id = moref
      machine.disks.each do |disk|
        reading.disk_metrics ||= []
        reading.disk_metrics << { platform_id:     disk.platform_id,
                                  read_kilobytes:  0,
                                  write_kilobytes: 0,
                                  usage_bytes:     disk.metrics['usage_bytes'] || 0 }
      end
      machine.nics.each do |nic|
        reading.nic_metrics ||= []
        reading.nic_metrics << { platform_id:       nic.platform_id,
                                 transmit_kilobits: 0,
                                 receive_kilobits:  0 }
      end
      @readings << reading
    end
    logger.info "Adding #{@readings.size} readings to metrics collection"

    # We don't update the status until all metrics have been collected. This way, if
    #  saving fails, the inventory will remain queued for metering (i.e., it will get
    #  picked up again for processing automatically)

    # FIXME: Apply Lock here
    inventoried_time.update_attribute(:record_status, 'metering')
    @readings.save
    inventoried_time.update_attribute(:record_status, 'metered')
  end

  def confirm_statistics_level
    unless MetricsCollector.level_3_statistics_enabled?
      logger.fatal 'Level 3 statistics must be enabled for the 5-minute interval'
      raise 'Insufficient vSphere statistics collection level'
    end
  end

  def self.level_3_statistics_enabled?
    # Confirm 5-minutes interval is configured for "level 3" statistic in vSphere
    VSphere.wrapped_vsphere_request do
      VSphere.session.serviceInstance.content.perfManager.active_intervals[3].any? { |interval| interval.samplingPeriod == 300 }
    end
  end

  # --- Custom Perf Counter ---

  private

  def filtered_inventory_morefs
    @local_inventory.select do |_platform_id, machine|
      machine.record_status != 'incomplete'
    end.keys
  end

  def perf_counter
    @perf_counter ||= @performance_manager.perfCounter
  end

  def perf_counter_hash
    @perfcounter_hash ||= Hash[perf_counter.map { |x| ["#{x.name}.#{x.rollupType}", x] }]
  end

  def perf_counter_id_hash
    @perfcounter_id_hash ||= Hash[perf_counter.map { |x| [x.key, x] }]
  end

  def custom_retrieve_stats(objects, metrics, opts = {})
    realtime = false

    instances = ['*']
    metric_ids = []

    metrics.each do |metric|
      counter = perf_counter_hash[metric]
      unless counter
        pp perf_counter_hash.keys
        raise "Counter for #{metric} couldn't be found"
      end

      metric_ids << RbVmomi::VIM::PerfMetricId(counterId: counter.key,
                                               instance: metric =~ /^(?:cpu|mem)/ ? '' : '*') # !! refactor Reading.machine_properties et al
    end
    query_specs = objects.map do |obj|
      RbVmomi::VIM::PerfQuerySpec(entity: obj,
                                  metricId: metric_ids,
                                  intervalId: opts[:interval],
                                  startTime: (realtime == false ? opts[:start_time].to_datetime : nil),
                                  endTime: (realtime == false ? opts[:end_time].to_datetime : nil))
    end

    stats = VSphere.wrapped_vsphere_request { @performance_manager.QueryPerf(querySpec: query_specs) }

    Hash[stats.map do |res|
           [
             res.entity,
             {
                 sampleInfo: res.sampleInfo,
                 metrics: Hash[res.value.map do |metric|
                   pc_info = perf_counter_id_hash[metric.id.counterId]
                   metric_name = "#{pc_info.name}.#{pc_info.rollupType}"
                   [[metric_name, metric.id.instance], metric.value]
                 end
                               ]
             }
           ]
         end
        ]
  end
end
