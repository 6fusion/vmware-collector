require 'ipaddr'
require 'uri'

class Networking
  include ActiveModel::Validations

  HOST_NETWORK_DIR='/host/etc/systemd/network'
  HOST_NETWORK_CONFIG="#{HOST_NETWORK_DIR}/static.network"

  attr_accessor :ip_address
  attr_accessor :netmask
  attr_accessor :gateway
  attr_accessor :primary_dns
  attr_accessor :secondary_dns

  validates :type, inclusion: { in: %w(vcenter dhcp static automatic) }
  validates :ip_address, format: { with: IPAddr::RE_IPV4ADDRLIKE }, if: :static?
  validates :netmask,    format: { with: IPAddr::RE_IPV4ADDRLIKE }, if: :static?
  validates :gateway,    format: { with: IPAddr::RE_IPV4ADDRLIKE }, if: :static?
  validates :primary_dns,        format: { with: IPAddr::RE_IPV4ADDRLIKE }, if: :static?
  validates :secondary_dns,      format: { with: IPAddr::RE_IPV4ADDRLIKE }, if: :static?, allow_blank: true
  validate  :dns_valid?, if: :static?

  def initialize(attr={})
    attr.each {|k,v|
      instance_variable_set("@#{k}", v) unless v.nil? }
    @type ||= 'dhcp'
    @reboot_required = false
  end

  def static?
    @type.eql?('static')
  end
  def vcenter?
    @type.eql?('vcenter')
    true
  end
  def reboot_required?
    @reboot_required
  end
  def type
    case @type
      when 'vcenter' then 'automatic'
      when 'dhcp'    then 'automatic'
      else @type
    end
  end
  def to_json
    { ip_address:    ip_address,
      netmask:       netmask,
      gateway:       gateway,
      primary_dns:   primary_dns,
      secondary_dns: secondary_dns
    }.to_json
  end

  def fields_match?(other)
    ip_address.eql?(other.ip_address) and
      netmask.eql?(other.netmask)     and
      gateway.eql?(other.gateway)     and
      primary_dns.eql?(other.primary_dns) and
      secondary_dns.eql?(other.secondary_dns)
  end


  def save
    if ( @type.eql?('static') )
      if ( File.writable?(HOST_NETWORKD_DIR) )
        check_against = Networking.build_from_system_settings
        network_file = File.new(HOST_NETWORK_CONFIG, 'w')
        cidr = IPAddr.new(netmask).to_i.to_s(2).count("1")
        network_file.write <<-CONFIG.gsub(/^\s+/,'')
        #Configured by meter registration wizard
        [Match]
        Name=en*

        [Network]
        Address=#{ip_address}/#{cidr}
        Gateway=#{gateway}
        DNS=#{primary_dns}
        #{"DNS=#{secondary_dns}" unless secondary_dns.blank?}
        CONFIG

        @reboot_required = !fields_match?(check_against)
      end
    else  # Ensure comment cleared out (comment is used for check by ovfnetworkd script)
      if ( File.readable?(HOST_NETWORK_CONFIG) and File.size?(HOST_NETWORK_CONFIG) )  #!! refactor to use params_from_file?
        if ( File.open(HOST_NETWORK_CONFIG){|f| f.readline.match(/#Configured by meter registration wizard/)} )
          File.truncate(HOST_NETWORK_CONFIG,0)
          # If previously configured by the meter, and now static, will need a reboot
          @reboot_required = true
        end
      end
    end
  end

  def self.build_from_system_settings
    Networking.new(params_from_file)
  end

  private
  def self.params_from_file
    params = {type: 'dhcp'}

    if ( File.readable?(HOST_NETWORK_CONFIG) and
         File.size?(HOST_NETWORK_CONFIG) )
      dns = []
      File.readlines(HOST_NETWORK_CONFIG).each do |line|
        case line
          when /^DHCP=yes/     then params[:type] = 'dhcp'
          when /^Gateway=(.+)/ then params[:gateway] = $1
          when /^DNS=(.+)$/    then dns << $1
          when /#Configured by meter registration wizard/ then params[:type] = 'static'
          when %r{^Address=([^/]+)/(.+)$}
            params[:ip_address] = $1
            params[:netmask]    = IPAddr.new('255.255.255.255').mask($2).to_s
        end
        params[:type] = 'vcenter' if ( !params[:type].eql?('static') and params[:ip_address].present? )
      end
      dns_types = %w(primary secondary)
      dns.each_with_index{|nameserver,i|
        params[:"#{dns_types[i]}_dns"] = nameserver }
    end

    params
  end

  def dns_valid?
    begin
      Timeout::timeout(10) {
        Resolv.new.getaddress('api.6fusion.com') }
    rescue StandardError => e
      errors.add(:primary_dns, "Could not resolve api.6fusion.com. This could indicate a problem with DNS configuration.")
    end
  end

end
