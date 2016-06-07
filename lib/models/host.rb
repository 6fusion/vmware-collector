require 'rbvmomi_extensions'
require 'matchable'

class Host
  include Mongoid::Document
  include Matchable
  using RbVmomiExtensions

  field :platform_id, type: String

  field :uuid, type: String
  field :name, type: String
  # field :tags, type: Array (Not supported)
  field :cluster, type: String

  field :cpu_hz, type: Integer # !!! Todo: rename cpu_speed_hz
  field :cpu_model, type: String
  field :cpu_cores, type: Integer # !!! Todo: rename Cores
  field :sockets, type: Integer
  field :threads, type: Integer

  field :cpus, type: Array # array of hashes (vendor, model, cpu_hz)
  field :host_bus_adapters, type: Array # array of hashes (key, model, speed_mbits)
  field :nics, type: Array # array of hashes (key, speedMb)
  # field :nics # !!! Todo: Nest these ? (name, speed_mbits)
  # field :cpus # (vendor, model, speed_hz)

  field :memory, type: Integer # !!! Todo: rename memory_bytes
  field :vendor, type: String
  field :model, type: String
  field :os, type: String, default: 'VMware ESXi'
  field :os_version, type: String
  field :os_vendor, type: String

  # other info?
  field :inventory, type: Array # stash VM platform_ids here

  embedded_in :infrastructures

  def self.build_from_vsphere_result(attribute_set)
    host = Host.new
    attribute_map.each do |local, vsphere|
      next unless attribute_set[vsphere].present?
      if local == :inventory
        host.inventory = attribute_set[vsphere].map(&:moref) # moref is a refinement, so &: syntax doesn't work
      else
        host.send("#{local}=", attribute_set[vsphere])
      end
    end

    host
  end

  def total_lan_bandwidth
    nics ?
        nics.inject(0) { |sum, nic| sum + (nic[:speed_mbits] ? nic[:speed_mbits] : 0) } :
      0
  end

  # Keys used for matching
  # Key/values used by vsphere
  def self.attribute_map
    {platform_id: :platform_id,
     uuid:        :'summary.hardware.uuid',
     name:        :name,
     # tag:         :tag, # not supported currently
     cluster:     :parent, # VSphere maps Clusters to Hosts, doesn't use value here
     cpu_hz:      :'hardware.cpuInfo.hz',
     cpu_model:   :'summary.hardware.cpuModel',
     cpu_cores:   :'summary.hardware.numCpuCores',
     sockets:     :'summary.hardware.numCpuPkgs',
     threads:     :'summary.hardware.numCpuThreads',
     memory:      :'summary.hardware.memorySize',
     vendor:      :'summary.hardware.vendor',
     model:       :'summary.hardware.model',
     os:          :'config.product.name',
     os_version:  :'config.product.version',
     os_vendor:   :'summary.config.product.vendor',
     inventory: :vm,
     cpus:        :'hardware.cpuPkg',
     host_bus_adapters: :'configManager.storageSystem', # Need moref of storageSystem for mapping host_bus_adapters
     nics: :'configManager.networkSystem'} # Need moref of networkSystem for mapping nics

    # Note: these were in the old host_properties before moving over here ... May not need anymore?
    # 'datastore', 'config.network', # Don't need until figure out NICs
  end

  # Properties used by Infrastructure Collector host_filter_spec
  def self.vsphere_query_properties
    @props ||= begin
      props = attribute_map.values
                 props.delete(:platform_id) # platform_id is used internally, not vsphere property like others
                 props
               end
  end

  def api_format
    {
      uuid: uuid,
      # tags: tags, # Currently not supported,
      cluster: cluster,
      cpu_speed_hz: cpu_hz,
      cpu_model: cpu_model,
      cores: cpu_cores,
      sockets: sockets,
      threads: threads,
      memory_bytes: memory,
      vendor: vendor,
      model: model,
      os: os,
      os_version: os_version,
      # Note: Unlike some nested objects, cpus, host_bus_adapters, and nics are
      # Arrays of hashes (to avoid nesting more than 1 level) -- may want to consider refactor
      # Didn't want to deal with deep nesting for as_document
      cpus: define_cpus,
      host_bus_adapters: host_bus_adapters,
      nics: nics
    }
  end

  def define_cpus
    cpus.map { |e| e[:cores] = cpu_cores }
    cpus
  end
end
