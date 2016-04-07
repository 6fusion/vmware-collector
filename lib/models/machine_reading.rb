# Class to encapsulate API operations for machine readings
require 'hyper_client'
require 'json'

class MachineReading
  include Mongoid::Document
  include Mongoid::Attributes::Dynamic
  include Logging

  def api_format
    disk_metrics = Hash.new{|h,k|h[k]=[]}
    nic_metrics = Hash.new{|h,k|h[k]=[]}
    metrics = Hash.new

    readings.each do |reading|
      reading[:disk_metrics].each{|dm|
        disk_metrics[dm['remote_id']] << dm.slice('reading_at', 'usage_bytes', 'read_kilobytes', 'write_kilobytes').merge(reading_at: reading[:reading_at]) } unless ( reading[:disk_metrics].blank? )
      reading[:nic_metrics].each{|nm|
        nic_metrics[nm['remote_id']] << nm.slice('transmit_kilobits','receive_kilobits').merge(reading_at: reading[:reading_at]) } unless ( reading[:nic_metrics].blank? )
    end

    disks = disk_metrics.map{|k,v| {id: k, readings: v } }
    nics  = nic_metrics.map {|k,v| {id: k, readings: v } }

    machine = readings.map{|reading|
      { reading_at: reading[:reading_at],
        cpu_usage_percent: reading[:machine_metrics]['cpu_usage_percent'],
        memory_bytes: reading[:machine_metrics]['memory_bytes'] } }

    metrics[:readings] = machine unless machine.empty?
    metrics[:nics] = nics unless nics.empty? # better!! way
    metrics[:disks] = disks unless disks.empty?

    metrics
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
      logger.info JSON::parse(e.response)['message']
      logger.debug @metrics
      logger.debug e
    rescue RestClient::BadRequest => e
      status = 'submitted_bad_request'
      logger.error "#{e.message} returned when posting to #{reading_endpoint}."
      logger.error JSON::parse(e.response)['message']
      logger.debug @metrics
      logger.debug e
    end

    # Iterate over the *aggregated* readings, convert them to proper reading docs, and update them as appropriate
    readings.each do |r|
      begin
        reading = Reading.find(r['_id'])
        reading.record_status = status
        reading.submitted_at = Time.now.utc
        reading.save
      rescue Mongoid::Errors::DocumentNotFound => e
        logger.warn "Unable to update reading submited_at timestamp for machine #{r[:machine_platform_id]}@#{r[:infrastructure_platform_id]} for time #{r[:reading_at]}"
        logger.warn e.message
      end
    end

    ( response and response.code == 200 )
  end

  private
  def hyper_client
    @hyper_client ||= HyperClient.new
  end

end
