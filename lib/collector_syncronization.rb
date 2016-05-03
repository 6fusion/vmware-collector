require 'uri'
require 'securerandom'

require 'global_configuration'
require 'logging'
require 'vsphere_session'
require 'metrics_collector'
require 'infrastructure_collector'
require 'inventory_collector'
require 'uc6_connector'
require 'interval_time'

class CollectorSyncronization
  using IntervalTime
  include GlobalConfiguration
  include Logging
  include VSphere

  def initialize
    @environment = ENV['METER_ENV'] || 'development'
    @configuration = GlobalConfiguration::GlobalConfig.instance
  end

  def sync_data
    start_sync if access_granted?
  end

  private

  def access_granted?
    @configuration[:verified_api_connection] && @configuration[:verified_vsphere_connection]
  end

  def start_sync
    begin
      logger.debug "On Start Sync"
      @uc6_connector = UC6Connector.new
      logger.debug "UC6 connector #{@uc6_connector.inspect}"
      collect_infrastructures
      submit_infrastructures
      collect_machine_inventory
      sync_remote_ids
    rescue StandardError => e
      logger.error e
      logger.error e.backtrace.join("\n")
      if ( e.is_a?(RestClient::Exception) )
        logger.error e.to_s
        logger.error e.http_body
      end
    end
  end

  def collect_infrastructures
    logger.debug "On collect insfrastructures"
    infrastructures = Infrastructure.all
    InfrastructureCollector.new.run
    if Infrastructure.empty?
      logger.debug "No infrastructures discovered"
    else
      logger.debug "#{infrastructures.count} infrastructure#{'s' if infrastructures.count > 1} discovered"
    end
  end

  def submit_infrastructures
    logger.info "On submit infrastructures"
    @uc6_connector.submit_infrastructure_creates
    if ( @configuration.blank_value?(:uc6_meter_id) )
      any_enabled_infrastructure = Infrastructure.first
      if any_enabled_infrastructure
        meters_endpoint = "#{@configuration[:uc6_api_endpoint]}/organizations/"\
          "#{@configuration[:uc6_organization_id]}/infrastructures/"\
          "#{any_enabled_infrastructure.remote_id}/vmware_meters.json"
        infrastructure_endpoint = "#{@configuration[:uc6_api_endpoint]}/organizations/"\
          "#{@configuration[:uc6_organization_id]}/infrastructures/"\
          "#{any_enabled_infrastructure.remote_id}"
        @configuration[:uc6_meter_id] = (retrieve_meter(any_enabled_infrastructure.name, meters_endpoint) || submit_meter(any_enabled_infrastructure.name, infrastructure_endpoint))["remote_id"]
        any_enabled_infrastructure.update_attribute(:meter_id, @configuration[:uc6_meter_id])
      end
    end
    # We rely on the passwords having been added to the global config, *unencrypted*, in the previous registration steps
    #  So we save them before moving into the code to set up encryption
    proxy   = @configuration[:uc6_proxy_password]
    vsphere = @configuration[:vsphere_password]
    hyper_client = HyperClient.new
    url = "#{@configuration[:uc6_api_endpoint]}/organizations/"\
        "#{@configuration[:uc6_organization_id]}/infrastructures/"\
        "#{@configuration[:uc6_infrastructure_id]}/vmware_meters/#{@configuration[:uc6_meter_id]}"

    response = hyper_client.get(url)

    if ( response.code == 200 )
      @configuration[:uc6_proxy_password] = proxy
      @configuration[:vsphere_password] = vsphere
    else
      logger.error "Something other than a 200 returned at #{__LINE__}: #{response.code}"
      logger.debug response.body
    end
    logger.info "Submitted infrastructures"
  end

  def collect_machine_inventory
    time_to_query = Time.now.truncated
    inventoried_timestamp = InventoriedTimestamp.find_or_create_by(inventory_at: time_to_query)
    logger.debug "COLLECT MACHINE INVENTORY \n\n #{Infrastructure.enabled}\n\n\n"
    Infrastructure.enabled.each do |infrastructure|
      logger.info "Collecting inventory for #{infrastructure.name}"
      begin
        collector = InventoryCollector.new(infrastructure)
        collector.run(time_to_query)
      rescue StandardError => e
        logger.error e.message
        logger.debug e.backtrace.join("\n")
        infrastructure.disable
      end
    end
    machine_count = Machine.distinct(:platform_id).count
    if ( machine_count == 0 )
      raise 'No virtual machine inventory discovered'
    end
    inventoried_timestamp.delete  # Leaving this behind creates "gaps" between this inventory time and when the user clicks "start metering"
    logger.info "#{machine_count} virtual machine#{'s' if machine_count > 1} discovered"
  end

  def sync_remote_ids
    logger.info "On sync remote ids"
    @uc6_connector.initialize_platform_ids{|msg| logger.info  msg }
    logger.info "Local inventory synced with UC6"
  end

  #VERIFY IF THIS IS THE RIGHT PLACE TO PUT THIS 2 METHODS
  def retrieve_meter(infrastructure_name, infrastructure_meters_endpoint)
    logger.info "Querying for existing VMware meters for infrastructure '#{infrastructure_name}'"
    hyper_client = HyperClient.new
    meters_as_json = hyper_client.get_all_resources("#{infrastructure_meters_endpoint}")
    meter_json = meters_as_json.find{|json| json['name'].eql?("#{infrastructure_name} meter")}
  end

  def submit_meter(infrastructure_name, infrastructure_endpoint)
    configuration = GlobalConfiguration::GlobalConfig.instance

    logger.info "Creating new meter for infrastructure: #{infrastructure_name}"
    hyper_client = HyperClient.new
    #!! make sure one doesn't already exist?
    response = hyper_client.post("#{infrastructure_endpoint}/vmware_meters",
                                { name: "#{infrastructure_name} meter",
                                enabled: 'true',
                                release_version:   @configuration[:uc6_meter_version],
                                last_processed_on: (Time.now.utc + 1000).strftime("%Y-%m-%dT%H:%M:%SZ"),
                                vcenter_server:    @configuration[:vsphere_host],
                                username: '*******',
                                password: '*******' } )

    ( response.code == 200 ) ? response.json : nil
  end
end