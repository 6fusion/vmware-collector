require 'hyper_client'
require 'matchable'
require 'global_configuration'

class MeterInstance
  include Mongoid::Document
  include Mongoid::Timestamps
  include GlobalConfiguration
  include Matchable

  field :remote_id, type: Integer
  field :enabled, type: Boolean, default: true
  field :name, type: String
  field :status, type: String, default: 'online'
  field :vcenter_server, type: String #!! hmmmm
  field :release_version, type: String, default: 'alpha'

  embedded_in :infrastructure

  def vcenter_server
    configuration[:vsphere_host]
  end

  def self.find_or_create_in_uc6(infrastructure_name:, infrastructure_endpoint:)
    meter_json = retrieve_meter(infrastructure_name, infrastructure_endpoint) || submit_meter(infrastructure_name, infrastructure_endpoint)
    configuration = GlobalConfiguration::GlobalConfig.instance
    meter_json.nil? ?
      nil :
      MeterInstance.new(enabled: meter_json['enabled'],
                        name: meter_json['name'],
                        remote_id: meter_json['remote_id'],
                        release_version: configuration[:uc6_meter_version],
                        status: meter_json['status'])
  end


  def self.retrieve_meter(infrastructure_name, infrastructure_endpoint)
    logger.info "Querying for existing VMware meters for infrastructure '#{infrastructure_name}'"
    hyper_client = HyperClient.new
    meters_as_json = hyper_client.get_all_resources("#{infrastructure_endpoint}/vmware_meters.json")
    meter_json = meters_as_json.find{|json| json['name'].eql?("#{infrastructure_name} meter")}
  end


  def self.submit_meter(infrastructure_name, infrastructure_endpoint)
    configuration = GlobalConfiguration::GlobalConfig.instance

    if ( configuration[:encryption_secret].blank? )
      logger.warn "Refusing to create infrastructure meter in UC6 with blank encryption secret"
      return nil
    end
    logger.info "Creating new meter for infrastructure: #{infrastructure_name}"
    hyper_client = HyperClient.new
    #!! make sure one doesn't already exist?
    response = hyper_client.post("#{infrastructure_endpoint}/vmware_meters",
                                 { name: "#{infrastructure_name} meter",
                                   enabled: 'true',
                                   release_version:   configuration[:uc6_meter_version],
                                   last_processed_on: (Time.now.utc + 1000).strftime("%Y-%m-%dT%H:%M:%SZ"),
                                   vcenter_server:    configuration[:vsphere_host],
                                   username: '*******',
                                   password: configuration[:encryption_secret] } )

    ( response.code == 200 ) ? response.json : nil
  end

  def submit_updated_self
    logger.debug self.inspect
    hyper_client = HyperClient.new

    if ( infrastructure.remote_id.nil? or remote_id.nil? )
      logger.warn "Cannot submit meter configuration update for #{name}. Missing remote_id: infrastructure: #{infrastructure.remote_id}; meter: #{remote_id}"
      return false
    end


    if ( configuration[:encryption_secret].blank? )
      logger.warn "Refusing to update infrastructure #{infrastructure.remote_id} meter in UC6 with blank encryption secret"
      return nil
    end


    meter_endpoint =  <<-URL.gsub(/\s/,'')
      #{configuration[:uc6_api_endpoint]}/organizations/#{configuration[:uc6_organization_id]}
      /infrastructures/#{infrastructure.remote_id}
      /vmware_meters/#{remote_id}
    URL

    #!! make sure one doesn't already exist?
    response = hyper_client.put(meter_endpoint,
                                 { name:              name,
                                   enabled:           enabled,
                                   release_version:   release_version,
                                   last_processed_on: (Time.now.utc + 1000).strftime("%Y-%m-%dT%H:%M:%SZ"),
                                   vcenter_server:    configuration[:vsphere_host],
                                   username:          '*******',
                                   password:          configuration[:encryption_secret] })

    ( response.code == 200 ) ? response.json : nil
  end

end
