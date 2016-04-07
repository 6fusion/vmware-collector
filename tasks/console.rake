ENV['METER_ENV'] ||= 'development'

Dir.glob('lib/**/*.rb'){|f| require File.basename(f, File.extname(f)) }
ARGV.clear

task :console do
  pry
end

desc "Initialize mongo connection"
task :init_mongo do
  include MongoConnection
  include GlobalConfiguration
  initialize_mongo_connection
end

task :console => :init_mongo
