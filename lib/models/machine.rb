require 'global_configuration'
require 'disk'
require 'nic'
require 'matchable'
require 'on_prem_url_generator'

class Machine
  include Mongoid::Document
  include Mongoid::Timestamps
  include Matchable
  include OnPremUrlGenerator
  include GlobalConfiguration

  field :remote_id,     type: String
  field :platform_id,   type: String
  field :moref,         type: String
  field :record_status, type: String
  field :inventory_at,  type: DateTime
  field :name,          type: String
  field :os,            type: String
  field :virtual_name,  type: String
  field :uuid,          type: String
  field :cpu_count,     type: Integer,  default: 1  # Console requires a value for count and mhz > 0
  field :cpu_speed_hz,  type: Integer,  default: 1
  field :memory_bytes,  type: Integer,  default: 0
  field :status,        type: String,   default: 'unknown'
  field :tags,          type: Set,      default: ['platform:VMware']
  field :metrics,       type: Hash
  field :submitted_at,  type: DateTime

  alias :custom_id :uuid

  field :infrastructure_custom_id, type: String
  field :infrastructure_platform_id, type: String

  embeds_many :disks
  embeds_many :nics
  accepts_nested_attributes_for :disks, :nics

  scope :to_be_created, -> { where(record_status: 'created') }
  scope :to_be_deleted, -> { where(record_status: 'updated').and(status: 'deleted') }
  scope :disks_or_nics_to_be_deleted, -> { any_of({'disks.record_status': 'to_be_deleted'}, {'nics.record_status': 'to_be_deleted'}) }
  scope :failed_creates, -> { where(record_status: 'failed_create') }

  index({ record_status: 1, status: 1 })
  index({ status: 1 })
  index({ 'disks.record_status': 1 })
  index({ 'nics.record_status': 1 })
  index({ platform_id: 1 })
  # Expiration
  index({inventory_at: 1}, {expire_after_seconds: 1.days })

  def self.to_be_updated
    most_recent_updates = Machine.collection.aggregate( [ {
                                                            '$match': { record_status: {
                                                                          '$in': ['updated', 'incomplete', 'verified_create', 'verified_update']
                                                                        }
                                                                      }
                                                          },
                                                          {
                                                            '$sort': { inventory_at: -1 }
                                                          },
                                                          {
                                                            '$group': {
                                                                        '_id': '$platform_id',
                                                                       latest_updated_id: {
                                                                         '$first': '$_id'
                                                                       }
                                                                      }
                                                          } ] )

    Machine.in(id: most_recent_updates.map{|bson| bson[:latest_updated_id]} ).nin(record_status: ['verified_create', 'verified_update'])
  end

  # These need to correspond to the attributes that will be pulled out of
  #  a vSphere objectUpdate object
  def attribute_map
    { platform_id:  :platform_id,
      name:         :name,
      os:           :'config.guestFullName',
      virtual_name: :platform_id,
      uuid:         :'config.instanceUuid',
      cpu_count:    :'summary.config.numCpu',
      memory_bytes: :'summary.config.memorySizeMB',
      status:       :'summary.runtime.powerState'
      #cpu_speed:   :'runtime.host.hardware.cpuInfo.hz' # This is collected by the infrastructures collector
    }
  end

  def self.build_from_vsphere_vm(attribute_set)
    machine = Machine.new
    machine.assign_machine_attributes(attribute_set)
    machine.assign_machine_disks(attribute_set[:disks])
    machine.assign_machine_nics(attribute_set[:nics])
    machine.assign_disk_metrics(attribute_set[:disk_map])
    machine.tags += ["os:#{machine.os}"]  # << operator does not work well; maybe a mongoid bug?
    machine
  end

  # This expects assign_machine_disks to already have been called
  def assign_disk_metrics(attr)
    #!! rescue/error if disk key missing
    #!! comment, make pretty
    # Iterate over the disk files and sum up their allocated storage
    return unless attr

    disks.each do |disk|
      # Important to reference this via string (not symbol), so it remains "matchable" to data pulled from mongo (where keys are always strings)
      usage_bytes = 0
      begin
        if ( attr.values )
          disk_sizes = attr.values.select{|h| h[:disk].present?}
          #!! should this be platform_id and should platform_id == key????
          usage_bytes = disk_sizes.group_by{|h| h[:disk]}[disk.key].map{|p|p[:size]}.sum unless disk_sizes.empty?
          disk.metrics['usage_bytes'] = usage_bytes
        else
          $logger.warn "Missing values from disk attributes: #{attr}"
          disk.metrics['usage_bytes'] = 0
        end
      rescue StandardError => e
        $logger.error e.message
        $logger.debug e.backtrace.join("\n")
        disk.metrics['usage_bytes'] = 0
      end
    end
  end

  def assign_machine_attributes(attr)
    return unless attr
    attribute_map.each do |machine_attr, vsphere_attr|
      if ( attr[vsphere_attr].present? )
        self.send("#{machine_attr}=", attr[vsphere_attr])
      else
        # Some attributes will be missing if machine is powered down
        #  Likewise, machine attributes will be missing if change is only to disk or nic
        #  Or if the machine is migrated to a different host
        self.record_status = 'incomplete'
        $logger.warn "#{vsphere_attr} is missing from the vSphere properties for machine: #{self.platform_id}"
      end
    end
  end

  def assign_machine_disks(disks)
    begin
      self.disks = disks.map{|properties|
        Disk.new(properties) }
    rescue StandardError => e
      $logger.error e.message
      $logger.debug e.backtrace.join("\n")
    end
  end

  def assign_machine_nics(nics)
    begin
      self.nics = nics.each_value.map{|properties| Nic.new(properties.merge(machine_id: self.uuid)) }  # use build?
    rescue StandardError => e
      $logger.error e.message
      $logger.debug e.backtrace.join("\n")
    end
  end

  # Format to submit to OnPrem Console API
  def api_format
    machine_api_format = { 'name': name,
                           'custom_id': uuid,
                           'cpu_count': cpu_count,
                           'cpu_speed_hz': cpu_speed_hz,
                           'memory_bytes': memory_bytes,
                           'status': status,
                           'tags': tags }
