# Adding a couple methods to ObjectUpdate class to simplify parsing elsewhere
require 'ipaddr'
require 'rbvmomi'
require 'logging'
require 'volume'

module RbVmomiExtensions

  # Expose the moref for various object types
  [RbVmomi::VIM::ManagedEntity,
   RbVmomi::VIM::ExtensibleManagedObject].each do |class_type|
    refine class_type do
      def moref; instance_variable_get('@ref'); end
    end
  end

  # Same as above, but for obj
  [RbVmomi::VIM::ObjectUpdate,
   RbVmomi::VIM::ObjectContent].each do |class_type|
    refine class_type do
      def moref; obj.instance_variable_get('@ref'); end
    end
  end


  # RbVmomi has issue where it makes additional requests if call methods on any objects in response
  # Need to get the attributes from the changeSet for each ObjectSet returned
  # Responsibility of this class is to extract properties and reduce the number of network requests (significantly impacts performance)
  refine RbVmomi::VIM::ObjectUpdate do
    def machine_properties
      logger = Logging::MeterLog.instance.logger
      updated_attributes = Hash.new
      updated_attributes[:platform_id] = moref
      updated_attributes[:disks] = Array.new
      updated_attributes[:nics] = Hash.new{|h,k|h[k] = Hash.new}

      if ( self.kind.eql?('leave') )
        logger.debug "Detected 'leave' event for #{moref}; marking as deleted"
        updated_attributes[:'summary.runtime.powerState'] = 'deleted'
      end

      self.changeSet.each do |cs|
        begin
          if ( cs.name =~ /config.hardware.device/ )
            if ( cs.val )
              cs.val.grep(RbVmomi::VIM::VirtualDisk).each do |disk|
                # RDMs do not expose a UUID; instead they have a lunUuid
                disk_uuid = disk.backing.uuid || ( disk.backing.respond_to?(:lunUuid) and disk.backing.lunUuid )

                updated_attributes[:disks] << { name: disk.deviceInfo.label,
                                                platform_id: disk_uuid,
                                                key: disk.key,
                                                size: disk.capacityInKB } if ( disk_uuid )

              end

              cs.val.grep(RbVmomi::VIM::VirtualEthernetCard).each {|nic|
                next unless nic.key
                updated_attributes[:nics][nic.key][:name] = nic.deviceInfo.label
                updated_attributes[:nics][nic.key][:platform_id] = nic.key
                updated_attributes[:nics][nic.key][:mac_address] = nic.macAddress
                updated_attributes[:nics][nic.key][:kind] = 'lan' }
            else
              logger.debug "No value returned by vSphere for cs.name: #{cs.name}; cs.val: #{cs.val}"
            end
          elsif ( cs.name =~ /guest.net/ )
            cs.val.each do |nic_info|
              if ( nic_info.ipConfig )
                ipv4s = nic_info.ipConfig.ipAddress.select{|addy| addy.prefixLength<=32 and
                                                                  addy.ipAddress.match(IPAddr::RE_IPV4ADDRLIKE) } # pull out IPV4 addresses
                updated_attributes[:nics][nic_info.deviceConfigId][:ip_address] = ipv4s.first.ipAddress unless ipv4s.empty?
              end
            end
          elsif ( cs.name =~ /^layoutEx.disk$/ )
            cs.val.each do |file_layout_ex_disk_layout|
              updated_attributes[:disk_map] ||= Hash.new{|h,k| h[k] = Hash.new}
              if (chain = file_layout_ex_disk_layout.chain)
                if (chain.first and chain.first.fileKey)
                  disk_key = file_layout_ex_disk_layout.key
                  chain.first.fileKey.each{|file_key| updated_attributes[:disk_map][file_key][:disk] = disk_key }
                else
                  logger.debug "Unable to determine disk configuration for #{moref}"
                  logger.debug cs.inspect
                end
              end
            end
          elsif ( cs.name =~ /^layoutEx.file$/ )
            updated_attributes[:disk_map] ||= Hash.new{|h,k| h[k] = Hash.new}

            cs.val.each {|file_layout_ex_file_info|
              file_key = file_layout_ex_file_info.key
              updated_attributes[:disk_map][file_key][:size] = file_layout_ex_file_info.size }
          elsif ( cs.name =~ /memorySizeMB/ )
            updated_attributes[cs.name.to_sym] = cs.val ? (cs.val * 1024**2) : 0
          else
            # !! Todo: Why on updates, this doesn't pick up attrs like name? If can fix this, will avoid record_status "incomplete" when not actually incomplete
            updated_attributes[cs.name.to_sym] = cs.val
          end
        rescue StandardError => e
          logger.warn e.message
          logger.debug e.backtrace.join("\n")
        end
      end

      # Delete any extraneous NICs that may have gotten created (e.g., virutal NICs for containers)
      updated_attributes[:nics].delete_if{|platform_id, nic_info| nic_info[:name].blank? }
      updated_attributes
    end

    def host_properties
      attributes = Hash.new
      mappings = Host.attribute_map.invert

      self.changeSet.each do |cs|
        key = cs.name.to_sym
        next unless (mappings.has_key?(key) || cs.name == 'parent')
        begin
          if ( cs.name == 'vm' )
            attributes[mappings[key]] = cs.val.map{|vm| vm.moref}
          elsif ( cs.name == 'parent' )
            attributes[:cluster] = cs.val.moref # temporarily store moref for mapping
          elsif (cs.name == 'hardware.cpuPkg')
            cpus = []
            host_cpus_results = cs.val
            host_cpus_results.each do |host_cpu_result|
              cpu = Hash.new
              cpu[:vendor] = host_cpu_result.try(:vendor)
              cpu[:model] = host_cpu_result.try(:description)
              cpu[:speed_hz] = host_cpu_result.try(:hz)
              cpus << cpu
            end
            attributes[:cpus] = cpus
          elsif (cs.name == 'configManager.storageSystem')
            attributes[:host_bus_adapters] = cs.val.moref # temporarily store moref for mapping
          elsif (cs.name == 'configManager.networkSystem')
            attributes[:nics] = cs.val.moref
          else
            attributes[mappings[key]] = cs.val
          end
        rescue StandardError => e
          logger = Logging::MeterLog.instance.logger
          logger.warn e.message
          logger.debug e.backtrace.join("\n")
        end
      end
      attributes[:platform_id] = self.moref
      attributes
    end

    def cluster_properties
      # Note: Move this into model (see Host, Machine for examples) if need more attrs for Cluster
      cluster_attribute_map = { name: :name }

      mappings = cluster_attribute_map.invert
      attributes = Hash.new

      self.changeSet.each do |cs|
        key = cs.name.to_sym
        next unless mappings.has_key?(key)
        begin
          attributes[mappings[key]] = cs.val
        rescue StandardError => e
          logger = Logging::MeterLog.instance.logger
          logger.warn e.message
          logger.debug e.backtrace.join("\n")
        end
      end
      attributes[:platform_id] = self.moref
      attributes
    end

    def host_bus_adapters
      # Move into model if more attrs needed
      host_bus_adapter_attribute_map = { name:   :key,
                                         model: :model,
                                         speed_mbits: :speed_mbits }

      host_bus_adapters = []

      self.changeSet.each do |cs|
        cs.val.each do |hba|
          hba_attrs = {}
          host_bus_adapter_attribute_map.each do |k,v|
            begin
              if ( k == :speed_mbits )
                hba_attrs[:speed_mbits] = case
                                            when hba.respond_to?(:maxSpeedMb) then hba.maxSpeedMb         # RbVmomi::VIM::HostInternetScsiHba has 'maxSpeedMb' (megabits/second)
                                            when hba.respond_to?(:speed)      then hba.speed / 1_000_000  # RbVmomi::VIM::HostFibreChannelHba has 'speed' (bits/second)
                                            else 0
                                          end
              else
                hba_attrs[k] = hba.send(v)
              end
            rescue StandardError => e
              logger = Logging::MeterLog.instance.logger
              logger.warn e.message
              logger.debug e.backtrace.join("\n")
            end
          end

          host_bus_adapters << hba_attrs
        end
      end

      host_bus_adapters
    end

    def nics
      # Move into model if more attrs needed
      nic_attribute_map = { name:         :key,
                            speed_mbits: :'linkSpeed.speedMb' }
      nics = []
      logger = nil

      self.changeSet.each do |cs|
        cs.val.each do |nic|
          nic_attrs = {}
          nic_attribute_map.each do |k,v|
            begin
              if ( k == :speed_mbits )
                nic_attrs[k] = nic.linkSpeed ? nic.linkSpeed.speedMb : 0  # linkSpeed is actually a PhysicalNicLinkInfo object, and will be nil if the link is down
              else
                nic_attrs[k] = nic.send(v)
              end
            rescue StandardError => e
              logger ||= Logging::MeterLog.instance.logger
              logger.warn e.message
              logger.debug e.backtrace.join("\n")
            end
          end
          nics << nic_attrs
        end
      end
      nics
    end
  end

  refine RbVmomi::VIM::ObjectContent do
    def data_center_properties
      attributes = Hash.new
      logger = nil

      propSet.each do |cs|
        begin
          if ( cs.name =~ /^name|hostFolder$/ )
            attributes[cs.name.to_sym] = cs.val
          elsif ( cs.name == 'network' )
            #!! We need to write a global method that uses RetrievePropertiesEx + objects to give us all of items like this in
            #  one shot. Could be good for retrieving hosts for DC as well I'd think
            #  the below code will result in N requests where N=number of networks
            attributes[cs.name.to_sym] = cs.val.map{|network| network.name}
          elsif (cs.name == 'datastore')
            attributes[:datastores] = cs.val.map{|datastore| datastore.moref}
          end
        rescue StandardError => e
          logger ||= Logging::MeterLog.instance.logger
          logger.warn e.message
          logger.debug e.backtrace.join("\n")
        end
      end
      attributes[:platform_id] = self.moref
      attributes
    end

    def volume_properties
      attributes = Hash.new
      logger = nil

      propSet.each do |property|
        begin
          if ( property.name.eql?('summary') )
            attributes[:accessible] = property.val.accessible
            attributes[:storage_bytes] = property.val.capacity
            attributes[:free_space] = property.val.freeSpace
            attributes[:volume_type] = property.val.type
            attributes[:name] = property.val.name
          elsif ( property.name.eql?('info') and property.val.is_a?(RbVmomi::VIM::VmfsDatastoreInfo) )
            attributes[:ssd] = property.val.vmfs.ssd
          end
        rescue StandardError => e
          logger ||= Logging::MeterLog.instance.logger
          logger.warn e.message
          logger.debug e.backtrace.join("\n")
        end
      end

      attributes
    end

  end
end
