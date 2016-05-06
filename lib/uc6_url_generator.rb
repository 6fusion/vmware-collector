module UC6UrlGenerator
  def organization_url
    @organization_url ||= "#{configuration[:uc6_api_endpoint]}/organizations/#{configuration[:uc6_organization_id]}"
  end

  def infrastructures_url
    @infrastructures_url ||= "#{organization_url}/infrastructures"
  end

  def machines_url
    @machines_url ||= "#{organization_url}/machines"
  end

  # !!!! For consistency, make this take the infrastructure object and get the remote_id using prid
  def infrastructure_machines_url(infrastructure_id,organization_id)
    "#{configuration[:uc6_api_endpoint]}/machines.json?infrastructure_id=#{infrastructure_id}&organization_id=#{organization_id}"
  end

  def retrieve_machine(machine_remote_id)
    "#{configuration[:uc6_api_endpoint]}/machines/#{machine_remote_id}.json"
  end

  def machines_creation_url(infrastructure_id)
    "#{configuration[:uc6_api_endpoint]}/infrastructures/#{infrastructure_id}/machines.json"
  end

  def infrastructure_machine_url(infrastructure_id, machine_id)
    "#{infrastructure_machines_url(infrastructure_id, configuration[:uc6_organization_id])}/#{machine_id}"
  end

  def infrastructure_machine_readings_url(infrastructure_id, machine_id)
    "#{infrastructure_machine_url(infrastructure_id,machine_id)}/readings.json"
  end

  def machine_url(machine)
    logger.info "@local_platform_remote_id_inventory => #{@local_platform_remote_id_inventory} \n\n MACHINE #{machine.inspect}"
    infrastructure_prid = @local_platform_remote_id_inventory["i:#{machine.infrastructure_platform_id}"]
    machine_prid = @local_platform_remote_id_inventory["i:#{machine.infrastructure_platform_id}/m:#{machine.platform_id}"]
    raise "Could construct API url for #{machine.platform_id}" unless machine_prid
    raise "No remote_id for machine: #{machine.platform_id}" unless machine_prid.remote_id

    retrieve_machine(machine.remote_id)
  end

  def disk_url(disk)
    raise "No machine for disk #{disk.platform_id}, _id: #{disk.id}" if disk.machine.blank?

    disk_machine = disk.machine
    disk_prid = @local_platform_remote_id_inventory["i:#{disk_machine.infrastructure_platform_id}/m:#{disk_machine.platform_id}/d:#{disk.platform_id}"]
    raise "No disk prid for #{disk.platform_id}, _id: #{disk.id}" if disk_prid.blank?
    raise "No remote id for disk_prid #{disk_prid.platform_key}" if disk_prid.remote_id.blank?

    machine_url(disk_machine) + "/disks/#{disk_prid.remote_id}"
  end

  def nic_url(nic)
    raise "No machine for nic #{nic.platform_id}, _id: #{nic.id}" if nic.machine.blank?

    nic_machine = nic.machine
    nic_prid = @local_platform_remote_id_inventory["i:#{nic_machine.infrastructure_platform_id}/m:#{nic_machine.platform_id}/n:#{nic.platform_id}"]
    raise "No nic prid for #{nic.platform_id}, _id: #{nic.id}" if nic_prid.blank?
    raise "No remote id for nic_prid #{nic_prid.platform_key}" if nic_prid.remote_id.blank?

    machine_url(nic_machine) + "/nics/#{nic_prid.remote_id}"
  end
end
