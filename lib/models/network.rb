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
      kind: kind
    }
  end
end
