require 'logger'  #not to be confused with our logging.rb module
require 'set'
require 'singleton'
require 'yaml'

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
      process_config_overrides

      # Before we attempt to access the MeterConfiguration collection, we need to initialize mongo
      #  in such a way that it doesn't rely on the Configuration module
      #  (i.e., break the circular relationship between the modules)

      #!! dynamically base this off vsphere_session_limit
      # store in such a way that it can be merged with yaml overrides
      store(:mongoid_options, { pool_size: 20 })
      # Update values with configuration from mongo
      # Original configuration, uncomment it to make it work on the container
      initialize_mongo_connection({ mongoid_database:  self[:mongoid_database],
                                    mongoid_hosts:     self[:mongoid_hosts], #["#{ENV['MONGO_PORT_27017_TCP_ADDR']}:#{ENV['MONGO_PORT_27017_TCP_PORT']}"]
                                    mongoid_options:   self[:mongoid_options],
                                    mongoid_log_level: self[:mongoid_log_level]})
      # Comment the following line if you are going to run it on container
      #initialize_mongo_connection({:mongoid_database=>"6fusion_meter_development", :mongoid_hosts=>["localhost:27017"], :mongoid_options=>{:pool_size=>20}, :mongoid_log_level=>1})

      @logger.level = fetch(:uc6_log_level)
      Logging::MeterLog.instance.logger.level = fetch(:uc6_log_level)
    end

    def configured?
      self[:verified_api_connection] && self[:verified_vsphere_connection]
    end
   
    def vsphere_configured?
      errors = true
      [:vsphere_host, :vsphere_user, :vsphere_password].each  do |attribute|
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
        super(key, value)
      end
    end

    def freeze(key, value)
      @logger.debug "Freezing key/value for '#{key}'"
      store(key, value)
      @frozen_keys << (aliases[key] || key)
    end

    def blank_value?( key )
      self[key].blank? || self[key] == 'not set'
    end

    def present_value?( key )
      !blank_value?(key)
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
        mongoid_log_level:  method(:infer_mongoid_log_level)
      }
    end

    def apply_store_hook(key,value)
      store_hooks.has_key?(key) ? store_hooks[key].call(value) : value
    end
    def apply_fetch_hook(key,value)
      fetch_hooks.has_key?(key) ? fetch_hooks[key].call(value) : value
    end

    def defaults
      @defaults ||= {config_root: 'config',
                     data_center: 'not set',
                     vsphere_session_limit: 10,
                     vsphere_user: 'not set',
                     vsphere_password: 'not set',
                     vsphere_host: 'not set',
                     vsphere_readings_batch_size: 500,
                     vsphere_ignore_ssl_errors: false,
                     vsphere_debug: false,
                     uc6_api_format: 'json',
                     uc6_api_host: 'not set',
                     uc6_login_email: 'not set',
                     uc6_login_password: 'not set',
                     uc6_batch_size: 500,
                     uc6_api_endpoint: 'not set',
                     uc6_oauth_endpoint: 'not set',
                     uc6_api_scope: 'not set',
                     uc6_api_threads: 2,
                     uc6_application_id: 'not set',
                     uc6_application_secret: 'not set',
                     uc6_meter_version: 'not set',
                     uc6_organization_id: 'not set',
                     uc6_organization_name: 'not set',
                     uc6_meter_id: 'not set',
                     uc6_oauth_token: 'not set',
                     uc6_refresh_token: 'not set',
                     uc6_proxy_host: 'not set',
                     uc6_proxy_port: 'not set',
                     uc6_proxy_user: 'not set',
                     uc6_proxy_password: 'not set',
                     uc6_log_level: Logger::DEBUG,
                     mongoid_log_level: Logger::INFO,
                     mongoid_hosts: 'localhost:27017',
                     mongoid_database: '6fusion_meter',
                     mongoid_port: 'not set',
                     verified_api_connection: false,
                     verified_vsphere_connection: true,
                     container_namespace: '6fusion',
                     container_repository: 'vmware-collector'
                    }
    end

    # freeze + the updated store allow setting a value such that it can't be overridden
    def store(key, value)
      value = apply_store_hook(key,value)
      key = aliases[key] || key
      super(key, value) unless @frozen_keys.include?(key)
    end

    def config_root
      pwd = Dir.pwd
      @config_root ||= begin
                         case
                         when File.readable?("#{pwd}/../config/#{@environment}/uc6.yml") then "#{pwd}/../config/#{@environment}"
                         when File.readable?('config/uc6.yml') then 'config'
                         when File.readable?('../config/uc6.yml') then '../config'
                         end
                       end
    end

    def process_config_overrides
      ['mongoid'].each {|file| process_yaml(file) }
      ['uc6', 'vsphere'].each{ |file| process_secret(file) }
    end

    def process_yaml(filename)
      file = "#{config_root}/#{filename}.yml"   #"/config/development/#{filename}.yml" #!!! Change to this if you are gonna run it out of container
      if ( File.readable?(file) )
        @logger.debug "Loading configuration overrides from #{file}"
        begin
          config = filename.eql?('mongoid') ?
                     YAML.load_file(file)[@environment]['sessions']['default'] :
                     YAML.load_file(file)[@environment]
          config.each do |key,value|
            store("#{filename}_#{key}".to_sym, human_to_machine(value))
          end
        rescue StandardError => e
          @logger.warn "Could not parse configuration file: #{file}"
          @logger.debug e
          @logger.debug File.read(file)
        end
      end
    end

    def process_secret(filename)
      file = "#{ENV['SECRETS_PATH']}/#{filename}" #"secrets/#{filename}" #!!! Change to this if you are gonna run it out of container
      if File.exists?(file)
        @logger.debug "Loading configuration overrides from #{file}"
        begin
          content = File.open(file, 'rb') { |file| file.read }
          result = JSON.parse(content)
          result.each do |key,value|
            store("#{filename}_#{key}".to_sym, human_to_machine(value))
          end
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

  end

end
