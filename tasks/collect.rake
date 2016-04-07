require 'global_configuration'
require 'mongo_connection'
require 'infrastructure_collector'
require 'interval_time'
require 'inventoried_timestamp'
require 'inventory_collector'
require 'metrics_collector'
require 'host'
require 'machine'
require 'reading'
require 'infrastructure'


using IntervalTime

namespace :collect do

  desc "Collect infrastructures (datacenters) from vSphere"
  task :infrastructures do
    InfrastructureCollector.new.run
  end

  desc "Collect inventory from vSphere"
  task :inventory do
    Rake::Task["collect:infrastructures"].invoke if Infrastructure.empty?
    now = Time.now.truncated - 10.minutes
    inventoried_timestamp = InventoriedTimestamp.create(inventory_at: now)
    Infrastructure.not.where('meter_instance.status': 'disabled').each {|inf|
      InventoryCollector.new(inf).run(now) }
    inventoried_timestamp.record_status = 'inventoried'
    inventoried_timestamp.save
  end

  desc "Collect VM metrics from vSphere"
  task :metrics do
    Rake::Task["collect:inventory"].invoke if InventoriedTimestamp.where(record_status: 'inventoried').empty?
    MetricsCollector.new.run( InventoriedTimestamp.where(record_status: 'inventoried').desc(:inventory_at).first )
  end

  desc "Running missing readings handler"
  task :missing do
    MissingLocalReadingsHandler.new.run
  end

  desc "Show collected records"
  task :show do
    puts "Inventory Times:"
    InventoriedTimestamp.each{|it| puts "\t#{it.inventory_at}"}
    infrastructures = Infrastructure.all
    puts "Infrastructures (#{infrastructures.size}):"
    infrastructures.each{|inf|
      puts "\t#{inf.name}"
      [:platform_id, :total_server_count, :total_cpu_cores,
       :total_cpu_mhz, :total_memory_mb, :total_storage_gb,
       :record_status].each{|attr| puts "\t\t#{attr}:#{inf[attr]}" } }
  end

  task :all => [:infrastructures, :inventory, :metrics]

  desc "Initialize mongo connection"
  task :init_mongo do
    include MongoConnection
    include GlobalConfiguration
    initialize_mongo_connection
  end

  task :inventory => :init_mongo
  task :infrastructures => :init_mongo
  task :all => :init_mongo
  task :show => :init_mongo
  task :metrics => :init_mongo
  task :reset => :init_mongo


  namespace :reset do
    desc "Clear out collected infrastructures"
    task :infrastructure do
      Infrastructure.delete_all
    end
    desc "Clear out collected inventory"
    task :inventory do
      Machine.delete_all
      InventoriedTimestamp.delete_all
    end
    desc "Clear out collected metrics"
    task :metrics do
      Reading.delete_all
    end
    desc "Clear out collected remote IDs"
    task :prid do
      PlatformRemoteId.delete_all
    end
    task :all => [:infrastructure, :inventory, :metrics, :prid ]
    task :inventory => :init_mongo
    task :infrastructures => :init_mongo
    task :metrics => :init_mongo

  end
  desc "Clear out all collected collections"
  task :reset => 'reset:all'

end
