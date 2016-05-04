require 'global_configuration'
require 'host'
require 'infrastructure_collector'
require 'logging'
require 'matchable'
require 'network'

class Infrastructure
  include Mongoid::Document
  include Mongoid::Timestamps
  include Logging
  include Matchable
  include GlobalConfiguration

  field :platform_id, type: String
  field :remote_id, type: String
  field :name, type: String
  field :record_status, type: String
  field :tags, type: String

  # TODO: Check if this is required by the inventory collector
  field :enabled, type: Boolean, default: true
  field :status, type: String, default: 'online'
  field :vcenter_server, type: String #!! hmmmm
  field :release_version, type: String, default: 'alpha'

  embeds_many :hosts
  embeds_many :networks
  embeds_many :volumes

  accepts_nested_attributes_for :hosts
  accepts_nested_attributes_for :networks
  accepts_nested_attributes_for :volumes

  # Infrastructure Statuses: created, updated, deleted, disabled, verified_create, verified_update
  scope :to_be_created_or_updated, -> { where(:record_status.in => ['created','updated']) }
  # TODO: Verify if we still need this index
  scope :enabled, -> { where(enabled: true) }

  index({ record_status: 1 })

  # TODO: Verify if we still need this index
  index({enabled: 1})

  def total_server_count; @total_server_count ||= hosts.size; end
  def total_cpu_cores; @total_cpu_cores ||= infrastructure_totals[:cpu_cores]; end
  def total_cpu_mhz; @total_cpu_mhz ||= infrastructure_totals[:cpu_mhz]; end
  def total_memory; @total_memory ||= infrastructure_totals[:memory]; end
  def total_sockets; @total_sockets ||= infrastructure_totals[:sockets]; end
  def total_threads; @total_threads ||= infrastructure_totals[:threads]; end
  def total_storage_bytes; @total_storage_bytes ||= infrastructure_totals[:storage_bytes]; end
  def total_lan_bandwidth_mbits; @total_lan_bandwidth_mbits ||= infrastructure_totals[:lan_bandwidth_mbits]; end

  def infrastructure_totals
    @infrastructure_totals ||= begin
      totals = Hash.new{|h,k| h[k]=0 }

      hosts.each do |host|
        totals[:cpu_cores] += host.cpu_cores
        totals[:cpu_mhz]   += host.cpu_hz
        totals[:memory]    += host.memory
        totals[:sockets]   += host.sockets
        totals[:threads]   += host.threads
        totals[:lan_bandwidth_mbits] += host.total_lan_bandwidth
      end

      volumes.each{|volume|
        totals[:storage_bytes] += volume.maximum_size_bytes }

      totals
    end
  end

  # TODO CHECK IF WE STILL NEED THIS METHOD
  def enabled?
    self.enabled
  end

  def disable
    self.update_attribute('enabled', false)
  end

  def enable
    self.update_attribute('enabled', true)
  end

  def submit_create(infrastructure_endpoint)
    response = nil
    begin
      logger.info "Submitting #{name} to API for creation in UC6"
      self.tags = name if tags.blank?
      response = hyper_client.post(infrastructure_endpoint, api_format)
      if ( response and response.code == 200 )
        self.remote_id = JSON.parse(response)["id"]
        # TODO: see if we need this at this place
        self.enabled = 'true'
        self.release_version = configuration[:uc6_meter_version]

        self.update_attribute(:record_status, 'verified_create')  # record_status will be ignored by local_inventory class, so we need to update it "manually"
      else
        logger.error "Unable to create infrastructure in UC6 for #{name}"
        logger.debug "API reponse: #{response}"
      end

    rescue RestClient::Conflict => e
      logger.warn "Infrastructure already exists in UC6; attempting to update local instance to match"
      infrastructures = hyper_client.get_all_resources(infrastructure_endpoint)
      me_as_json = infrastructures.find{|inf| inf['name'].eql?(name) }

      if ( me_as_json )
        # record_status will be ignored by local_inventory class, so we need to update it "manually"
        self.update_attributes(record_status: 'verified_create', remote_id: me_as_json['remote_id'])
      else
        logger.error "Could not retrieve remote_id from conflict response for infrastructure: #{infrastructure.name}"
      end
    rescue StandardError => e
      logger.error "Error creating infrastructure in UC6 for #{name}"
      logger.debug e
      raise
    end
    self
  end

  def submit_update(infrastructure_endpoint)
    response = hyper_client.put("#{infrastructure_endpoint}/#{remote_id}", api_format.merge(status: 'Active'))
  end

  def attribute_map
    { name: :name }
  end

  def vm_to_host_map
    @vm_to_host_map ||= begin
      h = Hash.new
      hosts.each{|host|
        host.inventory.each{|vm| h[vm] = host} }
      h
    end
  end


  def hyper_client
    @hyper_client ||= HyperClient.new
  end

  # Format to submit to UC6 Console API
  def api_format
    {
      name: name,
      #tags: name # Not currently supported,
      summary: {
        # Counts
        hosts: self.hosts.size,
        networks: self.networks.size,
        volumes: self.volumes.size,

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
      hosts: self.hosts.map{|h| h.api_format},
      networks: self.networks.map{|n| n.api_format},
      volumes: self.volumes.map{|v| v.api_format}
    }
  end
end
