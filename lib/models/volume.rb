require 'matchable'

class Volume
  include Mongoid::Document
  include Matchable

  field :platform_id, type: String
  field :uuid, type: String
  field :name, type: String
  field :ssd, type: Boolean
  field :maximum_size_bytes, type: Integer, default: 0
  field :volume_type, type: String
  field :accessible, type: String
  field :free_space, type: Integer, default: 0

  def self.attribute_map
    { uuid: :uuid,
      name: :name,
      ssd: :ssd,
      maximum_size_bytes: :capacity,
      volume_type: :type,
      accessible: :accessible,
      free_space: :freeSpace }
  end

  def api_format
    { name: name,
      ssd: ssd,
      maximum_size_bytes: maximum_size_bytes,
      volume_type: :volume_type,
      accessible: :accessible,
      free_space: :free_space }
  end
end
