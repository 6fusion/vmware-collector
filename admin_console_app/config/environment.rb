ENV['METER_ENV'] ||= ENV['RAILS_ENV']
# Load the Rails application.
require File.expand_path('../application', __FILE__)

# Initialize the Rails application.
Rails.application.initialize!

# disable output buffering (buffering makes it harder to follow logs)
STDOUT.sync = true
