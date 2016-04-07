require 'ipaddr'
require 'rest-client'
require 'uri'

class Proxy
  include ActiveModel::Validations
  include NetworkHelper

  HOST_PROXY_CONFIG='/host/etc/system/docker.service.d/http-proxy.conf'

  attr_accessor :uc6_proxy_host
  attr_accessor :uc6_proxy_port
  attr_accessor :uc6_proxy_user
  attr_accessor :uc6_proxy_password

  validate :proxy_valid?

  def initialize(attr={})
    attr.each {|k,v|
      instance_variable_set("@#{k}", v) unless v.nil? }
    self.uc6_proxy_port ||= 8080
  end

  def proxy_valid?
    unless ( uc6_proxy_host.blank? )
      begin
        uri = URI.parse(uc6_proxy_host) #validate that host is http://blah.blah like
        if ( uri.kind_of?(URI::HTTP) )
          can_connect?(uc6_proxy_host.split('//')[1], uc6_proxy_port) # throws exception on failures
          RestClient.proxy = proxy_string
          response = RestClient.get('api.6fusion.com')
          if ( response.code == 200 )
            true
          else
            errors.add(:uc6_proxy_host, "does not appear to be valid. Unable to access api.6fusion.com (#{response.code})")
            Rails.logger.debug response.body
          end
        else
          errors.add(:uc6_proxy_host, 'is not a valid URI')
          false
        end
      rescue RestClient::Exception => e
        errors.add(:uc6_proxy_host, "does not appear to be valid. #{e.message} returned when accessing api.6fusion.com")
        Rails.logger.error e.message
      rescue StandardError => e
        errors.add(:uc6_proxy_host, "could not be reached: #{e}")
        false
      rescue URI::InvalidURIError
        errors.add(:uc6_proxy_host, "is not a valid URI")
        false
      end
    end
  end

  # This save doesn't actually write to the database - that's handled in the registration controller.
  # Its purpose is simply to update the appropriate CoreOS configuration file
  def save
    if ( uc6_proxy_host.blank? )
      File.truncate(HOST_PROXY_CONFIG, 0) if File.exists?(HOST_PROXY_CONFIG)
    else
      File.open(HOST_PROXY_CONFIG, 'w'){|f|
        f.write(%Q|Environment="HTTP_PROXY=#{proxy_string}"\n|) }
    end
  end

  def proxy_string
    # copypasta'd from global_configuration.rb
    host_uri = URI.parse(uc6_proxy_host)
    proxy_string = host_uri.scheme + '://'
    unless uc6_proxy_user.blank?
      proxy_string += uc6_proxy_user
      proxy_string += uc6_proxy_password.blank? ? '@' : ":#{uc6_proxy_password}@"
    end

    proxy_string += host_uri.host
    proxy_string += ":#{uc6_proxy_port}" unless uc6_proxy_port.blank?
  end

  def self.build_from_system_settings
    proxy = Proxy.new
    if File.readable?(HOST_PROXY_CONFIG)
      line = File.read(HOST_PROXY_CONFIG)
      if ( md = line.match(%r|Environment="HTTP_PROXY=(https*://)(?:([^:@]+):*([^@]+)?@)*(.+)|) )
        host_and_port, proxy.uc6_proxy_user, proxy.uc6_proxy_password = "#{md[1]}#{md[4]}", md[2], md[3]
        proxy.uc6_proxy_host, proxy.uc6_proxy_password = host_and_port.split(':')
      end
    end
    proxy
  end

end
