require 'ipaddr'
require 'uri'

HOST_TIMESYNCD_CONF = '/host/etc/systemd/timesyncd.conf'

class NTP
  include ActiveModel::Validations

  attr_accessor :host

  validates :host, format: { with: /#{IPAddr::RE_IPV4ADDRLIKE}|(?:\w+\.)+(?:[a-z])/ }, allow_blank: true
  validate :host_reachable?

  def initialize(attr={})
    attr.each {|k,v| instance_variable_set("@#{k}", v) unless v.nil? }
  end

  def host_reachable?
    ntp_message = ""
    exit_code = 0
    begin
      Timeout::timeout(15) {
        exit_code, ntp_message = host.blank? ? HostCommandHelper::run('ntpdate -q 0.coreos.pool.ntp.org') : HostCommandHelper::run("ntpdate -q #{host}") }
    rescue Timeout::Error => e
      Rails.logger.error e.message
      Rails.logger.debug e.backtrace
      errors.add('NTP host', " could not be reached for time synchronization (timed out)")
      false
    rescue StandardError => e
      Rails.logger.error e.message
      Rails.logger.debug e.backtrace
      errors.add('NTP host', " could not be reached: #{e.message}")
      false
    end

    if ( exit_code == 0 )
      true
    else
      errors.add('NTP host', " could not be reached: #{ntp_message}")
      false
    end
  end

  def save
    if ( host.blank? )
      unless ( coreos? )
        File.write(HOST_TIMESYNCD_CONF, File.read(HOST_TIMESYNCD_CONF).sub(/^NTP=(.*)$/, "#NTP=\\1"))
      end
    else
      File.write(HOST_TIMESYNCD_CONF, File.read(HOST_TIMESYNCD_CONF).sub(/^#*NTP=.*$/, "NTP=#{host}"))
    end
    systemd = Systemd::Manager.new
    systemd.stop("systemd-timesyncd.service", "replace")
    systemd.start("systemd-timesyncd.service", "replace")
  end

  def self.build_from_system_settings
    ntp = NTP.new
    unless ( ntp.coreos? )
      ntp.host = File.readlines(HOST_TIMESYNCD_CONF).find{|l| l.start_with?('NTP')}.split('=')[1] if File.readable?(HOST_TIMESYNCD_CONF)
    end
    ntp
  end

  def coreos?
    @coreos ||= (host.blank? and default_timesyncd?)
  end

  def default_timesyncd?
    # If the NTP= line is uncommented, a custom (not default) configuration has been specified
    File.readable?(HOST_TIMESYNCD_CONF) and
      File.readlines(HOST_TIMESYNCD_CONF).select{|line|
      line.start_with?('NTP=')}.empty?
  end

end
