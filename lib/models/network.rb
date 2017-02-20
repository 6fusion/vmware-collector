require 'matchable'

class Network
  include Mongoid::Document
  include Mongoid::Timestamps
  include Matchable

  field :platform_id, type: Integer
  field :remote_id, type: Integer

  field :name, type: String
  field :kind, type: String, default: 'LAN'

  embedded_in :infrastructures

  def api_format
    {
      name: name,
      kind: kind,
      speed_bits_per_second: speed_or_default
    }
  end

  def speed_or_default
    if kind.eql?('WAN')
      ENV['DEFAULT_WAN_IO'] || 100000000
    elsif kind.eql?('SAN')
      ENV['DEFAULT_DISK_IO'] || 100000000000
    else
      ENV['DEFAULT_LAN_IO'] || 100000000000
    end
  end
end
