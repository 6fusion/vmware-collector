require 'logger' # not to be confused with our logging.rb module
require 'set'
require 'singleton'
require 'yaml'
require 'mongo_connection'

module GlobalConfiguration
  DEFAULT_EMPTY_VALUE = 'not set'.freeze

  def configuration
    GlobalConfig.instance
  end

  class GlobalConfig < Hash
    include Singleton
    include MongoConnection

    def initialize
      super
      @frozen_keys = Set.new
      @environment = ENV['METER_ENV'] || 'development'

      @logger = Logger.new(STDOUT)
      STDOUT.sync = true # disable output buffering; makes it hard to follow docker logs
      @logger.progname = File.basename($PROGRAM_NAME, '.rb')

      @logger.formatter = proc do |severity, _datetime, progname, msg|
        "#{progname} (#{severity}): #{msg}\n"
      end

      # Initialize iwth default values
      merge!(defaults)
      # Process environment (e.g., mongo info could be passed in through ENV)
      #  Since environment overrides everything, we "freeze" these values so they won't
      #  get updated by subsequent configuration sources
      (keys + aliases.keys).each do |opt|
        freeze(opt, ENV[opt.to_s.upcase]) if ENV[opt.to_s.upcase].present?
      end

      # Pull in dev/test configs
      process_config_overrides

      # Before we attempt to access the MeterConfiguration collection, we need to initialize mongo
      #  in such a way that it doesn't rely on the Configuration module
      #  (i.e., break the circular relationship between the modules)

      # !! dynamically base this off vsphere_session_limit
      # store in such a way that it can be merged with yaml overrides
      store(:mongoid_options, pool_size: 20)
      # Update values with configuration from mongo
      # Original configuration, uncomment it to make it work on the container
      initialize_mongo_connection(mongoid_database: self[:mongoid_database],
                                  mongoid_hosts: self[:mongoid_hosts], # ["#{ENV['MONGO_PORT_27017_TCP_ADDR']}:#{ENV['MONGO_PORT_27017_TCP_PORT']}"]
                                  mongoid_options: self[:mongoid_options],
                                  mongoid_log_level: self[:mongoid_log_level])
      # Comment the following line if you are going to run it on container
      # initialize_mongo_connection({:mongoid_database=>"6fusion_meter_development", :mongoid_hosts=>["localhost:27017"], :mongoid_options=>{:pool_size=>20}, :mongoid_log_level=>1})

      @logger.level = fetch(:on_prem_log_level)
      Logging::MeterLog.instance.logger.level = fetch(:on_prem_log_level)
    end

    def vsphere_configured?
      errors = true
      [:vsphere_host, :vsphere_user, :vsphere_password].each do |attribute|
        if blank_value?(attribute)
          logger.info "#{attribute} is not set on the configuration file"
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
      @logger.debug "Freezing key/value for '#{key}'"
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
          mongo_port: :mongoid_hosts,
          log_level: :on_prem_log_level
      }
    end

    def store_hooks
      @store_hooks ||= {
          mongo_port: ->(v) { v.split('//').last }, # chop off leading tcp:// docker injects
          encryption_secret: ->(v) { @encryption_secret = v } # analog to fetch hook below to update memoized value
      }
    end

    def get_an_infrastructure_id(*)
      infrastructure = Infrastructure.enabled.first || Infrastructure.first
      infrastructure ? infrastructure.remote_id : nil
    end

    def fetch_hooks
      @fetch_hooks ||= {
          mongoid_database: method(:database_name),
          on_prem_proxy: method(:build_proxy_string),
          on_prem_proxy_port: method(:proxy_port_unless_provided),
          on_prem_api_endpoint: method(:prepend_on_prem_api_host),
          on_prem_oauth_endpoint: method(:prepend_on_prem_api_host),
          on_prem_infrastructure_id: method(:get_an_infrastructure_id),
          mongoid_log_level: method(:infer_mongoid_log_level)
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
      @defaults ||= {config_root: 'config',
                     data_center: DEFAULT_EMPTY_VALUE,
                     vsphere_session_limit: 10,
                     vsphere_user: DEFAULT_EMPTY_VALUE,
                     vsphere_password: DEFAULT_EMPTY_VALUE,
                     vsphere_host: DEFAULT_EMPTY_VALUE,
                     vsphere_readings_batch_size: 500,
                     vsphere_ignore_ssl_errors: false,
                     vsphere_debug: false,
                     on_prem_api_format: 'json',
                     on_prem_api_host: DEFAULT_EMPTY_VALUE,
                     on_prem_login_email: DEFAULT_EMPTY_VALUE,
                     on_prem_login_password: DEFAULT_EMPTY_VALUE,
                     on_prem_batch_size: 500,
                     on_prem_api_endpoint: DEFAULT_EMPTY_VALUE,
                     on_prem_oauth_endpoint: DEFAULT_EMPTY_VALUE,
                     on_prem_api_scope: DEFAULT_EMPTY_VALUE,
                     on_prem_api_threads: 2,
                     on_prem_application_id: DEFAULT_EMPTY_VALUE,
                     on_prem_application_secret: DEFAULT_EMPTY_VALUE,
                     on_prem_collector_version: DEFAULT_EMPTY_VALUE,
                     on_prem_organization_id: DEFAULT_EMPTY_VALUE,
                     on_prem_organization_name: DEFAULT_EMPTY_VALUE,
                     on_prem_meter_id: DEFAULT_EMPTY_VALUE,
                     on_prem_oauth_token: DEFAULT_EMPTY_VALUE,
                     on_prem_refresh_token: DEFAULT_EMPTY_VALUE,
                     on_prem_proxy_host: DEFAULT_EMPTY_VALUE,
                     on_prem_proxy_port: DEFAULT_EMPTY_VALUE,
                     on_prem_proxy_user: DEFAULT_EMPTY_VALUE,
                     on_prem_proxy_password: DEFAULT_EMPTY_VALUE,
                     on_prem_machines_by_inv_timestamp: '500',
                     on_prem_inventoried_limit: 10,
                     on_prem_log_level: Logger::DEBUG,
                     mongoid_log_level: Logger::INFO,
                     mongoid_hosts: 'localhost:27017',
                     mongoid_database: '6fusion_collector',
                     mongoid_port: DEFAULT_EMPTY_VALUE,
                     verified_api_connection: false,
                     verified_vsphere_connection: true,
                     container_namespace: '6fusion',
                     container_repository: 'vmware-collector'}
    end

    # freeze + the updated store allow setting a value such that it can't be overridden
    def store(key, value)
      value = apply_store_hook(key, value)
      key = aliases[key] || key
      super(key, value) unless @frozen_keys.include?(key)
    end

    def config_root
      pwd = Dir.pwd
      @config_root ||= begin
        if File.readable?("#{pwd}/config/#{@environment}/inventory_mongoid_container.yml")
          "#{pwd}/config/#{@environment}"
        elsif File.readable?("config/#{@environment}/inventory_mongoid_container.yml")
          "config/#{@environment}"
        else
          'config'
        end
      end
    end

    def process_config_overrides
      process_yaml
      load_secrets
    end

    def process_yaml
      file = "#{config_root}/#{ENV['CONTAINER']}_mongoid_container.yml" # "/config/development/#{filename}.yml" #!!! Change to this if you are gonna run it out of container
      if File.readable?(file)
        @logger.debug "Loading configuration overrides from #{file}"
        begin
          config = YAML.load(ERB.new(File.read(file)).result)[@environment]['sessions']['default']
          config.each { |key, value| store("mongoid_#{key}".to_sym, human_to_machine(value)) }
        rescue StandardError => e
          @logger.warn "Could not parse configuration file: #{file}"
          @logger.debug e
          @logger.debug File.read(file)
        end
      end
    end

    def load_secrets
      vsphere_secrets = %w(host password user debug ignore-ssl-errors)
      on_prem_secrets = %w(api-host log-level oauth-endpoint api-endpoint organization-id api-scope collector-version
                           registration-date machines-by-inv-timestamp inventoried-limit proxy-host proxy-port proxy-user
                           proxy-password oauth-token refresh-token login-email login-password batch-size application-id
                           application-secret organization-name)

      store_secrets_for(vsphere_secrets, "vsphere")
      store_secrets_for(on_prem_secrets, "on-prem")
    end

    def store_secrets_for(keys, secret)
      keys.each do |name_in_file|
        path = "#{ENV['SECRETS_PATH']}/#{secret}/#{name_in_file}"
        if File.exists?(path)
          value = File.read("#{ENV['SECRETS_PATH']}/#{secret}/#{name_in_file}")
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

    def database_name(*)
      case ENV['METER_ENV']
        when 'production' then
          '6fusion_meter'
        when 'staging' then
          '6fusion_meter_staging'
        when 'test' then
          '6fusion_meter_testing'
        else
          '6fusion_meter_development'
      end
    end

    def infer_mongoid_log_level(*)
      # Mongoid should only be bumped up to debug if it's been explicitly set. I.e., don't assume that because the
      #  meter is at debug, mongoid should be as well (it's really noisy)
      fetch(:mongoid_log_level,
            fetch(:on_prem_log_level, Logger::INFO) <= Logger::INFO ? Logger::INFO : fetch(:on_prem_log_level))
    end

    def proxy_port_unless_provided(*)
      port = fetch(:on_prem_proxy_port, '')
      port.blank? ?
          (fetch(:on_prem_proxy_host, '').start_with?('https') ? '443' : '80') :
          port
    end

  end
end
