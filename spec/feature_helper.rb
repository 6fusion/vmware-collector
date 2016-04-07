require 'bundler'
$:.unshift File.expand_path('lib'), File.expand_path('lib/shared'), File.expand_path('lib/models'), File.expand_path('spec'), File.expand_path('spec/config')

Bundler.require(:default, :test)

require 'minitest/autorun'
require 'vsphere_helpers'

ENV['METER_ENV'] ||= 'test'

Mongoid.load!('config/mongoid.yml', ENV['METER_ENV'])

DatabaseCleaner.strategy = :truncation
