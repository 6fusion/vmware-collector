require 'global_configuration'
require 'mongo_connection'

namespace :db do

  desc "Blank out database"
  task :reset do
    Mongoid.purge!
  end

  desc "Initialize mongo connection"
  task :init_mongo do
    include MongoConnection
    include GlobalConfiguration
    initialize_mongo_connection
  end

  task :reset => :init_mongo

end
