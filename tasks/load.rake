require 'global_configuration'
require 'on_prem_connector'
require 'registration'

namespace :load do

  Mongoid.load!("config/#{ENV['METER_ENV']}/#{ENV['CONTAINER']}_mongoid_container.yml", ENV['METER_ENV'] || :development)

  desc "Retrieve infrastructures from OnPrem"
  task :infrastructures do
    OnPremConnector.new.load_infrastructure_data
  end

  desc "Retrieve inventory (machines) from OnPrem"
  task :inventory do
    OnPremConnector.new.load_machines_data
  end

  desc "Match machines platform IDs to inventory based on machine name"
  task :register_machines do
    Registration::initialize_platform_ids
  end

end
