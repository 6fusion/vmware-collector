require 'global_configuration'
require 'host'
require 'infrastructure_collector'
require 'matchable'
require 'network'
require 'on_prem_url_generator'
require 'meter_object'

class Infrastructure
  include Mongoid::Document
  include Mongoid::Timestamps
  include Matchable
  include GlobalConfiguration
  include OnPremUrlGenerator
  include MeterObject

  field :platform_id, type: String
  field :moref, type: String
  field :remote_id, type: String
  field :name, type: String
  field :record_status, type: String
  field :vcenter_id, type: String
  field :custom_id, type: String
  # Tags are currently static defaults only, not updated during collection
  field :tags, type: Set, default: ['platform:VMware', 'collector:VMware']

  field :status, type: String, default: 'online'
  field :vcenter_server, type: String # !! hmmmm
  # field :release_version, type: String, default: 'alpha'

  embeds_many :hosts
  embeds_many :networks
  embeds_many :volumes

  accepts_nested_attributes_for :hosts
  accepts_nested_attributes_for :networks
  accepts_nested_attributes_for :volumes

  # Infrastructure Statuses: created, updated, deleted, verified_create, verified_update
  scope :to_be_created_or_updated, -> { where(:record_status.in => %w(created updated)) }

  index(record_status: 1)
  index(remote_id: 1)
  index(platform_id: 1)
  # TODO: Verify if we still need this index

  def initialize(params={})
    params[:custom_id] ||= "#{params[:platform_id]}-#{params[:vcenter_id]}"
    super
  end

  def self.managed_object_properties
    [:name, :platform_id]
  end

  def submit_create
    if already_submitted?
      $logger.debug { "Infrastructure #{self.custom_id} already present in the 6fusion Meter" }
      self.update_attribute(:record_status, 'updated')
    else
      post_to_api
    end
    self
  end

  def submit_update
    $logger.info "Updating infrastructure #{name} in 6fusion Meter API"
    begin
      response = $hyper_client.put(infrastructure_url(infrastructure_id: custom_id), api_format.merge(status: 'Active'))
      response_json = response.json
      if (response.present? && response.code == 200 && response_json['id'].present?)
        self.record_status = 'verified_update'
      end
    rescue RuntimeError => e
      $logger.error "Error updating infrastructure '#{name} in the 6fusion Meter API"
      raise e
    end
    self
  end

  def attribute_map
    { name: :name }
  end

  def vm_to_host_map
    @vm_to_host_map ||= begin
      h = {}
      hosts.each do |host|
        host.inventory.each { |vm| h[vm] = host }
      end
      h
    end
  end

  def name_with_prefix
    (ENV['VCENTER_DESCRIPTOR'] and !ENV['VCENTER_DESCRIPTOR'].empty?) ?
      "#{ENV['VCENTER_DESCRIPTOR']}: #{self.name}" : self.name
  end

  # Format to submit to OnPrem Console API
  def api_format
    {
      name: name_with_prefix,
      custom_id: custom_id,
      tags: tags,
      # summary: {
      #   # Counts
      #   hosts: hosts.size,
      #   networks: networks.size,
      #   volumes: volumes.size,

      #   # Sums
      #   sockets: total_sockets,
      #   cores: total_cpu_cores,
      #   threads: total_threads,
      #   speed_mhz: total_cpu_mhz,
      #   memory_bytes: total_memory,
      #   storage_bytes: total_storage_bytes,
      #   lan_bandwidth_mbits: total_lan_bandwidth_mbits,
      #   wan_bandwidth_mbits: 0
      # },

      # Nested models
      hosts: hosts.map(&:api_format),
      networks: networks_with_defaults,
      volumes: volumes.map(&:api_format)
    }
  end

  def networks_with_defaults
    ([ Network.new(name: 'default_wan', kind: 'WAN') ] |
      [ Network.new(name: 'default_san', kind: 'SAN') ] |
     networks).map(&:api_format)
  end

end
