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
  desc "Submit all inventory to OnPremConsole (in order of priority)"
  task :all do
    OnPremConnector.new.submit
  end

  desc "Submit inventory (machines) to OnPremConsole"
  task :machines do
    on_prem_connector = OnPremConnector.new
    on_prem_connector.submit_machine_creates
    on_prem_connector.submit_machine_deletes
    on_prem_connector.submit_machine_updates
  end

  desc "Submit machine creates to OnPremConsole"
  task :machine_creates do
    OnPremConnector.new.submit_machine_creates
  end

  desc "Submit machine deletes to OnPremConsole"
  task :machine_deletes do
    OnPremConnector.new.submit_machine_deletes
  end

  desc "Submit machine updates to OnPremConsole"
  task :machine_updates do
    OnPremConnector.new.submit_machine_updates
  end

  desc "Submit machine failed creates to OnPremConsole"
  task :machine_failed_creates do
    OnPremConnector.new.handle_machine_failed_creates
  end

  desc "Submit infrastructures (datacenters) to OnPremConsole"
  task :infrastructures do
    OnPremConnector.new.submit_infrastructure_creates
  end

  desc "Submit readings to OnPremConsole"
  task :metrics do
    OnPremConnector.new.submit_reading_creates
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

