require 'global_configuration'
require 'host'
require 'infrastructure_collector'
require 'logging'
require 'matchable'
require 'network'
require 'on_prem_url_generator'

class Infrastructure
  include Mongoid::Document
  include Mongoid::Timestamps
  include Logging
  include Matchable
  include GlobalConfiguration
  include OnPremUrlGenerator

  field :platform_id, type: String
  field :remote_id, type: String
  field :name, type: String
  field :record_status, type: String
  # Tags are currently static defaults only, not updated during collection
  field :tags, type: Array, default: ['platform:VMware', 'collector:VMware']

  # TODO: Check if this is required by the inventory collector
  field :enabled, type: Boolean, default: true
  field :status, type: String, default: 'online'
  field :vcenter_server, type: String # !! hmmmm
  field :release_version, type: String, default: 'alpha'

  embeds_many :hosts
  embeds_many :networks
  embeds_many :volumes

  accepts_nested_attributes_for :hosts
  accepts_nested_attributes_for :networks
  accepts_nested_attributes_for :volumes

  # Infrastructure Statuses: created, updated, deleted, disabled, verified_create, verified_update
  scope :to_be_created_or_updated, -> { where(:record_status.in => %w(created updated)) }
  # TODO: Verify if we still need this index
  scope :enabled, -> { where(enabled: true) }

  index(record_status: 1)

  # TODO: Verify if we still need this index
  index(enabled: 1)

  def total_server_count
    @total_server_count ||= hosts.size
  end

  def total_cpu_cores
    @total_cpu_cores ||= infrastructure_totals[:cpu_cores]
  end

  def total_cpu_mhz
    @total_cpu_mhz ||= infrastructure_totals[:cpu_mhz]
  end

  def total_memory
    @total_memory ||= infrastructure_totals[:memory]
  end

  def total_sockets
    @total_sockets ||= infrastructure_totals[:sockets]
  end

  def total_threads
    @total_threads ||= infrastructure_totals[:threads]
  end

  def total_storage_bytes
    @total_storage_bytes ||= infrastructure_totals[:storage_bytes]
  end

  def total_lan_bandwidth_mbits
    @total_lan_bandwidth_mbits ||= infrastructure_totals[:lan_bandwidth_mbits]
  end

  def infrastructure_totals
    @infrastructure_totals ||= begin
      totals = Hash.new { |h, k| h[k] = 0 }
      hosts.each do |host|
        totals[:cpu_cores] += host.cpu_cores
        totals[:cpu_mhz]   += host.cpu_hz
        totals[:memory]    += host.memory
        totals[:sockets]   += host.sockets
        totals[:threads]   += host.threads
        totals[:lan_bandwidth_mbits] += host.total_lan_bandwidth
      end

      volumes.each do |volume|
        totals[:storage_bytes] += volume.storage_bytes
      end

      totals
    end
  end

  # TODO: CHECK IF WE STILL NEED THIS METHOD
  def enabled?
    enabled
  end

  def disable
    update_attribute('enabled', false)
  end

  def enable
    update_attribute('enabled', true)
  end

  def submit_create
    response = nil
    begin
      logger.info "Submitting #{name} to API for creation in OnPrem"
      response = hyper_client.post(infrastructures_post_url, api_format)
      if response && response.code == 200
        self.remote_id = response.json['id']
        # TODO: see if we need this at this place
        self.enabled = 'true'
        self.release_version = configuration[:on_prem_collector_version]

        update_attribute(:record_status, 'verified_create') # record_status will be ignored by local_inventory class, so we need to update it "manually"
      else
        logger.error "Unable to create infrastructure in OnPrem for #{name}"
        logger.debug "API reponse: #{response}"
      end

    rescue RestClient::Conflict => e
      logger.warn 'Infrastructure already exists in OnPrem; attempting to update local instance to match'
      infrastructures = hyper_client.get_all_resources(infrastructures_url)
      me_as_json = infrastructures.find { |inf| inf['name'].eql?(name) }

      if me_as_json
        # record_status will be ignored by local_inventory class, so we need to update it "manually"
        update_attributes(record_status: 'verified_create', remote_id: me_as_json['remote_id'])
      else
        logger.error "Could not retrieve remote_id from conflict response for infrastructure: #{infrastructure.name}"
      end
    rescue StandardError => e
      logger.error "Error creating infrastructure in OnPrem for #{name}"
      logger.debug e
      raise
    end
    self
  end

  def submit_update
    logger.info "Updating infrastructure #{name} in OnPrem API"
    begin
      response = hyper_client.put(infrastructure_url(infrastructure_id: remote_id), api_format.merge(status: 'Active'))
      response_json = response.json
      if (response.present? && response.code == 200 && response_json['id'].present?)
        self.record_status = 'verified_update'
      end
    rescue RuntimeError => e
      logger.error "Error updating infrastructure '#{name} in OnPrem"
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

  # Format to submit to OnPrem Console API
  def api_format
    {
      name: name,
      custom_id: platform_id,
      tags: tags,
      summary: {
        # Counts
        hosts: hosts.size,
        networks: networks.size,
        volumes: volumes.size,

        # Sums
        sockets: total_sockets,
        cores: total_cpu_cores,
        threads: total_threads,
        speed_mhz: total_cpu_mhz,
        memory_bytes: total_memory,
        storage_bytes: total_storage_bytes,
        lan_bandwidth_mbits: total_lan_bandwidth_mbits,
        wan_bandwidth_mbits: 0
      },

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
