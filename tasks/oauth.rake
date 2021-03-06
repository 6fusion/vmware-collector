require 'global_configuration'

namespace :oauth do

  desc 'Put vmware-collector application ID and secret into console database'
  task  :sync_application do
    ENV['RAILS_ENV'] ||= ENV['METER_ENV']
    config = GlobalConfiguration::GlobalConfig.instance
    puts "Go run this command in the console root"
    puts("RAILS_ENV=#{ENV['RAILS_ENV']} rake oauth:vmware_meter:add_application['#{config[:on_prem_application_id]}','#{config[:on_prem_application_secret]}']")
  end

end
