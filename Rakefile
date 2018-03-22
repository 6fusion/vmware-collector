require 'bundler'
Bundler.require(:default)
$:.unshift File.expand_path('lib'), File.expand_path('lib/shared'), File.expand_path('lib/models')
require_relative './config/defaults'

Dir.glob('tasks/*.rake').each {|r| load r}

# the db:mongoid:create_indexes is very rails-centric, and expects this to be defined
task :environment do
  'default'
end

# load the rakefile providing db:mongoid:create_indexes
spec = Gem::Specification.find_by_name 'mongoid'
load  "#{spec.gem_dir}/lib/mongoid/railties/database.rake"
