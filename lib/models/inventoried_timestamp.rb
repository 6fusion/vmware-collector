class InventoriedTimestamp
  include Mongoid::Document
  include Mongoid::Timestamps

  field :inventory_at, type: DateTime # Expires field
  field :record_status, type: String, default: 'inventoried' # inventoried, metering, metered
  field :machine_inventory, type: Array
  field :locked, type: Boolean, default: false
  field :locked_by, type: String
  field :fail_count, type: Integer, default: 0

  index(record_status: 1)
  # Expiration
  index({inventory_at: 1}, expire_after_seconds: 1.week)

  def self.most_recent
    InventoriedTimestamp.in(record_status: %w(inventoried metered)).desc(:inventory_at).first
  end

  def self.ready_for_metering
    InventoriedTimestamp.in(record_status: %w(inventoried))
      .where(:inventory_at.lte => 6.minutes.ago,
             :inventory_at.gte => 23.hours.ago)
      .desc(:inventory_at)
  end

end
