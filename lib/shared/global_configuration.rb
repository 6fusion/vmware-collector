require 'set'
require 'singleton'
require 'yaml'

module GlobalConfiguration
  DEFAULT_EMPTY_VALUE = 'not set'.freeze

  def configuration
    GlobalConfig.instance
  end

  class GlobalConfig < Hash
    include Singleton

    def initialize
      super
      @frozen_keys = Set.new
      @environment = ENV['METER_ENV'] || 'development'

      # Initialize with default values
      merge!(defaults)
      load_secrets
    end

    def vsphere_configured?
      errors = true
      [:vsphere_host, :vsphere_user, :vsphere_password].each do |attribute|
        if blank_value?(attribute)
          $logger.info "#{attribute} is not set on the configuration file"
          errors = false
        end
      end
      errors
    end

    def to_s
      "Configuration: \n" +
          map do |key, value|
            "      #{key}: #{value}\n" unless key =~ /password/
          end.join
    end

    def [](key)
      key = aliases[key] || key
      # !! rework fetch_hooks to not require a value being passed in
      apply_fetch_hook(key, fetch(key, nil))
    end

    def []=(key, value)
      if @frozen_keys.include?(key)
        value
      else
        value = apply_store_hook(key, value)
        super(key, value)
      end
    end

    def freeze(key, value)
      $logger.debug "Freezing key/value for '#{key}'"
      store(key, value)
      @frozen_keys << (aliases[key] || key)
    end

    def blank_value?(key)
      self[key].blank? || self[key] == DEFAULT_EMPTY_VALUE
    end

    def present_value?(key)
      !blank_value?(key)
    end

    private

    def aliases
      @aliases ||= {
          # mongo_port: :mongoid_hosts,
          log_level: :on_prem_log_level
      }
    end

    def store_hooks
      @store_hooks ||= {
          # mongo_port: ->(v) { v.split('//').last }, # chop off leading tcp:// docker injects
          encryption_secret: ->(v) { @encryption_secret = v } # analog to fetch hook below to update memoized value
      }
    end

    def fetch_hooks
      @fetch_hooks ||= {
          on_prem_proxy: method(:build_proxy_string),
          on_prem_proxy_port: method(:proxy_port_unless_provided),
          on_prem_api_endpoint: method(:prepend_on_prem_api_host),
          on_prem_oauth_endpoint: method(:prepend_on_prem_api_host),
          # on_prem_infrastructure_id: method(:get_an_infrastructure_id),
      }
    end

    def apply_store_hook(key, value)
      store_hooks.key?(key) ? store_hooks[key].call(value) : value
    end

    def apply_fetch_hook(key, value)
      fetch_hooks.key?(key) ? fetch_hooks[key].call(value) : value
    end

    # ALL defauls values can be changed on the secrets file. All elements that begin with:
    # "on_prem" should be included in on_prem kubernetes secret
    # "vsphere" should be included in vsphere kubernetes secret
    def defaults
      @defaults ||= {
                     # config_root: 'config',
                     data_center: DEFAULT_EMPTY_VALUE,
                     vsphere_session_limit: 10,
                     vsphere_user: DEFAULT_EMPTY_VALUE,
                     vsphere_password: DEFAULT_EMPTY_VALUE,
                     vsphere_host: DEFAULT_EMPTY_VALUE,
                     vsphere_readings_batch_size: 64,
                     vsphere_ignore_ssl_errors: false,
                     vsphere_debug: false,
                     on_prem_api_format: 'json',
                     on_prem_api_host: DEFAULT_EMPTY_VALUE,
                     # on_prem_login_email: DEFAULT_EMPTY_VALUE,
                     # on_prem_login_password: DEFAULT_EMPTY_VALUE,
                     on_prem_batch_size: 500,
                     on_prem_api_endpoint: DEFAULT_EMPTY_VALUE,
                     # on_prem_oauth_endpoint: DEFAULT_EMPTY_VALUE,
                     # on_prem_api_scope: DEFAULT_EMPTY_VALUE,
                     on_prem_api_threads: 2,
                     # on_prem_application_id: DEFAULT_EMPTY_VALUE,
                     # on_prem_application_secret: DEFAULT_EMPTY_VALUE,
                     on_prem_collector_version: DEFAULT_EMPTY_VALUE,
                     on_prem_organization_id: DEFAULT_EMPTY_VALUE,
                     # on_prem_organization_name: DEFAULT_EMPTY_VALUE,
                     # on_prem_meter_id: DEFAULT_EMPTY_VALUE,
                     on_prem_oauth_token: DEFAULT_EMPTY_VALUE,
                     on_prem_refresh_token: DEFAULT_EMPTY_VALUE,
                     on_prem_proxy_host: DEFAULT_EMPTY_VALUE,
                     on_prem_proxy_port: DEFAULT_EMPTY_VALUE,
                     on_prem_proxy_user: DEFAULT_EMPTY_VALUE,
                     on_prem_proxy_password: DEFAULT_EMPTY_VALUE,
                     on_prem_machines_by_inv_timestamp: '500',
                     on_prem_inventoried_limit: 10,
                     on_prem_log_level: Logger::DEBUG,
                     verified_api_connection: false,
                     verified_vsphere_connection: true,
                     # container_namespace: '6fusion',
                     # container_repository: 'vmware-collector'
      }
    end

    # freeze + the updated store allow setting a value such that it can't be overridden
    def store(key, value)
      value = apply_store_hook(key, value)
      key = aliases[key] || key
      super(key, value) unless @frozen_keys.include?(key)
    end

    def load_secrets
      vsphere_secrets = %w(host password user debug ignore-ssl-errors readings-batch-size)
      on_prem_secrets = %w(api-host log-level oauth-endpoint api-endpoint organization-id
                           registration-date machines-by-inv-timestamp inventoried-limit proxy-host proxy-port proxy-user
                           proxy-password oauth-token refresh-token batch-size)

      store_secrets_for(vsphere_secrets, "vsphere")
      store_secrets_for(on_prem_secrets, "on-prem")
    end

    def store_secrets_for(keys, secret)
      keys.each do |name_in_file|
        path = "/var/run/secrets/vmwarecollector/#{secret}/#{name_in_file}"
        if File.exists?(path)
          value = File.read("/var/run/secrets/vmwarecollector/#{secret}/#{name_in_file}")
          store("#{secret}_#{name_in_file}".gsub("-", "_").to_sym, human_to_machine(value.chomp))
        end
      end
    end

    # Map human-readable to ruby-usable
    def human_to_machine(value)
      case value
        when /^true|yes$/ then
          true
        when /^false|no$/ then
          false
          # these can probably be ditched
        when 'debug' then
          Logger::DEBUG
        when 'error' then
          Logger::ERROR
        when 'fatal' then
          Logger::FATAL
        when 'info' then
          Logger::INFO
        when 'warn' then
          Logger::WARN
        else
          value
      end
    end

    def prepend_on_prem_api_host(url)
      url.start_with?('http') ?
          url :
          "#{fetch(:on_prem_api_host)}/#{url}"
    end

    def build_proxy_string(proxy_host)
      return nil if proxy_host.nil? || proxy_host.blank?
      host_uri = URI.parse(proxy_host)
      proxy_string = host_uri.scheme + '://'
      if key?(:on_prem_proxy_user)
        proxy_string += fetch(:on_prem_proxy_user)
        proxy_string += key?(:on_prem_proxy_password) ? ":#{fetch(:on_prem_proxy_password)}@" : '@'
      end
      proxy_string += host_uri.host
      proxy_string += ":#{fetch(:u6_proxy_port)}" if key?(:on_prem_proxy_port)
      proxy_string
    end

    def proxy_port_unless_provided(*)
      port = fetch(:on_prem_proxy_port, '')
      port.blank? ?
          (fetch(:on_prem_proxy_host, '').start_with?('https') ? '443' : '80') :
          port
    end

  end
end
