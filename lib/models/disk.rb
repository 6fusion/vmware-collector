require 'matchable'

class Disk
  include Mongoid::Document
  include Mongoid::Timestamps
  include Matchable

  # Remote ID it's a UUID
  field :remote_id, type: String
  field :platform_id, type: String

  field :record_status, type: String
  field :status, type: String, default: 'active'
  field :name, type: String
  field :type, type: String, default: 'disk'
  field :size, type: Integer
  field :key,  type: Integer
  field :metrics, type: Hash, default: {} # usage_bytes (from inventory_collector),
                                          # read_kilobytes, write_kilobytes (from metrics_collector)

  embedded_in :machine

  def attribute_map
    { name: :'deviceInfo.label',
      platform_id: :'backing.uuid',  #!! condense platform_id to key??
      key: 'key',
      metrics: :metrics,
      size: :capacityInBytes }
  end

  def submit_delete(disk_endpoint)
    $logger.debug "ignoring disk delete for #{disk_endpoint}"
    $logger.info "Deleting disk #{platform_id} for machine #{machine.platform_id} from OnPrem API, at disk_endpoint #{disk_endpoint}"
    begin
      status = 'deleted'
      response = hyper_client.put(disk_endpoint, api_format)
      self.record_status = 'verified_delete' #if response.code == 204
    rescue RestClient::ResourceNotFound => e
      $logger.error "Error deleting disk #{platform_id} for machine #{machine.platform_id} from OnPrem API"
      $logger.debug self.inspect
      $logger.debug e
      self.record_status = 'unverified_delete'
    rescue StandardError => e
      $logger.error "Error deleting machine '#{name} from OnPrem API"
      $logger.debug e
      self.record_status = 'unverified_delete'
    end

    self
  end

  def custom_id
    "#{self.machine.uuid}-#{self.platform_id}"
  end

  def api_format
    {
      "id": custom_id,
     "custom_id": custom_id,
     "name": name,
     "storage_bytes": size || 0, # Default to 0 if nil, otherwise API throws error
     "kind": type,
     "status": status
    }
  end

  def hyper_client
    @hyper_client ||= HyperClient.new
  end
end
