require 'global_configuration'
require 'logging'
require 'local_inventory'
require 'vsphere_session'
require 'rbvmomi_extensions'
require 'infrastructure'
class InfrastructureCollector
  include GlobalConfiguration
  include Logging
  using RbVmomiExtensions

  MEGABIT_TO_BIT = 1_000_000
  BASIC_INFRASTRUCTURE_FIELDS = [:name, :platform_id]
  BASIC_HOST_FIELDS = [:platform_id, :uuid, :name, :cluster, :cluster_platform_id, :cpu_hz, :cpu_model,
    :cpu_cores, :sockets, :threads, :cpus, :memory, :vendor, :model, :os,
    :os_version, :os_vendor, :inventory]
  def initialize
    logger.info 'Initializing infrastructure collector'
    @local_inventory = InfrastructureInventory.new

    VSphere.wrapped_vsphere_request do
      VSphere.session.propertyCollector.CreateFilter(spec: hosts_filter_spec(VSphere.root_folder, Host.vsphere_query_properties),
                                                     partialUpdates: false)
    end
    @infrastructure_volumes = {}
    @hosts = {}
    @clusters = {} # Map ClusterComputeResource.moref => cluster_properties
    @host_bus_adapters = {} # Map HostStorageSystem.moref => array host_bus_adapters
    @nics = {} # Map HostNetworkSystem.moref => array nics
    @version = ''
  end

  def run
    logger.info 'Checking for updates to infrastructure'
    update = false
    begin
      results = VSphere.wrapped_vsphere_request do
        VSphere.session.propertyCollector.WaitForUpdatesEx(version: @version,
                                                           options: {maxWaitSeconds: 0})
      end
      while results
        update = true
        # Collect attributes in hashes before building host objects and mapping (cluster name, host_bus_adapters)
        results.filterSet.each do |fs|
          object_set = fs.objectSet
          object_set.select { |os| os.obj.is_a?(RbVmomi::VIM::HostSystem) }.each do |os|
            # !! hosts deleted?
            # @hosts[os.moref] = Host.new(os.host_properties) # Note: this host_properties is added from RbVmomiExtensions
            @hosts[os.moref] = os.host_properties
          end # Store Host level attributes in a hash

          # Collect cluster names, needed as host property
          object_set.select { |os| os.obj.is_a?(RbVmomi::VIM::ClusterComputeResource) }.each do |os|
            @clusters[os.moref] = os.cluster_properties
          end

          object_set.select { |os| os.obj.is_a?(RbVmomi::VIM::HostStorageSystem) }.each do |os|
            @host_bus_adapters[os.moref] = os.host_bus_adapters
          end
          object_set.select { |os| os.obj.is_a?(RbVmomi::VIM::HostNetworkSystem) }.each do |os|
            @nics[os.moref] = os.nics
          end
        end
        @version = results.version

        results = VSphere.wrapped_vsphere_request do
          VSphere.session.propertyCollector.WaitForUpdatesEx(version: @version,
                                                             options: {maxWaitSeconds: 0})
        end
      end
    rescue RbVmomi::Fault => e
      if e.fault.is_a?(RbVmomi::VIM::InvalidCollectorVersion)
        @version = ''
        retry
      else
        raise e
      end
    end
    if update
    # Re-set host cluster (moref -> name)
      @host_objects = {}

      @hosts.each do |key, host|
        infrastructure = Infrastructure.where(:"hosts.platform_id" => key).first
        cluster_pid =  infrastructure.present? ? infrastructure.hosts.where(platform_id: key).first.cluster_platform_id : nil
        cluster = @clusters[host[:cluster]] || (@clusters[cluster_pid] if cluster_pid)
        host[:cluster_platform_id] =  (host[:cluster] =~ /domain/).present? ? host[:cluster] : nil
        host[:cluster] = cluster ? cluster[:name] : nil
        host[:host_bus_adapters] = convert_speed_mbits_to_speed_bits_per_second(@host_bus_adapters)[host[:host_bus_adapters]]
        host[:nics] = convert_speed_mbits_to_speed_bits_per_second(@nics)[host[:nics]]
        @host_objects[key] = Host.new(host)
      end
      data_centers_hash.each do |platform_id, properties|
        host_ids = hosts_for_datacenter(properties[:hostFolder])

        properties[:hosts] = @host_objects.select { |k| host_ids.include?(k) }.values
        properties[:networks] = properties[:network].map { |network| Network.new(name: network) } unless properties[:network].blank?
        properties[:volumes] = properties[:datastores].map { |ds_moref| Volume.new(@infrastructure_volumes[ds_moref]) } unless properties[:datastores].blank?
        properties.delete(:hostFolder)
        properties.delete(:network)
        properties.delete(:datastores) # Datastores from vSphere are referred to as 'volumes' in our domain
        @local_inventory[platform_id] = updated_infrastructure(properties)
      end
      @local_inventory.save
    end
    logger.debug 'Generating vSphere session activity with currentTime request'
    VSphere.wrapped_vsphere_request { VSphere.session.serviceInstance.CurrentTime }
  end

  private

  def updated_infrastructure(properties)
    infrastructure = Infrastructure.where(platform_id: properties[:platform_id])
    if infrastructure.present?
      current_infrastructure = infrastructure.first
      update_fields_for(current_infrastructure,properties)
    else
      Infrastructure.new(properties)
    end
  end

  def update_fields_for(current_infrastructure,properties)
    BASIC_INFRASTRUCTURE_FIELDS.each{|field| current_infrastructure[field] = properties[field] }
    current_infrastructure[:networks] = properties[:networks] ? build_updated_networks(properties) : []
    current_infrastructure[:volumes] = properties[:volumes] ? build_updated_volumes(properties) : []
    current_infrastructure.record_status = 'updated'
    current_infrastructure = update_hosts(properties,current_infrastructure)
    current_infrastructure.save
    current_infrastructure
  end

  def update_hosts(properties,current_infrastructure)
    properties[:hosts].each do |h|
      host = current_infrastructure.hosts.where(platform_id: h[:platform_id]).first
      host.present? ? update_host(host,h) : current_infrastructure.hosts << h
    end
    if properties[:hosts].empty?
      current_infrastructure.hosts = []
    else
      current_infrastructure.hosts = current_infrastructure.hosts.map do |h|
        h if properties[:hosts].select{|val| val[:platform_id] == h[:platform_id]}.any?
      end
    end
    current_infrastructure
  end

  def build_updated_networks(properties)
    properties[:networks].map do |n|
      {'_id': n['_id'], 'kind' => n['kind'], 'name'=> n['name']}
    end
  end

  def build_updated_volumes(properties)
    properties[:volumes].map do |v|
      { '_id'=> v['_id'], 'storage_bytes' => v['storage_bytes'],
        'free_space'=> v['free_space'], 'accessible' => v['accessible'],
        'volume_type' => v['volume_type'],'name'=> v['name']
      }
    end
  end

  def update_host(host,new_host)
    host = update_basic_host_fields_for(host,new_host)
    platform_id_number = host[:platform_id].match(/[0-9]+/)
    host[:host_bus_adapters] = @host_bus_adapters["storageSystem-#{platform_id_number[0]}"]
    host[:nics] = @nics["networkSystem-#{platform_id_number[0]}"]
    host.save
  end

  def update_basic_host_fields_for(host,new_host)
    BASIC_HOST_FIELDS.each do |field|
      if field == :cluster_platform_id && @clusters[host[:cluster_platform_id]]
        host[field]= @clusters[host[:cluster_platform_id]][:platform_id]
      elsif !@clusters[host[:cluster_platform_id]] && field == :cluster_platform_id
        if new_host.cluster.present? && new_host.cluster_platform_id.present?
          host[field] = new_host[field]
          host[:cluster] = new_host[:cluster]
        else
          host[field] = nil
          host[:cluster] = nil
        end
      elsif new_host[field].present?
        host[field] = new_host[field]
      end
    end
    host
  end

  def data_centers_hash
    data_centers = {}
    result = VSphere.wrapped_vsphere_request do
      VSphere.session.propertyCollector.RetrievePropertiesEx(specSet: [data_centers_filter_spec],
                                                             partialUpdates: false,
                                                             options: {})
    end
    if result
      loop do
        result_objects = result.objects

        result_objects.select { |ro| ro.obj.is_a?(RbVmomi::VIM::Datastore) }.each do |object_content|
          @infrastructure_volumes[object_content.moref] = object_content.volume_properties
        end

        result_objects.select { |ro| ro.obj.is_a?(RbVmomi::VIM::Datacenter) }.each do |object_content|
          data_centers[object_content.moref] = object_content.data_center_properties
        end

        break unless result.token
        result = VSphere.wrapped_vsphere_request { VSphere.session.propertyCollector.ContinueRetrievePropertiesEx(token: result.token) }
      end
    end

    data_centers
  end

  def hosts_for_datacenter(host_folder)
    host_ids = []
    result = VSphere.wrapped_vsphere_request do
      VSphere.session.propertyCollector.RetrievePropertiesEx(specSet: [hosts_filter_spec(host_folder, [])],
                                                             partialUpdates: false,
                                                             options: {})
    end
    if result
      loop do
        host_ids.push(*(result.objects.map{|obj|obj.moref}))
        break unless result.token
        result = VSphere.wrapped_vsphere_request { VSphere.session.propertyCollector.ContinueRetrievePropertiesEx(token: result.token) }
      end
    end

    host_ids
  end

  def data_centers_filter_spec
    recurse_folders = RbVmomi::VIM.SelectionSpec(name: 'ParentFolder')

    # !! can you have datacenters under datacenters?
    # This code gives objects all the way from root to the VM
    RbVmomi::VIM.PropertyFilterSpec(
        objectSet: [
            obj: VSphere.root_folder,
            selectSet: [
          RbVmomi::VIM.TraversalSpec(
              name: 'tsFolder',
              type: 'Folder',
              path: 'childEntity',
              skip: false,
              selectSet: [
                  RbVmomi::VIM.SelectionSpec(name: 'tsDatacenterHostFolder'),
                  RbVmomi::VIM.SelectionSpec(name: 'tsDatacenterDatastore')
              ]
          ),
          RbVmomi::VIM.TraversalSpec(
              name: 'tsDatacenterHostFolder',
              type: 'Datacenter',
              path: 'hostFolder',
              skip: false,
              selectSet: [
                  RbVmomi::VIM.SelectionSpec(name: 'tsFolder')
            ]
          ),
          RbVmomi::VIM.TraversalSpec(
              name: 'tsDatacenterDatastore',
              type: 'Datacenter',
              path: 'datastore',
              skip: false
          )
        ]
      ],
        propSet: [
        # Need to include datastore to map
            {type: 'Datacenter', pathSet: %w(name hostFolder network datastore)},
            {type: 'Datastore', pathSet: %w(info summary)}
      ]
    )
  end

  def hosts_filter_spec(starting_folder = VSphere.root_folder, properties = [])
    # name:      Arbitrary name for referencing this traversal spec
    # type:      Name of the object containing the property (Managed Object Type)
    # path:      Name of the property to use to select additional objects (Next step from where I currently am)
    # selectSet: Optional set of selections to specify additional objects to filter
    ts_folder_child_entity = RbVmomi::VIM.TraversalSpec(
      name: 'tsFolder', type: 'Folder', path: 'childEntity', skip: false,
      selectSet: [
        RbVmomi::VIM.SelectionSpec(name: 'tsCR'),
        RbVmomi::VIM.SelectionSpec(name: 'tsDatacenterHostFolder'),
        RbVmomi::VIM.SelectionSpec(name: 'tsClusterRP'),
        RbVmomi::VIM.SelectionSpec(name: 'tsClusterHost')
      ]
    )

    ts_data_center_host_folder = RbVmomi::VIM.TraversalSpec(
      name: 'tsDatacenterHostFolder', type: 'Datacenter', path: 'hostFolder', skip: false,
      selectSet: [
        RbVmomi::VIM.SelectionSpec(name: 'tsCR'),
        RbVmomi::VIM.SelectionSpec(name: 'tsFolder'),
        RbVmomi::VIM.SelectionSpec(name: 'tsClusterRP'),
        RbVmomi::VIM.SelectionSpec(name: 'tsClusterHost')
      ]
    )

    ts_compute_resource_host = RbVmomi::VIM.TraversalSpec(
      name: 'tsCR', type: 'ComputeResource', path: 'host', skip: false,
      selectSet: [
        RbVmomi::VIM.SelectionSpec(name: 'tsCR'),
        RbVmomi::VIM.SelectionSpec(name: 'tsFolder'),
        RbVmomi::VIM.SelectionSpec(name: 'tsClusterRP'),
        RbVmomi::VIM.SelectionSpec(name: 'tsClusterHost'),
        RbVmomi::VIM.SelectionSpec(name: 'tsRP'),
        RbVmomi::VIM.SelectionSpec(name: 'tsHostSysStorageSys'),
        RbVmomi::VIM.SelectionSpec(name: 'tsHostSysNetworkSys')
      ]
    )

    ts_cluster_compute_resource_resource_pool = RbVmomi::VIM.TraversalSpec(
      name: 'tsClusterRP', type: 'ClusterComputeResource', path: 'resourcePool', skip: false,
      selectSet: [
        RbVmomi::VIM.SelectionSpec(name: 'tsCR'),
        RbVmomi::VIM.SelectionSpec(name: 'tsRP')
      ]
    )

    ts_cluster_compute_resource_host = RbVmomi::VIM.TraversalSpec(
      name: 'tsClusterHost', type: 'ClusterComputeResource', path: 'host', skip: false,
      selectSet: [
        RbVmomi::VIM.SelectionSpec(name: 'tsCR'),
        RbVmomi::VIM.SelectionSpec(name: 'tsHostSysStorageSys'),
        RbVmomi::VIM.SelectionSpec(name: 'tsHostSysNetworkSys')
      ]
    )

    ts_resource_pool_resource_pool = RbVmomi::VIM.TraversalSpec(
      name: 'tsRP', type: 'ResourcePool', path: 'resourcePool', skip: false,
      selectSet: [
        RbVmomi::VIM.SelectionSpec(name: 'tsCR'),
        RbVmomi::VIM.SelectionSpec(name: 'tsRP')
      ]
    )

    ts_host_system_storage_system = RbVmomi::VIM.TraversalSpec(
      name: 'tsHostSysStorageSys', type: 'HostSystem', path: 'configManager.storageSystem', skip: false
    )

    ts_host_system_network_system = RbVmomi::VIM.TraversalSpec(
      name: 'tsHostSysNetworkSys', type: 'HostSystem', path: 'configManager.networkSystem', skip: false
    )

    RbVmomi::VIM.PropertyFilterSpec(
      objectSet: [
        obj: starting_folder, # All of following start from here
        selectSet: [
          ts_data_center_host_folder,
          ts_folder_child_entity,
          ts_compute_resource_host,
          ts_cluster_compute_resource_resource_pool,
          ts_cluster_compute_resource_host,
          ts_resource_pool_resource_pool,
          ts_host_system_storage_system,
          ts_host_system_network_system
        ]
      ],
      propSet: [
        { type: 'HostSystem', pathSet: properties },
        { type: 'ClusterComputeResource', pathSet: ['name'] },
        { type: 'HostStorageSystem', pathSet: ['storageDeviceInfo.hostBusAdapter'] },
        { type: 'HostNetworkSystem', pathSet: ['networkInfo.pnic'] }
      ]
    )
  end

  def convert_speed_mbits_to_speed_bits_per_second(nics)
    result = {}
    nics.each do |key, value|
      new_value = []
      value.map do |val|
        if val[:speed_mbits]
          val[:speed_bits_per_second] = (val[:speed_mbits] * MEGABIT_TO_BIT)
          val.reject! { |k| k == :speed_mbits }
        end
        new_value << val
      end
      result[key] = new_value
    end
    result
  end
end