#     'infrastructure_id': infrastructure_custom_id,

    # !!! Make sure if field is missing these won't blow up
    # For now, will reject disks and nics missing name (nil) -- may need to reject is missing other fields
    # May need to just refactor to not submit disks/nics at all with machine updates
    # Instead, submit to their own endpoint (and no longer nest under Machines)
    machine_api_format.merge!("disks": disks.reject{|d| d.name.nil?}.map {|disk| disk.api_format }) unless disks.empty?
    machine_api_format.merge!("nics": nics.reject{|n| n.name.nil?}.map {|nic| nic.api_format}) unless nics.empty?

    machine_api_format
  end

  def submit_create
    if already_submitted?
      self.record_status = 'updated'
    else
      begin
        response = hyper_client.post(machines_post_url(infrastructure_id: infrastructure_custom_id), api_format)
        if (response && response.code == 200 && response.json['id'])
          self.remote_id = response.json['id']

          # Machine create (POST) doesn't return remote_ids for disks and nics
          # So, do additional request here and map disk/nic remote_ids back to self
          assign_disks_nics_remote_ids(self.remote_id)
          self.submitted_at = Time.now.utc
          self.record_status = 'verified_create'
        end
      rescue StandardError => e
        $logger.error "Error creating machine '#{name}' in 6fusion Meter API"
        $logger.debug e
        raise e
      end
    end
    self.save
  end


  def already_submitted?
    $logger.debug "Checking 6fusion Meter for #{self.name}:#{self.platform_id}"
    begin
      response = hyper_client.head_machine(custom_id)
      response and (response.code == 200)
    rescue StandardError => e
      $logger.warn "Response for already_submitted? check for machine #{self.platform_id}: #{e.message}"
      $logger.debug e
      false
    end
  end

  def submit_delete(machine_endpoint)
    $logger.info "Deleting machine #{name} from OnPrem API"
    begin
      response = hyper_client.put(machine_endpoint, api_format)
      self.record_status = 'deleted' if (response.code == 200 || response.code == 404)
    rescue StandardError => e
      $logger.error "Error deleting machine '#{name} from OnPrem API"
      $logger.debug e.backtrace.join("\n")
      raise e
    end
  end

  def submit_update(machine_endpoint)
    $logger.info "Updating machine #{name} in OnPrem API"
    begin
      response = hyper_client.put(machine_endpoint, api_format)
      response_json = response.json
      if (response.present? && response.code == 200 && response_json['id'].present?)
        machine_with_disks_nics_response = hyper_client.get(machine_endpoint, {"expand": "disks,nics"})
        response_json = machine_with_disks_nics_response.json # Note: response#json populates remote_ids

        response_disks_json = response_json['embedded']['disks']
        assign_disk_remote_ids(response_disks_json) if response_disks_json

        response_nics_json = response_json['embedded']['nics']
        assign_nic_remote_ids(response_nics_json) if response_nics_json

        self.record_status = 'verified_update'
      end
    rescue StandardError => e
      $logger.error "Error updating machine #{name} in API"
      raise e
    end

    self
  end


  def merge(other)
    other_attrs = other.attributes

    other.attribute_map.each do |mongo,vsphere|
      if ( other_attrs[mongo] &&
           (self[mongo].blank? or ( self[mongo].is_a?(Integer) && self[mongo].eql?(0) ) ) )
        self.send("#{mongo}=", other_attrs[mongo])
      end
    end
    merge_tags(other)
  end

  def merge_tags(other)
    if self.tags != other.tags
      $logger.debug "Tag mismatch:\n#{self.tags.to_a} vs\n#{other.tags.to_a}"
      current_tags = Hash[self.tags.map{|t| t.split(':',2)}]
      older_tags = Hash[other.tags.map{|t| t.split(':',2)}]
      current_tags.each do |key,value|
        if value.blank?
          $logger.debug "Updating tag #{key}: to #{key}:#{older_tags[key]}"
          current_tags[key] = older_tags[key]
        end
      end
      self.tags = current_tags.map{|k,v| "#{k}:#{v}"}
    end

    # These values have defaults other than zero or blank or nil (those are handled above)
    # If they are default values, then use previous (would be default if VSphere doesn't provide, true for VSphere updates)
    self.cpu_count = other.cpu_count if self.cpu_count.eql?(1)
    self.status = other.status if self.status.eql?('unknown')
    self.cpu_speed_hz = other.cpu_count if self.cpu_speed_hz.eql?(1)


    # !!! This code may be necessary for dealing with lost data during migration
    # However, it's causing issue where deleted disks/nics are filled back in
    # unless ( other.disks.empty? or
    #          other.disks.reject{|d|d.name.eql?('fake')}.empty? )
    #   self.disks = (disks | other.disks.reject{|d|d.name.eql?('fake')}).uniq{|d| d.platform_id }
    # end
    # unless ( other.nics.empty? or
    #          other.nics.reject{|d|d.name.eql?('fake')}.empty? )
    #   self.nics = (nics | other.nics.reject{|n|n.name.eql?('fake')}).uniq{|n| n.platform_id}
    # end
  end

  def assign_disks_nics_remote_ids(machine_remote_id)
    machine_with_disks_nics_response = hyper_client.get(retrieve_machine(machine_remote_id))
    response_json = machine_with_disks_nics_response.json # Note: response#json populates remote_ids
    response_disks_json = response_json['embedded']['disks']
    assign_disk_remote_ids(response_disks_json) if response_disks_json

    response_nics_json = response_json['embedded']['nics']
    assign_nic_remote_ids(response_nics_json) if response_nics_json
  end


  private
  def assign_disk_remote_ids(response_disks_json)
    response_disks_ids_names = {}
    response_disks_json.each { |disk| response_disks_ids_names[disk['name']] = disk['id'] }
    self.disks.each { |disk| disk.remote_id = response_disks_ids_names[disk.name] unless disk.remote_id } # Only need to update if no remote id
  end

  def assign_nic_remote_ids(response_nics_json)
    response_nics_ids_names = {}
    response_nics_json.each { |nic| response_nics_ids_names[nic['name']] = nic['id'] }
    self.nics.each { |nic| nic.remote_id = response_nics_ids_names[nic.name] unless nic.remote_id } # Only need to update if no remote id
  end

  def hyper_client
    @hyper_client ||= HyperClient.new
  end
end
