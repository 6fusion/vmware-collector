require 'matchable'
require 'mongoid'

class Nic
  include Mongoid::Document
  include Mongoid::Timestamps
  include Matchable

  # Remote ID it's a UUID
  field :remote_id, type: String
  field :platform_id, type: String
  field :record_status, type: String
  field :name, type: String
  field :kind, type: String, default: 'lan'
  field :ip_address, type: String
  field :mac_address, type: String
  field :metrics, type: Hash

  embedded_in :machine

  def attribute_map
    { platform_id: :key,
      name: :'deviceInfo.label',
      mac_address: :macAddress,
      ip_address: :ip_address }
  end

  def submit_delete(nic_endpoint)
    logger.info "Deleting nic #{platform_id} for machine #{machine.platform_id} from UC6 API, at nic_endpoint #{nic_endpoint}"
    begin
      response = hyper_client.delete(nic_endpoint)
      self.record_status = 'verified_delete' if response.code == 204
    rescue RestClient::ResourceNotFound => e
      logger.error "Error deleting nic #{platform_id} for machine #{machine.platform_id} from UC6 API"
      logger.debug "#{self.inspect}"
      self.record_status = 'unverified_delete'
    rescue
      logger.error "Error deleting machine '#{name} from UC6 API"
      raise
    end

    self
  end

  def api_format
    {
      "id": remote_id,
      "name": name,
      "kind": kind,
      "ip_address": ip_address,
      "mac_address": mac_address
    }
  end

  def hyper_client
    @hyper_client ||= HyperClient.new
  end
end
