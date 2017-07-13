require 'global_configuration'
require 'host'
require 'infrastructure_collector'
require 'matchable'
require 'network'
require 'on_prem_url_generator'

class Infrastructure
  include Mongoid::Document
  include Mongoid::Timestamps
  include Matchable
  include GlobalConfiguration
  include OnPremUrlGenerator

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


  def already_submitted?
    $logger.info "Checking 6fusion Meter for infrastructure #{self.custom_id}"
    begin
      response = hyper_client.head_infrastructure(custom_id)
      response and (response.code == 200)
    rescue StandardError => e
      $logger.error "Error checking whether already_submitted? for machine: #{self.custom_id}"
      $logger.debug e
      false
    end
  end


  def submit_create
    if already_submitted?
      $logger.debug "Infrastructure #{self.custom_id} already present in the Meter API"
      self.record_status = 'updated'
    else
      begin
        $logger.info "Creating infrastructure #{name} in 6fusion Meter API"
        response = hyper_client.post(infrastructures_post_url, api_format)
        if response && response.code == 200
          self.remote_id = response.json['id']
          update_attribute(:record_status, 'verified_create') # record_status will be ignored by local_inventory class, so we need to update it "manually"
        else
          $logger.error "Unable to create infrastructure in the 6fusion Meter API for #{name}"
          $logger.debug "API reponse: #{response}"
        end
      rescue StandardError => e
        $logger.error "Error creating infrastructure in the 6fusion Meter API for #{name}"
        $logger.error e.message
        $logger.debug e
        raise
      end
    end
    self.save
    self
  end

  def submit_update
    $logger.info "Updating infrastructure #{name} in 6fusion Meter API"
    begin
      response = hyper_client.put(infrastructure_url(infrastructure_id: custom_id), api_format.merge(status: 'Active'))
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

  def hyper_client
    @hyper_client ||= HyperClient.new
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
