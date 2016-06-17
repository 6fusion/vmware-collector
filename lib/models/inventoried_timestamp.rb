require 'mongoid-locker'
class InventoriedTimestamp
  include Mongoid::Document
  include Mongoid::Locker
  include Mongoid::Timestamps

  field :inventory_at, type: DateTime # Expires field
  field :record_status, type: String, default: 'inventoried' # inventoried, metering, metered
  field :machine_inventory, type: Array
  field :locked, type: Boolean, default: false
  timeout_lock_after TIMEOUT_LOCK_RELEASE_TIME
  index(record_status: 1)
  # Expiration
  index({inventory_at: 1}, expire_after_seconds: 1.week)

  def self.most_recent
    InventoriedTimestamp.in(record_status: %w(inventoried metered)).desc(:inventory_at).first
  end
end
