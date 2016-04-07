require 'securerandom'

require 'infrastructure_collector'
require 'inventory_collector'
require 'uc6_connector'

class StepError < StandardError
  attr_accessor :step
  def initialize(step, message)
    super(message)
    @step = step
  end
end

class Uc6SyncSocketController < WebsocketRails::BaseController
  using IntervalTime

  def msg(msg)
    send_message :new_message, msg, namespace: 'uc6_sync'
  end

  def start
    GlobalConfiguration::GlobalConfig.instance.refresh
    Thread.new do
      begin
        Rails.logger.debug "UC6 Sync Started"
        @uc6_connector = UC6Connector.new

        collect_infrastructures
        submit_infrastructures
        collect_machine_inventory
        sync_remote_ids

      rescue StepError => e
        abort_sync(e.step, e.message)
        send_message :finished, "Registration stopped", namespace: 'uc6_sync'
      rescue StandardError => e
        logger.error e
        logger.error e.backtrace.join("\n")
        message = e.message
        if ( e.is_a?(RestClient::Exception) )
          logger.error e.to_s
          logger.error e.http_body
          message += "<br>#{e.response.message}" if ( e.response )
        end
        # FIXME move style to view/javascript
        send_message :finished, "<span style='color:red'>Error encountered: #{message}</span>", namespace: 'uc6_sync'
      else
        send_message :finished, "Registration complete!", namespace: 'uc6_sync'
      end
    end
  end

  private
  def abort_sync(from_step, msg=nil)
    msg(step: "step#{from_step}", status: 'abort', response: msg)
    (from_step+1).upto(5) {|step_number|
      msg(step: "step#{step_number}", status: 'skip', response: '') }
  end

  def collect_infrastructures
    msg(step: 'step1', status: 'in_progress')

    Infrastructure.all.each{|inf| inf.enable} # Re-enable anything that may have been disabled from previous registration attemps (i.e., things like permission issues may not be corrected)
    infrastructures = Infrastructure.enabled
    InfrastructureCollector.new.run

    raise StepError.new(1, 'No infrastructures discovered. Skipping UC6 syncronization') if ( Infrastructure.empty? )
    msg(step: 'step1', status: 'success',
        response: "#{infrastructures.count} infrastructure#{'s' if infrastructures.count != 1} discovered")
  end

  def submit_infrastructures
    msg(step: 'step2', status: 'in_progress')

    configuration = GlobalConfiguration::GlobalConfig.instance
    configuration[:encryption_secret] = SecureRandom.urlsafe_base64(30)  if ( configuration[:encryption_secret].blank? )

    @uc6_connector.submit_infrastructure_creates
    meter_config = MeterConfigurationDocument.first


    if ( meter_config.uc6_meter_id.blank? )
      any_enabled_infrastructure = Infrastructure.enabled.first
      if any_enabled_infrastructure
        local_meter_instance = any_enabled_infrastructure.meter_instance
        meter_config.update_attribute(:uc6_meter_id, local_meter_instance.remote_id)
        configuration[:uc6_meter_id] = local_meter_instance.remote_id
      end
    end

    # We rely on the passwords having been added to the global config, *unencrypted*, in the previous registration steps
    #  So we save them before moving into the code to set up encryption
    proxy   =  configuration[:uc6_proxy_password]
    vsphere =  configuration[:vsphere_password]

    hyper_client = HyperClient.new

    url = "#{configuration[:uc6_api_endpoint]}/organizations/"\
          "#{configuration[:uc6_organization_id]}/infrastructures/"\
          "#{configuration[:uc6_infrastructure_id]}/vmware_meters/#{configuration[:uc6_meter_id]}"

    response = hyper_client.get(url)

    if ( response.code == 200 )
      remote_meter_instance = response.json

      configuration[:encryption_secret] = remote_meter_instance['password']
      Mongoid::EncryptedFields.cipher = Gibberish::AES.new(remote_meter_instance['password'])
      meter_config.uc6_proxy_password = proxy
      meter_config.vsphere_password = vsphere
      meter_config.save

      configuration.refresh
    else
      logger.error "Something other than a 200 returned at #{__LINE__}: #{response.code}"
      logger.debug response.body
    end

    msg(step: 'step2', status: 'success', response: 'Submission complete')
  end

  def collect_machine_inventory
    time_to_query = Time.now.truncated
    inventoried_timestamp = InventoriedTimestamp.find_or_create_by(inventory_at: time_to_query)

    Infrastructure.enabled.each do |infrastructure|
      msg(step: 'step3', status: 'in_progress',
          response: "Collecting inventory for #{infrastructure.name}")
      begin
        collector = InventoryCollector.new(infrastructure)
        collector.run(time_to_query)
      rescue StandardError => e
        logger.error e.message
        logger.debug e.backtrace.join("\n")
        msg(step: 'step3', status: 'error',
            error: "#{infrastructure.name} error:<br>&nbsp;&nbsp;#{e.message}")
        infrastructure.disable
      end

    end
    machine_count = Machine.distinct(:platform_id).count
    if ( machine_count == 0 )
      raise StepError.new(3, 'No virtual machine inventory discovered')
    end
    inventoried_timestamp.delete  # Leaving this behind creates "gaps" between this inventory time and when the user clicks "start metering"
    msg(step: 'step3', status: 'success',
        response: "#{machine_count} virtual machine#{'s' if machine_count != 1} discovered")
  end

  def sync_remote_ids
    msg(step: 'step4', status: 'in_progress')

    @uc6_connector.initialize_platform_ids{|msg|
      msg(step: 'step4', response: msg) }

    msg(step: 'step4', status: 'success', response: "Local inventory synced with UC6")
  end

  def create_machines
    msg(step: 'step5', status: 'in_progress')
    @uc6_connector.submit_machine_creates
    msg(step: 'step5', status: 'success', response: 'Inventory submitted')
    send_message(:finished, "", namespace: 'uc6_sync')
  end

end
