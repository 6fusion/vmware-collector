require 'mongoid'
task :create_indexes, :environment do |t, args|
  unless args[:environment]
      puts "Must provide an environment"
      exit
  end

  yaml = YAML.load_file("config/#{ENV['METER_ENV']}/#{ENV['CONTAINER']}_mongoid_container.yml") #needs to be changed

  env_info = yaml[args[:environment]]
  unless env_info
      puts "Unknown environment"
      exit
  end

  Reading.create_indexes
  InventoriedTimestamp.create_indexes
  Machine.create_indexes
end
