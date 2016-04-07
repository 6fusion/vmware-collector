require 'infrastructure_collector'
require 'interval_time'
require 'inventoried_timestamp'
require 'inventory_collector'
require 'metrics_collector'
require 'global_configuration'
require 'host'
require 'machine'
require 'reading'
require 'infrastructure'

using IntervalTime

namespace :submit do
  desc "Submit all inventory to UC6Console (in order of priority)"
  task :all do
    UC6Connector.new.submit
  end

  desc "Submit inventory (machines) to UC6Console"
  task :machines do
    uc6_connector = UC6Connector.new
    uc6_connector.submit_machine_creates
    uc6_connector.submit_machine_deletes
    uc6_connector.submit_machine_updates
  end

  desc "Submit machine creates to UC6Console"
  task :machine_creates do
    UC6Connector.new.submit_machine_creates
  end

  desc "Submit machine deletes to UC6Console"
  task :machine_deletes do
    UC6Connector.new.submit_machine_deletes
  end

  desc "Submit machine updates to UC6Console"
  task :machine_updates do
    UC6Connector.new.submit_machine_updates
  end

  desc "Submit machine failed creates to UC6Console"
  task :machine_failed_creates do
    UC6Connector.new.handle_machine_failed_creates
  end

  desc "Submit infrastructures (datacenters) to UC6Console"
  task :infrastructures do
    UC6Connector.new.submit_infrastructure_creates
  end

  desc "Submit readings to UC6Console"
  task :metrics do
    UC6Connector.new.submit_reading_creates
  end

  desc "Initialize mongo connection"
  task :init_mongo do
    include MongoConnection
    initialize_mongo_connection
  end

  task :inventory => :machines
  task :inventory => :init_mongo
  task :infrastructures => :init_mongo
  # task :all => :init_mongo
  # task :show => :init_mongo
  task :metrics => :init_mongo
  task :readings => :metrics
end

task :submit => 'submit:all'

