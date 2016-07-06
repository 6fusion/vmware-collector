class InventoriedTimestamp
  include Mongoid::Document
  include Mongoid::Timestamps

  field :inventory_at, type: DateTime # Expires field
  field :record_status, type: String, default: 'inventoried' # inventoried, metering, metered
  field :machine_inventory, type: Array
  field :locked, type: Boolean, default: false
  field :locked_by, type: String
  index(record_status: 1)
  # Expiration
  index({inventory_at: 1}, expire_after_seconds: 1.week)

  def self.most_recent
    InventoriedTimestamp.in(record_status: %w(inventoried metered)).desc(:inventory_at).first
  end

  def self.unlocked_timestamps_for_day(status,inv_timestamp_limit)
    InventoriedTimestamp.where(record_status: status,
      :inventory_at.lte => 6.minutes.ago,
      :inventory_at.gte => 23.hours.ago)
    .asc(:inventory_at).limit(inv_timestamp_limit)
  end
end
