require 'mongoid'

class Reading
  include Mongoid::Document
  include Mongoid::Timestamps

  field :start_time, type: DateTime
  field :end_time, type: DateTime # Expires field
  field :infrastructure_platform_id, type: String
  field :machine_platform_id, type: String
  field :machine_custom_id, type: String
  field :record_status, type: String, default: 'created'
  field :submitted_at, type: DateTime

  field :machine_metrics, type: Hash
  field :disk_metrics, type: Array
  field :nic_metrics, type: Array

  index({ record_status: 1 })

  # Don't want to expire based on submitted, since if problem with OnPremConnector
  # The meter-database can exceed storage limits and crash all services
  index({end_time: 1}, {expire_after_seconds: 30.hours})

  scope :to_be_created, -> { where(record_status: 'created') }

  def self.build_from_result(result, machine, reading_timestamps)

    reading = Reading.new
    machine_metrics = Hash.new

    reading.machine_platform_id = machine.platform_id
    reading.machine_custom_id = machine.custom_id
    reading.end_time = result[:sampleInfo].first.timestamp  if ( result[:sampleInfo] and result[:sampleInfo].first )
    reading.start_time = reading_timestamps[:start_time]

    result[:metrics].select{|k,v| machine_properties.include?(k[0])}.each{|k,v|
      machine_metrics[k[0]] = v.first }

    disk_metrics = Hash.new{|h,k|h[k] = Hash.new}
    result[:metrics].reject{|k,v|k[1].empty?}.select{|k,v| disk_properties.include?(k[0])}.each{|k,v|
      type,number = k[1].split(':')
      disk_metrics[k[0]][ number.to_i + (type.match(/scsi/) ? 2000 : 3000)  ] = v.first } # 2000 == SCSI, 3000 == IDE

    nic_metrics = Hash.new{|h,k|h[k]={}}
    result[:metrics].reject{|k,v| k[1].to_i.eql?(0) }.select{|k,v| nic_properties.include?(k[0])}.each{|k,v|
      nic_metrics[k[0]][k[1]] = v.first }

    memory_bytes = machine_metrics['mem.consumed.average'] ? machine_metrics['mem.consumed.average'] * 1024 : 0   # Metric is returned in KB, need to submit in bytes
    cpu_percent  = machine_metrics['cpu.usage.average'] ? (machine_metrics['cpu.usage.average'] / 100.0).round : 0
    reading.machine_metrics = { cpu_usage_percent: cpu_percent,
                                memory_bytes: memory_bytes }

    machine.disks.each do |disk|
      reading.disk_metrics ||= Array.new
      reading.disk_metrics << { custom_id:       disk.custom_id,
                                read_kilobytes:  disk_metrics['virtualDisk.read.average'][disk.key]  || 0,
                                write_kilobytes: disk_metrics['virtualDisk.write.average'][disk.key] || 0,
                                usage_bytes:     disk.metrics['usage_bytes'] || 0 }
    end


    machine.nics.each{|nic|
      reading.nic_metrics ||= Array.new

      # Multipy by 8 to convert bytes to bits
      receive_kilobits = nic_metrics.fetch('net.received.average', {}).fetch(nic.platform_id, 0) * 8
      transmit_kilobits = nic_metrics.fetch('net.transmitted.average', {}).fetch(nic.platform_id, 0) * 8

      reading.nic_metrics << { custom_id:         nic.custom_id,
                               receive_kilobits:  receive_kilobits,
                               transmit_kilobits: transmit_kilobits }
     }

    reading
  end

  # Aggregate readings by machine, so that multiple readings can be submitted at once (per machine)
  #  The results of the aggregation can be accessed by the MachineReading model
  # def self.group_for_submission
  #   Reading.collection.aggregate([ { '$match': { record_status: 'created'}},
  #                                  { '$group': { '_id': { machine_custom_id: '$machine_custom_id',  },
  #                                                readings: { '$push': '$$CURRENT' } } },
  #                                  { '$out':    'machine_readings' } ],
  #                                { allowDiskUse: true } ).all?  # FIXME I cannot get this aggregation to execute in a meaningful way w/o this undocumneted 'all?'
  # end

  def self.metrics
    [machine_properties, disk_properties, nic_properties].flatten
  end

  def post_to_api(hyper_client)
    status = 'submitted'
    begin
      response = hyper_client.post_samples(machine_custom_id, api_format)
    rescue RestClient::Conflict => e
      status = 'submitted_conflict'
      $logger.warn "#{e.message} returned when posting samples."
      $logger.info JSON.parse(e.response)['message']
      $logger.debug api_format.to_json
      $logger.debug e
    rescue RestClient::BadRequest => e
      # If we get a badrequest returned, might as well mark it submitted and move on, as there's no way it will ever stop being a bad request
      status = 'submitted_bad_request'
      $logger.error "#{e.message} returned when posting samples."
      $logger.error JSON.parse(e.response)['message']
      $logger.error JSON.parse(e.response)['errors']
      $logger.debug api_format.to_json
      $logger.debug e
    end

    self.update_attribute(:record_status, 'submitted')

    (response && response.code == 200)
  end

  private
  def self.machine_properties
    %w(cpu.usage.average mem.consumed.average)
  end

  def self.disk_properties
    %w(virtualDisk.read.average virtualDisk.write.average)
  end

  def self.nic_properties
    %w(net.received.average net.transmitted.average)
  end

  def api_format
    {
      start_time: start_time.iso8601,
      end_time: end_time.iso8601,
      machine: machine_metrics,
      nics: (nic_metrics || []).map{|nm| { id: nm[:custom_id],
                                           receive_bytes_per_second: (nm[:receive_kilobits] * 125),
                                           transmit_bytes_per_second: (nm[:transmit_kilobits] * 125)} }.compact,
      disks: (disk_metrics || []).map{|dm| { id: dm[:custom_id],
                                             usage_bytes: dm[:usage_bytes],
                                             read_bytes_per_second: (dm[:read_kilobytes] * 1000),
                                             write_bytes_per_second: (dm[:write_kilobytes] * 1000)} }.compact
     }
  end

end
