#!/usr/bin/env ruby
$:.unshift 'lib','lib/models'

require 'bundler'
Bundler.require(:default, ENV['METER_ENV'] || :test)

require 'rbvmomi/utils/perfdump'


namespace :test do


  desc "Test Performance Metric Collection"
  task :metrics do
    # perf_agg = RbVmomi::PerfAggregator.new
    perf_agg = PerfAggregator.new
    root_folder = VSphere::session.serviceInstance.content.rootFolder

    # results = perf_agg.all_inventory_flat(root_folder)

    vm_info = perf_agg.collect_info_on_all_vms([root_folder])

    # Using ListViews ... Doesn't blow up but doesn't return any data....
    # WIPMetricCollector.new.run
  end

end
