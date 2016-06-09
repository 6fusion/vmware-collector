module UC6UrlGenerator

  def request_format
    configuration[:uc6_api_format]
  end

  # BASE URLS which will be used just for avoiding code duplication
  def infrastructures_base_url
    "#{configuration[:uc6_api_endpoint]}/infrastructures"
  end

  def organization_base_url
    "#{configuration[:uc6_api_endpoint]}/organizations/#{configuration[:uc6_organization_id]}"
  end

  def machines_base_url
    "#{configuration[:uc6_api_endpoint]}/machines"
  end

  # END BASE URLs methods

  # Real routing methods start here
  def organization_url
    "#{organization_base_url}.#{request_format}"
  end

  def infrastructures_url
    "#{infrastructures_base_url}.#{request_format}"
  end

  def infrastructures_post_url
    "#{organization_base_url}/infrastructures.#{request_format}"
  end

  def infrastructure_url(infrastructure_id:)
    "#{infrastructures_base_url}/#{infrastructure_id}.#{request_format}"
  end

  def machines_post_url(infrastructure_id:)
    "#{infrastructures_base_url}/#{infrastructure_id}/machines.#{request_format}"
  end

  def machines_url
    "#{machines_base_url}.#{request_format}"
  end


  def infrastructure_machines_url(infrastructure_id:)
    "#{machines_base_url}.#{request_format}?infrastructure_id=#{infrastructure_id}&organization_id=#{configuration[:uc6_organization_id]}"
  end

  def infrastructure_machines_base_url(infrastructure_id)
    "#{infrastructures_url}/#{infrastructure_id}/machines"
  end

  def retrieve_machine(machine_remote_id)
    "#{configuration[:uc6_api_endpoint]}/machines/#{machine_remote_id}.#{request_format}"
  end

  def machines_creation_url(infrastructure_id)
    "#{configuration[:uc6_api_endpoint]}/infrastructures/#{infrastructure_id}/machines.#{request_format}"
  end

  def infrastructure_machine_url(infrastructure_id, machine_id)
    "#{infrastructure_machines_url(infrastructure_id: infrastructure_id)}/#{machine_id}"
  end

  def infrastructure_machine_readings_url(machine_id)
    "#{configuration[:uc6_api_endpoint]}/machines/#{machine_id}/samples.#{request_format}"
  end

  def machine_url(machine)
    logger.info "@local_platform_remote_id_inventory => #{@local_platform_remote_id_inventory} \n\n MACHINE #{machine.inspect}"
    infrastructure_prid = @local_platform_remote_id_inventory["i:#{machine.infrastructure_platform_id}"]
    machine_prid = @local_platform_remote_id_inventory["i:#{machine.infrastructure_platform_id}/m:#{machine.platform_id}"]
    raise "Could construct API url for #{machine.platform_id}" unless machine_prid
    raise "No remote_id for machine: #{machine.platform_id}" unless machine_prid.remote_id
    remote_id = machine.remote_id.nil? ? machine_prid.remote_id : machine.remote_id
    retrieve_machine(remote_id)
  end

  def disk_url(disk)
    raise "No machine for disk #{disk.platform_id}, _id: #{disk.id}" if disk.machine.blank?
    
    disk_machine = disk.machine
    disk_prid = @local_platform_remote_id_inventory["i:#{disk_machine.infrastructure_platform_id}/m:#{disk_machine.platform_id}/d:#{disk.platform_id}"]
    raise "No disk prid for #{disk.platform_id}, _id: #{disk.id}" if disk_prid.blank?
    raise "No remote id for disk_prid #{disk_prid.platform_key}" if disk_prid.remote_id.blank?

    remote_id = disk.remote_id.nil? ? disk_prid.remote_id : disk.remote_id
    "#{configuration[:uc6_api_endpoint]}/disks/#{remote_id}.#{request_format}"
  end

  def nic_url(nic)
    raise "No machine for nic #{nic.platform_id}, _id: #{nic.id}" if nic.machine.blank?

    nic_machine = nic.machine
    nic_prid = @local_platform_remote_id_inventory["i:#{nic_machine.infrastructure_platform_id}/m:#{nic_machine.platform_id}/n:#{nic.platform_id}"]
    raise "No nic prid for #{nic.platform_id}, _id: #{nic.id}" if nic_prid.blank?
    raise "No remote id for nic_prid #{nic_prid.platform_key}" if nic_prid.remote_id.blank?
    remote_id = nic.remote_id.nil? ? nic_prid.remote_id : nic.remote_id
    "#{configuration[:uc6_api_endpoint]}/nics/#{remote_id}.#{request_format}"
  end

  def machine_nics_url(machine_remote_id)
    "#{configuration[:uc6_api_endpoint]}/machines/#{machine_remote_id}/nics.#{request_format}"
  end

  def machine_disks_url(machine_remote_id)
    "#{configuration[:uc6_api_endpoint]}/machines/#{machine_remote_id}/disks.#{request_format}"
  end

  def nic_url_for(nic_id)
     "#{configuration[:uc6_api_endpoint]}/nics/#{nic_id}.#{request_format}"
  end

  def disk_url_for(disk_id)
    "#{configuration[:uc6_api_endpoint]}/disks/#{disk_id}.#{request_format}"
  end
end
