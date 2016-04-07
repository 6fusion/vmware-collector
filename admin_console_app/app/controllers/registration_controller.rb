require 'resolv'
require 'securerandom'
require 'socket'
require 'uri'

require 'global_configuration'
require 'infrastructure'
require 'hyper_client'
require 'metrics_collector'
require 'systemd_helper'
require 'vsphere_session'
require 'uc6_connector'

class RegistrationController < ApplicationController
  layout 'registration'
  include Wicked::Wizard
  include DockerHelper
  include NetworkHelper
  include PasswordHelper

  before_action :set_percent_complete, only: [:show, :update]

  steps :set_password,
        :reset_meter,
        :configure_network,
        :reboot_prompt,
        :upgrade_meter,
        :configure_uc6,
        :configure_organization,
        :configure_vsphere,
        :initialize_meter,
        :start_meter,
        :finished # will redirect to admin dashboard

  def show
    @meter_configuration_document = current_meter_configuration

    case step
    when :set_password
      # Skip if the password has been changed from the default
      skip_step unless PasswordHelper::defaulted?

    when :reset_meter
      @readings_count = Reading.where(record_status: 'created').count
      skip_step if current_meter_configuration.registration_date.blank?

    when :configure_network
      @networking = Networking.build_from_system_settings
      @ntp = NTP.build_from_system_settings
      @proxy = Proxy.build_from_system_settings
    when :reboot_prompt
      session[:reboot_required] ?
        @networking = Networking.build_from_system_settings :
        skip_step

    when :upgrade_meter
      skip_step unless DockerHubHelper::update_available?

    when :configure_uc6
      current_meter_configuration.uc6_api_host ||= case ENV['RAILS_ENV'].to_s
                                                     when 'production'  then 'https://api.6fusion.com'
                                                     when 'staging'     then 'https://api-staging.6fusion.com'
                                                     when 'testing'     then 'https://api-staging.6fusion.com'
                                                     when 'development' then 'http://172.17.8.1:3000' # vagrant<->host bridge IP
                                                     else 'https://api.6fusion.com'
                                                     end  if current_meter_configuration.uc6_api_host.blank?

    when :configure_organization
      @organizations = Rails.cache.fetch(:organizations, expires_in: 2.minutes){ retrieve_organizations }

      if ( @organizations.size == 1 )
        current_meter_configuration.update_attribute(:uc6_organization_id, @organizations.first[:remote_id])
        skip_step
      end
    when :finished
      redirect_to url_for(controller: 'dashboard', action: 'index')
      return
    end

    @meter_configuration_document = current_meter_configuration
    render_wizard
  end


  def update
    current_meter_configuration.update_attributes(meter_params) if params[:meter_configuration_document].present?
    @meter_configuration_document = current_meter_configuration

    case step
      when :set_password        
        # Form validator ensures password matches confirm
        PasswordHelper::set_password(password_params[:password])
        session[:logged_in] = true

      when :reset_meter
        if ( reset_params[:selection] == 'true' )
          SystemdHelper::disable_meter_services
          Mongoid.purge!
          @current_meter_configuration = nil
        end

      when :configure_network
        original = Networking.build_from_system_settings
        @networking = Networking.new(network_params)
        @ntp = NTP.new(ntp_params)
        @proxy = Proxy.new(proxy_params)
        if ( @networking.valid? & @ntp.valid? & @proxy.valid?)
          @ntp.save
          @proxy.save
          @networking.save
          session[:reboot_required] = @networking.reboot_required?
          session[:shutdown_recommended] = (original.vcenter? and @networking.static?) # If they're switching from vCenter-provided to wizard-provided, a shutdown will allow them to clear out the vCenter config
        else
          @networking.ip_address = '' unless @networking.static? # A glitch in the UI can occur if you switch from static to vSphere, since it will have an IP (from the old static config). So we blank this out
          render_wizard
          return
        end

      when :configure_uc6
        unless ( validate_uc6_configuration )
          render_wizard
          return
        end
        current_meter_configuration.remove_attribute(:uc6_login_password)
        signal_meters

      when :configure_organization
        organizations = Rails.cache.fetch(:organizations){ retrieve_organizations }
        selected = organizations.find{|o|
          o[:remote_id].to_s == params[:meter_configuration_document][:uc6_organization_id]}
        current_meter_configuration.update_attribute(:uc6_organization_name, selected[:name]) if selected

      when :configure_vsphere
        unless ( validate_vsphere_configuration )
          render_wizard
          return
        end
        signal_meters

      when :initialize_meter
        # Sticking this here, since meter initialization is the step that will start filling our collections
        ensure_mongo_indexed
        update_meter_id

      when :start_meter
        begin
          current_meter_configuration.update_attribute(:registration_date, Time.now.utc)
          Infrastructure.each {|inf|
            logger.warn "Error submitting meter configuration update to UC6" unless inf.meter_instance.submit_updated_self }

          enable_containers

          last_added_machine = Machine.last
          @inventory_size = last_added_machine ? Machine.where(inventory_at: last_added_machine.inventory_at).size : 0


          # A redirect is appropriate here, but Firefox seems to have issues honoring/responding to a 302 from
          #  the start_meter page... the render seems to work well enough
          #redirect_to url_for(controller: 'dashboard', action: 'index')
          last_added_machine = Machine.last                    
          @inventory_size = last_added_machine ? Machine.where(inventory_at: last_added_machine.inventory_at).size : 0
          render template: 'dashboard/index', layout: 'dashboard'

          return
        rescue StandardError => e
          Rails.logger.warn e
          Rails.logger.debug e.backtrace
        end
    end
    @meter_configuration_document = current_meter_configuration
    render_wizard @meter_configuration_document
  end

  private
  def validate_uc6_configuration
    ( current_meter_configuration.valid? &  #<< don't want this to short circuit
      current_meter_configuration.uc6_api_configured? and
      oauth_succesful? )
  end

  def validate_vsphere_configuration
    begin
      return false unless can_connect?(:vsphere_host, 443)
      GlobalConfiguration::GlobalConfig.instance.refresh
      if ( current_meter_configuration.valid? and current_meter_configuration.vsphere_configured? )
        Timeout::timeout(15) do
          VSphere::refresh
          session = VSphere::session
          if ( session.serviceInstance.content.rootFolder )
            current_meter_configuration.errors.add(:base, 'vSphere level 3 statistics must be enabled at the 5-minute interval') unless ( MetricsCollector::level_3_statistics_enabled? )
          else
            current_meter_configuration.errors.add(:base, 'Could not access vSphere rootFolder. Please verify the supplied credentials are correct and have sufficient access privileges.')
          end
        end
      end
    rescue Timeout::Error => e
      logger.debug session
      logger.debug session.inspect
      current_meter_configuration.errors.add(:base, 'Could not access vSphere: operation timed out.  Please verify the supplied access information.')
    rescue OpenSSL::SSL::SSLError => e
      current_meter_configuration.errors.add(:base, 'Could not access vSphere: SSL verification error.')
    rescue StandardError => e
      logger.debug session
      logger.debug session.inspect
      current_meter_configuration.errors.add(:base, 'Could not access vSphere. Please verify the supplied user has sufficient access privileges.')
      false
    end
    current_meter_configuration.errors.empty?
  end

  def oauth_succesful?
    hyper_client = HyperClient.new
    begin
      # On first registration, these will already be blank. But if a user wanted to change a pasword,
      #  we need to force a token request, so we make sure these are blanked out
      GlobalConfiguration::GlobalConfig.instance.refresh
      GlobalConfiguration::GlobalConfig.instance.delete(:uc6_oauth_token)
      hyper_client.reset_token
      # trigger retrieval of new token
      if ( hyper_client.oauth_token.blank? )
        current_meter_configuration.errors.add(:oauth, 'access token could not be retrieved. Please verify UC6 API options.')
      end
    rescue StandardError => e
      if ( can_connect?(:uc6_api_host, URI.parse(current_meter_configuration.uc6_api_host).port) )
        if ( e.is_a?(OAuth2::Error) )
          # The OAuth2 error messages are useless, so we don't bother showing it to the user
          current_meter_configuration.errors.add(:oauth, "token could not be retrieved. Please verify the UC6 API credentials.")
        else
          current_meter_configuration.errors.add(:oauth, "token could not be retrieved: #{e.message}")
        end
      #else Errors are added as part of can_connect? method
      end
      Rails.logger.debug e
      Rails.logger.debug e.backtrace.join($/)
    end

    current_meter_configuration.errors.empty?
  end

  def can_connect?(field, port)
    begin
      Timeout::timeout(10) {
        host = current_meter_configuration[field].slice(%r{(?:https*://)?([^:]+)(?::\d+)*}i, 1)
        Resolv.new.getaddress(host)
        TCPSocket.new(host, port).close
        true }
    rescue Timeout::Error => e
      current_meter_configuration.errors.add(field, "timed during check: #{e.message}")
      false
    rescue Resolv::ResolvError => e
      current_meter_configuration.errors.add(field, "could not be resolved: #{e.message}")
      false
    rescue Errno::ECONNREFUSED => e
      current_meter_configuration.errors.add(field, "could not be connected to on port #{port}: #{e.message}")
      false
    rescue StandardError => e
      current_meter_configuration.errors.add(field, "could not be validated: #{e.message}")
      false
    end
  end


  def retrieve_organizations(batch_size=500)
    hyper_client = HyperClient.new
    url = "#{current_meter_configuration.uc6_api_host}/api/v2/organizations" #!! more dynamic endpoint?

    #!! begin rescue etc (for request)
    response = hyper_client.get_all_resources(url, {limit: batch_size})

    response.map{|resp| { name: resp['name'], remote_id: resp['remote_id'] }}
  end

  def meter_params

    if ( config = params[:meter_configuration_document] )
      if ( config[:uc6_api_host].present? )
        config[:uc6_api_host] = "https://#{config[:uc6_api_host]}"   unless config[:uc6_api_host].start_with?('http')
        config[:uc6_api_host].chop!                                  if config[:uc6_api_host].end_with?('/')
      end
      config[:uc6_proxy_host] = "https://#{config[:uc6_proxy_host]}" if ( config[:uc6_proxy_host].present? and !config[:uc6_proxy_host].start_with?('http') )
#      [:uc6_proxy_port, :uc6_proxy_user, :uc6_proxy_password].each{|p| config[p] = "" unless config[:uc6_proxy_host].present?} # Blank out other proxy fields if no host, since they'll be ignored anyway with no host

      config[:vsphere_host].slice!(%r{https*://}i)                   if ( config[:vsphere_host].present? and config[:vsphere_host].start_with?('http') )

      # Passwords could have been encrypted with a key that's no longer available
      GlobalConfiguration::GlobalConfig.instance[:uc6_login_password] = config[:uc6_login_password] if ( config[:uc6_login_password].present? )
      GlobalConfiguration::GlobalConfig.instance[:uc6_proxy_password] = config[:uc6_proxy_password] if ( config[:uc6_proxy_password].present? )
      GlobalConfiguration::GlobalConfig.instance[:vsphere_password]   = config[:vsphere_password]   if ( config[:vsphere_password].present? )
    end
    params.require(:meter_configuration_document).permit!
  end

  def password_params
    params.require(:password).permit(:password, :confirm)
  end

  def ntp_params
    params.require(:ntp).permit(:host)
  end
  def proxy_params
    params.require(:meter_configuration_document).permit(:uc6_proxy_host, :uc6_proxy_port, :uc6_proxy_user, :uc6_proxy_password)
  end
  def network_params
    params.require(:networking).permit(:type, :ip_address, :netmask, :gateway, :primary_dns, :secondary_dns)
  end

  def reset_params
    params.require(:reset_meter).permit(:selection)
  end

  def current_meter_configuration
    @current_meter_configuration ||= MeterConfigurationDocument.first || MeterConfigurationDocument.create
  end


  def enable_containers
    systemd = Systemd::Manager.new
    DockerHelper::METER_CONTAINER_NAMES.each do |service|
      systemd.enable_units("meter-#{service}.service", force: true)
      systemd.start("meter-#{service}.service", "replace")
    end
  end


  def update_meter_id
    meter_config_doc = current_meter_configuration
    infrastructure = Infrastructure.enabled.first
    if ( infrastructure )
      meter_config_doc.update_attribute(:uc6_infrastructure_id, infrastructure.remote_id)
      meter_config_doc.update_attribute(:uc6_meter_id, infrastructure.meter_instance.remote_id)
    end
  end

  def meter_configured?
    current_meter_configuration and !current_meter_configuration.registration_date.blank?
  end

  def set_percent_complete
    # funky math here is just to round *down* to the nearest 10; steps with e.g., 43% complete are kinda odd; and rounding down keeps us from
    #  getting to 100% when we're really at 96% etc.
    @percent_complete = ( (wizard_steps.find_index(step.to_sym) / wizard_steps.size.to_f) * 10).floor * 10
  end

  def ensure_mongo_indexed
    # Here we'll check the indexes on the machines collection.
    # If they're in place, we'll assume all our indexes are in place, otherwise we'll run the rake task to create them
    if ( Machine.collection.indexes.count <= 1 )
      Mongoid::Tasks::Database::create_indexes
      raise "Unable to create database indexes" unless Machine.collection.indexes.count > 1 # > 1 because there is always an _id index
    end
  end

end
