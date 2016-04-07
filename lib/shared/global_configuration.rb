require 'logger'  #not to be confused with our logging.rb module
require 'set'
require 'singleton'
require 'yaml'

require 'meter_configuration_document'
require 'mongo_connection'

module GlobalConfiguration
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
      @logger.progname = File::basename($PROGRAM_NAME,'.rb')

      @logger.formatter = proc do |severity, datetime, progname, msg|
        "#{progname} (#{severity}): #{msg}\n"
      end

      # Initialize iwth default values
      merge!(defaults)

      # Process environment (e.g., mongo info could be passed in through ENV)
      #  Since environment overrides everything, we "freeze" these values so they won't
      #  get updated by subsequent configuration sources

      (keys + aliases.keys).each {|opt|
        freeze(opt, ENV[opt.to_s.upcase]) if ENV[opt.to_s.upcase].present? }

      # Pull in dev/test configs
      process_yaml_overrides

      # Before we attempt to access the MeterConfiguration collection, we need to initialize mongo
      #  in such a way that it doesn't rely on the Configuration module
      #  (i.e., break the circular relationship between the modules)

      #!! dynamically base this off vsphere_session_limit
      # store in such a way that it can be merged with yaml overrides
      store(:mongoid_options, { pool_size: 20 })
      # Update values with configuration from mongo
      initialize_mongo_connection({ encryption_secret: 'not set',
                                    mongoid_database:  self[:mongoid_database],
                                    mongoid_hosts:     self[:mongoid_hosts],
                                    mongoid_options:   self[:mongoid_options],
                                    mongoid_log_level: self[:mongoid_log_level]})

      meter_configuration_document.attributes.each do |key,value| # the value can't actually be used for the encrypted fields, hence the "send" below
        begin
          next if %w(_id created_at updated_at).include?(key)  #!! cleanup
          store(key.to_sym, meter_configuration_document.send(key)) unless value.blank?
        rescue Gibberish::AES::SJCL::DecryptionError => e
          @logger.warn e.message
          @logger.debug e
          store(key.to_sym, 'unable to decrypt' ) unless value.blank?
        end
      end

      Mongoid::EncryptedFields.cipher = Gibberish::AES.new( retrieve_encryption_secret )
      refresh

      @logger.level = fetch(:uc6_log_level)
      Logging::MeterLog.instance.logger.level = fetch(:uc6_log_level)
    end

    def configured?
      !fetch(:registration_date,"").blank?
    end

    def refresh
      process_yaml_overrides

      # Update values with configuration from mongo
      meter_configuration_document.attributes.each do |key,value|
        next if %w(_id created_at updated_at).include?(key)  #!! cleanup
        begin
          store(key.to_sym, meter_configuration_document.send(key)) unless value.nil?
        rescue Gibberish::AES::SJCL::DecryptionError => e
          @logger.warn e.message
          @logger.debug e.backtrace
          store(key.to_sym, 'unable to decrypt' ) unless value.blank?
        end
      end
    end

    def to_s
      "Configuration: \n" +
      map do |key, value|
        "      #{key}: #{value}\n" unless key.match(/password/)
      end.join
    end

    def [](key)
      key = aliases[key] || key
      #!! rework fetch_hooks to not require a value being passed in
      apply_fetch_hook(key,fetch(key,nil))
    end

    def []=(key,value)
      if ( @frozen_keys.include?(key) )
        value
      else
        value = apply_store_hook(key,value)
        update_mongo(key,value)
        super(key, value)
      end
    end

    def freeze(key, value)
      @logger.debug "Freezing key/value for '#{key}'"
      store(key, value)
      @frozen_keys << (aliases[key] || key)
    end

    private
    def aliases
      @aliases ||= {
        mongo_port: :mongoid_hosts,
        log_level: :uc6_log_level    }
    end

    def store_hooks
      @store_hooks ||= {
        mongo_port:         lambda{|v| v.split('//').last}, #chop off leading tcp:// docker injects
        encryption_secret:  lambda{|v| @encryption_secret = v } # analog to fetch hook below to update memoized value
      }
    end

    def get_an_infrastructure_id(*)
      infrastructure = Infrastructure.enabled.first || Infrastructure.first
      infrastructure ? infrastructure.remote_id : nil
    end

    def fetch_hooks
      @fetch_hooks ||= {
        mongoid_database:   method(:database_name),
        uc6_proxy:          method(:build_proxy_string),
        uc6_proxy_port:     method(:proxy_port_unless_provided),
        uc6_api_endpoint:   method(:prepend_uc6_api_host),
        uc6_oauth_endpoint: method(:prepend_uc6_api_host),
        uc6_infrastructure_id: method(:get_an_infrastructure_id),
        mongoid_log_level:  method(:infer_mongoid_log_level),
        encryption_secret:  method(:retrieve_encryption_secret)
      }
    end

    def apply_store_hook(key,value)
      store_hooks.has_key?(key) ? store_hooks[key].call(value) : value
    end
    def apply_fetch_hook(key,value)
      fetch_hooks.has_key?(key) ? fetch_hooks[key].call(value) : value
    end

    def defaults
      @defaults ||= { config_root: 'config',
                      data_center: nil,
                      encryption_secret: 'see fetch_hook method',
                      vsphere_session_limit: 10,
                      vsphere_user: 'not set',
                      vsphere_password: 'not set',
                      vsphere_host: 'not set',
                      vsphere_readings_batch_size: 500,
                      vsphere_ignore_ssl_errors: false,
                      vsphere_debug: false,
                      uc6_api_host: 'not set',
                      uc6_login_email: 'not set',
                      uc6_login_password: 'not set',
                      uc6_batch_size: 500,
                      uc6_api_endpoint: 'api/v2',
                      uc6_oauth_endpoint: 'oauth',
                      uc6_api_scope: 'admin_organization',
                      uc6_api_threads: 2,
                      uc6_application_id: 'a1acf7ed12ecd4a9857e5d01fc64df7c0bb86dc380cd4b4347fc7c979b1251e6',
                      uc6_application_secret: '70c57259e3d20edffd902a227110eb0f32e9e9a3386bbc61e0e62b501d7d6c68',
                      uc6_meter_version: 'alpha',
                      uc6_log_level: Logger::DEBUG,
                      mongoid_log_level: Logger::INFO,
                      mongoid_hosts: 'localhost:27017',
                      mongoid_database: '6fusion_meter' }
    end

    # freeze + the updated store allow setting a value such that it can't be overridden
    def store(key, value)
      value = apply_store_hook(key,value)
      key = aliases[key] || key
      super(key, value) unless @frozen_keys.include?(key)
    end

    def config_root
      @config_root ||= begin
                         case
                         when File.readable?("config/#{@environment}/uc6.yml") then "config/#{@environment}"
                         when File.readable?('config/uc6.yml') then 'config'
                         when File.readable?('../config/uc6.yml') then '../config'
                         end
                       end
    end

    def process_yaml_overrides
      ['mongoid','vsphere','uc6'].each {|file|
        process_yaml(file) }
    end

    def process_yaml(filename)
      file = "#{config_root}/#{filename}.yml"
      if ( File.readable?(file) )
        @logger.debug "Loading configuration overrides from #{file}"
        begin
          config = filename.eql?('mongoid') ?
                     YAML.load_file(file)[@environment]['sessions']['default'] :
                     YAML.load_file(file)[@environment]
          config.each {|key,value|
            store("#{filename}_#{key}".to_sym, human_to_machine(value)) }
        rescue StandardError => e
          @logger.warn "Could not parse configuration file: #{file}"
          @logger.debug e
          @logger.debug File.read(file)
        end
      end
    end

    # Map human-readable to ruby-usable
    def human_to_machine(value)
      case value
        when /^true|yes$/ then true
        when /^false|no$/ then false
        when 'debug' then Logger::DEBUG
        when 'error' then Logger::ERROR
        when 'fatal' then Logger::FATAL
        when 'info' then Logger::INFO
        when 'warn' then Logger::WARN
        else value
      end
    end

    def prepend_uc6_api_host(url)
      url.start_with?('http') ?
        url :
        "#{fetch(:uc6_api_host)}/#{url}"
    end

    def build_proxy_string(proxy_host)
      return nil if proxy_host.nil? or proxy_host.blank?
      host_uri = URI.parse(proxy_host)
      proxy_string = host_uri.scheme + '://'
      if has_key?(:uc6_proxy_user)
        proxy_string += fetch(:uc6_proxy_user)
        proxy_string += has_key?(:uc6_proxy_password) ? ":#{fetch(:uc6_proxy_password)}@" : '@'
      end
      proxy_string += host_uri.host
      proxy_string += ":#{fetch(:u6_proxy_port)}" if has_key?(:uc6_proxy_port)
      proxy_string
    end

    def database_name(*)
      case ENV['METER_ENV']
        when 'production' then '6fusion_meter'
        when 'staging' then '6fusion_meter_staging'
        when 'test' then '6fusion_meter_testing'
        else '6fusion_meter_development'
      end
    end

    def retrieve_encryption_secret(*)
      @encryption_secret ||= begin
        if !( self[:uc6_meter_id] and self[:uc6_organization_id] and self[:uc6_infrastructure_id] and self[:uc6_meter_id] )
          @logger.warn "Cannot retrieve encryption secret from UC6. Missing a required parameter org/inf/meter: "\
                       "#{self[:uc6_organization_id]}/#{self[:uc6_infrastructure_id]}/#{self[:uc6_meter_id]}"
          ""
        else
          url = "#{self[:uc6_api_endpoint]}/organizations/#{fetch(:uc6_organization_id)}" \
                "/infrastructures/#{self[:uc6_infrastructure_id]}/vmware_meters/#{fetch(:uc6_meter_id)}"
          hyper_client = HyperClient.new(self)
          response = hyper_client.get(url)
          # FIXME remove this before alpha release
          @logger.debug "key retrieved: #{response.json['password']}"
          response.json['password'] # this is not actually the password, just randomness we use as an encryption key
        end
      rescue StandardError => e
        @logger.error "Can't retrieve encryption secret from UC6."
        @logger.error e.message
        @logger.debug e.backtrace.join("\n")
        ""
      end
    end

    def infer_mongoid_log_level(*)
      # Mongoid should only be bumped up to debug if it's been explicitly set. I.e., don't assume that because the
      #  meter is at debug, mongoid should be as well (it's really noisy)
      fetch(:mongoid_log_level,
            fetch(:uc6_log_level, Logger::INFO) <= Logger::INFO ? Logger::INFO : fetch(:uc6_log_level))
    end

    def proxy_port_unless_provided(*)
      port = fetch(:uc6_proxy_port,"")
      port.blank? ?
        (fetch(:uc6_proxy_host,"").start_with?('https') ? '443' : '80') :
        port
    end

    def meter_configuration_document
      MeterConfigurationDocument.first || MeterConfigurationDocument.new  # There should only be one document in this collection
    end

    def update_mongo(key,value)
      meter_configuration_document.update_attribute(key.to_sym,value) if
        meter_configuration_document.fields.keys.include?(key.to_s)
    end

  end

end
