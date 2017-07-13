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
      speed_bits_per_second: speed_or_default.to_i
    }
  end

  def speed_or_default
    # It's expcted that the user-configured speed be provided in gigabits per second, so we multiply it out to bits per second (for API submission)
    if ENV["DEFAULT_#{kind}_IO"]
      ENV["DEFAULT_#{kind}_IO"].to_f * 1000000000
    else
      case kind
      when 'WAN' then 1000000000
      when 'LAN' then 10000000000
      when 'SAN' then 10000000000
      end
    end
  end

end
