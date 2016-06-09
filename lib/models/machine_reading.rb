# Class to encapsulate API operations for machine readings
require 'hyper_client'
require 'json'
require 'local_inventory'
class MachineReading
  include Mongoid::Document
  include Mongoid::Attributes::Dynamic
  include Logging

  def api_format
    local_platform_remote_id_inventory = PlatformRemoteIdInventory.new
    infrastructure_prid = local_platform_remote_id_inventory["i:#{id[:infrastructure_platform_id]}"]
    machine_prid = local_platform_remote_id_inventory["#{infrastructure_prid.platform_key}/m:#{id[:machine_platform_id]}"]
    samples = []
    readings.each do |reading|
      disks_info = []
      nics_info = []
      if reading[:disk_metrics].present?
        disks_info = reading[:disk_metrics].map do |dm|
          next unless local_platform_remote_id_inventory["#{machine_prid.platform_key}/d:#{dm['platform_id']}"]
          {id: local_platform_remote_id_inventory["#{machine_prid.platform_key}/d:#{dm['platform_id']}"].remote_id,
           usage_bytes: dm[:usage_bytes],
           read_bytes_per_second: (dm[:read_kilobytes] * 1000),
           write_bytes_per_second: (dm[:write_kilobytes] * 1000)}
        end.compact
      end
      if reading[:nic_metrics].present?
        nics_info = reading[:nic_metrics].map do |nm|
          next unless local_platform_remote_id_inventory["#{machine_prid.platform_key}/n:#{nm['platform_id']}"]
          {id: local_platform_remote_id_inventory["#{machine_prid.platform_key}/n:#{nm['platform_id']}"].remote_id,
           receive_bytes_per_second: (nm[:receive_kilobits] * 125),
           transmit_bytes_per_second: (nm[:transmit_kilobits] * 125)}
        end.compact
      end
      samples = {start_time: reading[:start_time].iso8601,
                 end_time: reading[:end_time].iso8601,
                 machine: reading[:machine_metrics],
                 nics: nics_info,
                 disks: disks_info}
    end
    samples
  end

  def post_to_api(reading_endpoint)
    status = 'submitted'
    begin
      response = hyper_client.post(reading_endpoint, api_format)
    rescue RestClient::UnprocessableEntity, RestClient::Conflict => e
      # 422 UnprocessableEntity is currently returned if a reading already exists, in UC6, for a given timestamp
      # If we get a badrequest returned, might as well mark it submitted and move on, as there's no way it will ever stop being a bad request
      status = 'submitted_conflict'
      logger.warn "#{e.message} returned when posting to #{reading_endpoint}."
      logger.info JSON.parse(e.response)['message']
      logger.debug @metrics
      logger.debug e
    rescue RestClient::BadRequest => e
      status = 'submitted_bad_request'
      logger.error "#{e.message} returned when posting to #{reading_endpoint}."
      logger.error JSON.parse(e.response)['message']
      logger.debug @metrics
      logger.debug e
    end

    # Iterate over the *aggregated* readings, convert them to proper reading docs, and update them as appropriate
    update_readings_status(status)

    (response && response.code == 200)
  end

  def update_readings_status(status)
    readings.each do |r|
      begin
        reading = Reading.find(r['_id'])
        reading.record_status = status
        reading.submitted_at = Time.now.utc
        reading.save
      rescue Mongoid::Errors::DocumentNotFound => e
        logger.warn "Unable to update reading submited_at timestamp for machine #{r[:machine_platform_id]}@#{r[:infrastructure_platform_id]} for time #{r[:end_time]}"
        logger.warn e.message
      end
    end
  end

  private

  def hyper_client
    @hyper_client ||= HyperClient.new
  end
end
