source 'https://rubygems.org'

# meter requirements
gem 'activesupport',   '~>4.0'
gem 'concurrent-ruby-ext', require: 'concurrent'
gem 'gibberish'
gem 'mongoid',         '~>4.0'
gem 'mongoid-encrypted-fields'
gem 'oauth2',          '~>1.0'
gem 'rbvmomi',         '~>1.8'
gem 'rest-client',     '~>1.8'
gem 'rufus-scheduler', '~>3.0'

# admin console requirements
gem 'docker-api', require: 'docker'
gem 'foreman'
gem 'rails'
gem 'ruby-dbus'
#gem 'systemd', :git => 'git://github.com/ledbettj/systemd.git'  # taken down by author; committed locally to meter repo
gem 'thin'
gem 'turbolinks'
gem 'tzinfo-data'
gem 'wicked',           '~>1.1'
gem 'websocket-rails'

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

group :development, :assets do
  gem 'jquery-rails'
  gem 'jquery-ui-rails'
  gem 'jquery-validation-rails'
  gem 'quiet_assets'
  gem 'uglifier'
  gem 'coffee-script'
  gem 'execjs'
  gem 'compass-rails', '>=2.0.5'  # 2.0.4 seems to be getting pulled in, and does not get along with bootstrap
  gem 'bootstrap-sass'
  gem 'font-awesome-sass'
  gem 'chosen-rails'
end
