ENV['METER_ENV'] ||= 'test'
ENV['RSPEC_ENV'] ||= ENV['METER_ENV']
ENV['MONGOID_ENV'] ||= ENV['METER_ENV']

require 'bundler'
Bundler.require(:default, ENV['METER_ENV'])
$:.unshift 'spec', 'lib', 'lib/models', 'lib/shared'

DatabaseCleaner.strategy = :truncation

RSpec.configure do |config|
  config.before(:each) do
    begin
      DatabaseCleaner.start
      #FactoryGirl.lint
    ensure
      DatabaseCleaner.clean
    end
  end
  config.include FactoryGirl::Syntax::Methods
  config.alias_example_to :fit, :focused => true
  config.filter_run :focused => true
  config.run_all_when_everything_filtered = true
end

FactoryGirl.definition_file_paths = %w(spec/factories)
FactoryGirl.find_definitions

Mongoid.load!('config/mongoid.yml', ENV['METER_ENV'])
