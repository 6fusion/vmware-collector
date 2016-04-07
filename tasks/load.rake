require 'global_configuration'
require 'uc6_connector'
require 'registration'

namespace :load do

  Mongoid.load!('config/development/mongoid.yml', ENV['METER_ENV'] || :development)

  desc "Retrieve infrastructures from UC6"
  task :infrastructures do
    UC6Connector.new.load_infrastructure_data
  end

  desc "Retrieve inventory (machines) from UC6"
  task :inventory do
    UC6Connector.new.load_machines_data
  end

  desc "Match machines platform IDs to inventory based on machine name"
  task :register_machines do
    Registration::initialize_platform_ids
  end

end
