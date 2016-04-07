require 'global_configuration'
require 'meter_configuration_document'
require 'mongo_connection'

namespace :db do

  desc "Blank out database"
  task :reset do
    Mongoid.purge!
    mcd = MeterConfigurationDocument.new
    mcd.registration_date = Time.now.utc
    mcd.save
  end

  desc "Initialize mongo connection"
  task :init_mongo do
    include MongoConnection
    include GlobalConfiguration
    initialize_mongo_connection
  end

  task :reset => :init_mongo

end
