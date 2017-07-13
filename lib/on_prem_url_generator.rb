module OnPremUrlGenerator


  def api_endpoint
    @api_endpoint ||= "#{ENV['METER_API_PROTOCOL'] || 'https'}://#{ENV['ON_PREM_API_HOST']}:#{ENV['ON_PREM_API_PORT']}/api/v1"
  end

  # ---------------------------------------------- #
  def organizations_url
    "#{api_endpoint}/organizations/#{ENV['ORGANIZATION_ID']}"
  end

  # ---------------------------------------------- #
  def infrastructures_url
    "#{api_endpoint}/infrastructures"
  end

  def infrastructures_post_url
    "#{organizations_url}/infrastructures"
  end

  def infrastructure_url(infrastructure_id:)
    "#{infrastructures_url}/#{infrastructure_id}"
  end

  # ---------------------------------------------- #
  def machines_url
    "#{api_endpoint}/machines"
  end

  def machines_post_url(infrastructure_id:)
    "#{infrastructures_url}/#{infrastructure_id}/machines"
  end

  def infrastructure_machines_url(infrastructure_id:)
    "#{machines_base_url}?infrastructure_id=#{infrastructure_id}"
  end

  def retrieve_machine(machine_remote_id)
    "#{machines_url}/#{machine_remote_id}"
  end

  def infrastructure_machine_readings_url(machine_id)
    "#{api_endpoint}/machines/#{machine_id}/samples"
  end

  def machine_url(machine)
    retrieve_machine(machine.custom_id)
  end

  # ---------------------------------------------- #
  def disk_url(disk)
    "#{api_endpoint}/disks/#{disk.custom_id}"
  end

  # ---------------------------------------------- #
  def nic_url(nic)
    "#{api_endpoint}/nics/#{nic.custom_id}"
  end

  # def machine_nics_url(machine_remote_id)
  #   "#{api_endpoint}/machines/#{machine_remote_id}/nics"
  # end

  # def machine_disks_url(machine_remote_id)
  #   "#{api_endpoint}/machines/#{machine_remote_id}/disks"
  # end

  def nic_url_for(nic_id)
    "#{api_endpoint}/nics/#{nic_id}"
  end

  def disk_url_for(disk_id)
    "#{api_endpoint}/disks/#{disk_id}"
  end
end
