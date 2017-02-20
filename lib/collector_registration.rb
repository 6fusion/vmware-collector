require 'uri'

require 'global_configuration'
require 'json'
require 'logging'
require 'rest_client_extensions'
require 'on_prem_url_generator'
require 'vsphere_session'
require 'metrics_collector'

class CollectorRegistration
  include GlobalConfiguration
  include OnPremUrlGenerator
  include Logging
  include VSphere

  EMAIL_REGEX = /\A([^@\s]+)@((?:[-a-z0-9]+\.)+[a-z]{2,})\Z/i

  def initialize
    @environment = ENV['METER_ENV'] || 'development'
    @configuration = GlobalConfiguration::GlobalConfig.instance
  end

  def configure_on_prem
    if credentials_present?
      verify_connection_from_credentials
    else # no credentials
      if @configuration.present_value?(:on_prem_api_host)
        verify_connection_retrieving_missing_info
      else
        logger.error 'There is missing information on the configuration file'
        exit(1)
      end
    end
  end

  def configure_vsphere
    return false unless can_connect?(:vsphere_host, 443)
    if @configuration.vsphere_configured?
      Timeout.timeout(15) do
        VSphere.refresh
        session = VSphere.session
        if session.serviceInstance.content.rootFolder
          if MetricsCollector.level_3_statistics_enabled?
            logger.info 'Successfully connected to vsphere'
            @configuration[:verified_vsphere_connection] = true
          else
            logger.error 'vSphere level 3 statistics must be enabled at the 5-minute interval'
          end
        else
          logger.error 'Could not access vSphere rootFolder. Please verify the supplied credentials are correct and have sufficient access privileges.'
        end
      end
    end
  rescue Timeout::Error => e
    logger.debug VSphere.session
    logger.debug VSphere.session.inspect
    logger.error 'Could not access vSphere: operation timed out.  Please verify the supplied access information.'
  rescue OpenSSL::SSL::SSLError => e
    logger.error 'Could not access vSphere: SSL verification error.'
  rescue StandardError => e
    logger.debug VSphere.session
    logger.debug VSphere.session.inspect
    logger.error 'Could not access vSphere. Please verify the supplied user has sufficient access privileges.'
    false
  end

  private

  def credentials_present?
    @configuration.present_value?(:on_prem_application_id) && @configuration.present_value?(:on_prem_application_secret) &&
        @configuration.present_value?(:on_prem_login_email) && @configuration.present_value?(:on_prem_login_password)
  end

  def verify_connection_from_credentials
    if on_prem_api_configured? && oauth_succesful?
      retrieve_organization_name
      @configuration[:verified_api_connection] = true
      logger.info 'Succesful connected with on_prem api'
    else
      exit(1)
    end
  end

  def verify_connection_retrieving_missing_info
    retrieve_organization_name
    if @configuration.present_value?(:on_prem_organization_name)
      @configuration[:verified_api_connection] = true
      logger.info 'Succesful connected with on_prem api'
    end
  end

  def on_prem_api_configured?
    @configuration.present_value?(:on_prem_api_host) && valid_user?
  end

  def valid_user?
    if @configuration.blank_value?(:on_prem_refresh_token)
      validate_email && validate_password
    else
      true
    end
  end

  def validate_email
    @configuration.present_value?(:on_prem_login_email) &&
        !!(@configuration[:on_prem_login_email] =~ EMAIL_REGEX)
  end

  def validate_password
    @configuration.present_value?(:on_prem_login_password)
  end

  def oauth_succesful?
    hyper_client = HyperClient.new
    begin
      # On first registration, these will already be blank. But if a user wanted to change a pasword,
      #  we need to force a token request, so we make sure these are blanked out
      GlobalConfiguration::GlobalConfig.instance.delete(:on_prem_oauth_token)
      hyper_client.reset_token
      # trigger retrieval of new token
      if hyper_client.oauth_token.blank?
        puts 'access token could not be retrieved. Please verify OnPrem API options.'
        return false
      else
        return true
      end
    rescue StandardError => e
      if can_connect?(:on_prem_api_host, URI.parse(@configuration[:on_prem_api_host]).port)
        if e.is_a?(OAuth2::Error)
          # The OAuth2 error messages are useless, so we don't bother showing it to the user
          logger.error 'Authentication token could not be retrieved. Please verify the OnPrem API credentials.'
        else
          logger.error "Authentication token could not be retrieved: #{e.message}"
        end
        # else Errors are added as part of can_connect? method
      end
    end
  end

  def can_connect?(field, port)
    logger.info "Resolving IP address of #{@configuration[field]} ..."
    Timeout.timeout(60) do
      host = @configuration[field].slice(%r{(?:https*://)?([^:]+)(?::\d+)*}i, 1)
      Resolv.new.getaddress(host)
      TCPSocket.new(host, port).close
      true
    end
  rescue Timeout::Error => e
    logger.error "#{field} : timed during check: #{e.message}"
    false
  rescue Resolv::ResolvError => e
    logger.error "#{field} :could not be resolved: #{e.message}"
    false
  rescue Errno::ECONNREFUSED => e
    logger.error "#{field} :could not be connected to on port #{port}: #{e.message}"
    false
  rescue StandardError => e
    logger.error "#{field} :could not be validated: #{e.message}"
    false
  end

  def retrieve_organization_name
    hyper_client = HyperClient.new
    if @configuration.present_value?(:on_prem_organization_id)
      response = hyper_client.get(organization_url)
      if response.present?
        result = response.json
        begin
          if response.code == 200
            @configuration[:on_prem_organization_name] = result['name'] if result['name']
          end
        rescue
          logger.error "Organization name could not be retrieved from #{response.json}"
        end
      else
        logger.error 'OnPrem API could not be reached. Please verify OnPrem API options and that the OnPrem API is up.'
        exit(1)
      end
    end
  end
end
