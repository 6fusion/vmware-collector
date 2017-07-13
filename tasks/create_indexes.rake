require 'mongoid'
task :create_indexes do

  puts "here"
  #  if ( Machine.collection.indexes.count <= 1 )

  Mongoid.load!('config/mongoid.yml', :default)

  Mongoid::Tasks::Database::create_indexes
  #    raise "Unable to create database indexes" unless Machine.collection.indexes.count > 1 # > 1 because there is always an _id index
  #   end

  puts "there"

  # unless args[:environment]
  #     puts "Must provide an environment"
  #     exit
  # end

  # yaml = YAML.load_file("config/#{ENV['METER_ENV']}/#{ENV['CONTAINER']}_mongoid_container.yml") #needs to be changed

  # env_info = yaml[args[:environment]]
  # unless env_info
  #     puts "Unknown environment"
  #     exit
  # end



  # Reading.create_indexes
  # InventoriedTimestamp.create_indexes
  # Machine.create_indexes
end
