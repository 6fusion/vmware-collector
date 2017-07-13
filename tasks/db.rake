require 'global_configuration'

namespace :db do

  desc "Blank out database"
  task :reset do
    Mongoid.purge!
  end

  desc "Initialize mongo connection"
  task :init_mongo do
    Mongoid.load!('config/mongoid.yml', :default)
  end

  task :reset => :init_mongo

end
