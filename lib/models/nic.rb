require 'matchable'
require 'mongoid'

class Nic
  include Mongoid::Document
  include Mongoid::Timestamps
  include Matchable

  # Remote ID it's a UUID
  field :remote_id, type: String
  field :platform_id, type: String
  #field :custom_id, type: String
  field :record_status, type: String
  field :name, type: String
  field :kind, type: String, default: 'lan'
  field :ip_address, type: String
  field :mac_address, type: String
  field :metrics, type: Hash
  field :status, type: String, default: 'active'

  field :machine_id, type: String

  embedded_in :machine

  def attribute_map
    { platform_id: :key,
      name: :'deviceInfo.label',
      mac_address: :macAddress,
      ip_address: :ip_address }
  end

  def submit_delete(nic_endpoint)
    $logger.debug "Deleting nic #{platform_id} for machine #{machine.platform_id} from OnPrem API, at nic_endpoint #{nic_endpoint}"
    begin
      self.status = 'deleted'
      response = hyper_client.put(nic_endpoint)
      self.record_status = 'verified_delete' #if response.code == 204
    rescue RestClient::ResourceNotFound => e
      $logger.error "Error deleting nic #{platform_id} for machine #{machine.platform_id} from OnPrem API"
      $logger.debug "#{self.inspect}"
      $logger.debug e.message
      self.record_status = 'unverified_delete'
    rescue
      $logger.error "Error deleting machine '#{name} from OnPrem API"
      self.record_status = 'unverified_delete'
#      raise
    end

    self
  end

  def custom_id
    "#{self.machine.uuid}-#{self.platform_id}"
  end

  def api_format
    {
      'id': custom_id,
     'custom_id': custom_id,
     'name': name,
     'kind': kind.upcase,
     'status': status
    }
  end

  def hyper_client
    @hyper_client ||= HyperClient.new
  end
end
