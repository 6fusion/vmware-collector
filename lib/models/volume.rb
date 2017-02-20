require 'matchable'

class Volume
  include Mongoid::Document
  include Matchable

  field :platform_id, type: String
  field :uuid, type: String
  field :name, type: String
  field :ssd, type: Boolean
  field :storage_bytes, type: Integer, default: 0
  field :volume_type, type: String
  field :accessible, type: String
  field :free_space, type: Integer, default: 0

  def self.attribute_map
    { uuid: :uuid,
      name: :name,
      ssd: :ssd,
      storage_bytes: :capacity,
      volume_type: :type,
      accessible: :accessible,
      free_space: :freeSpace }
  end

  def api_format
    {name: name,
     ssd: ssd || false,
     storage_bytes: storage_bytes,
     volume_type: volume_type,
     accessible: accessible,
     free_space: free_space }
  end
end
