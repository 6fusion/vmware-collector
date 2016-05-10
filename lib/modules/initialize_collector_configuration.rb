#!/usr/bin/env ruby -W0
module InitializeCollectorConfiguration
  def init_configuration
    Rake.load_rakefile('Rakefile')
    Rake.application['create_indexes'].invoke((ENV['METER_ENV'] || :development).to_s)
    Thread.abort_on_exception = true
    registration = CollectorRegistration.new
    registration.configure_uc6
    registration.configure_vsphere
    sync = CollectorSyncronization.new
    sync.sync_data
  end
end
