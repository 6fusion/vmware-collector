#!/usr/bin/env ruby -W0
require './config/default_includes'
module InitializeCollectorConfiguration
  def init_configuration
    Thread.abort_on_exception = true
    registration = CollectorRegistration.new
    registration.configure_uc6
    registration.configure_vsphere
    Rake.load_rakefile('/usr/src/app/Rakefile')
    Rake.application['create_indexes'].invoke((ENV['METER_ENV'] || :development).to_s)
    sync = CollectorSyncronization.new
    sync.sync_data
  end
end
