
class InventoriedTimestamp
  include Mongoid::Document
  include Mongoid::Timestamps

  field :inventory_at, type: DateTime # Expires field
  field :record_status, type: String, default: 'created' # created, metering, metered

  index({ record_status: 1 })
  # Expiration
  index({inventory_at: 1}, {expire_after_seconds: 1.week})

  def self.most_recent
    InventoriedTimestamp.in(record_status: ['inventoried','metered']).desc(:inventory_at).first
  end
end
