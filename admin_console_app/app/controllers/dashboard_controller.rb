class DashboardController < ApplicationController
  layout 'dashboard'
  include DockerHelper
  include DockerHubHelper

  def index

    @meter_configuration_document = MeterConfigurationDocument.first || MeterConfigurationDocument.new
    @meter_configuration_document.uc6_log_level = Logger::DEBUG

    # Redirect to the registration wizard if registration hasn't occurred yet *unless* the specifically ask for the dashboard
    if ( (!request.env['ORIGINAL_FULLPATH'].include?('dashboard')) and
         ( @meter_configuration_document.nil? or
           @meter_configuration_document.registration_date.blank?) )
      redirect_to registration_index_url
      return
    end

   last_added_machine = Machine.last
   @inventory_size = last_added_machine ? Machine.where(inventory_at: last_added_machine.inventory_at).size : 0

   #!! good idea? bad idea?
   # if ( @meter_configuration_document.meter_version.blank? )
   #   @meter_configuration_document.update_attribute(:meter_version, DockerHubHelper::local_version)
   # end

  end
end
