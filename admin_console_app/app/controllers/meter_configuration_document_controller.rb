class MeterConfigurationDocumentController < ApplicationController

  def update
    @meter_configuration_document = MeterConfigurationDocument.first

    if ( (@meter_configuration_document.container_namespace  != meter_params[:container_namespace]) or
         (@meter_configuration_document.container_repository != meter_params[:container_repository]) )
      Rails.cache.delete(:latest_version)
      Rails.cache.delete(:docker_tags)
    end

    @meter_configuration_document.update_attributes(meter_params)

    if ( @meter_configuration_document.save )
      render nothing: true, :status => 200
    else
      render :status => 400, json: { errors: @meter_configuration_document.errors }
    end
  end

  def meter_params
    params.require(:meter_configuration_document).permit(MeterConfigurationDocument.user_editable_fields)
  end

end
