source 'https://rubygems.org'

# meter requirements
gem 'activesupport',   '~>4.0'
gem 'concurrent-ruby-ext', require: 'concurrent'
gem 'gibberish'
gem 'mongoid',         '~>4.0'
gem 'oauth2',          '~>1.0'
gem 'rbvmomi',         '~>1.8'
gem 'rest-client',     '~>1.8'
gem 'rufus-scheduler', '~>3.0'

# admin console requirements
gem 'docker-api', require: 'docker'
gem 'foreman'
gem 'ruby-dbus'
gem 'tzinfo-data'

# Locked version to prevent errors, etc
gem 'faye-websocket', '=0.10.0'
gem 'nokogiri', '=1.6.6.2'

group :test do
  gem 'airborne', '>= 0.0.18', require: false
  gem 'awesome_print', require: 'ap'
  gem 'database_cleaner', '~>1.4'
  gem 'factory_girl', '~>4.5.0'
  gem 'google_drive'
  gem 'net-ssh'
  gem 'rspec',   '~>3.2.0'
  gem 'roo-google'
  gem 'time_difference'
end

group :development, :test do
  gem 'pry'
end
