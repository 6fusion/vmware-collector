
Bundler.require(:default, ENV['METER_ENV'] || :development)
$:.unshift 'lib', 'lib/shared', 'lib/models', 'lib/modules'

Dir.glob('lib/**/*.rb'){|f| require File.basename(f, File.extname(f)) }
ARGV.clear

task :console do
  pry
end

desc "Initialize mongo connection"
task :init_mongo do
  Mongoid.load!('config/mongoid.yml', :default)
end

task :console => :init_mongo
