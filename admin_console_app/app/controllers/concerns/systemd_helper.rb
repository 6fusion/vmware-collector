module SystemdHelper
  include DockerHelper

  SERVICE_LABEL_MAP = DockerHelper::CONTAINER_NAME_MAP.invert
  SERVICE_LABELS = Set.new( SERVICE_LABEL_MAP.keys )

  #!! invert these methods bodies
  def enable_meter_service(service)
    enable_meter_services([service_name(service)])
  end
  def enable_meter_services(services = collector_service_names())
    systemd = Systemd::Manager.new
    services.each {|service|
      systemd.enable_units(service)
      systemd.start(service, 'replace') }
  end

  def disable_meter_service(service)
    Rails.logger.debug service
    Rails.logger.debug service_name(service)
    disable_meter_services([service_name(service)])
  end
  def disable_meter_services(services = collector_service_names())
    systemd = Systemd::Manager.new
    services.each {|service|
      systemd.disable_units(service)
      systemd.stop(service, 'replace') }
  end

  def collector_service_names
    DockerHelper::METER_CONTAINER_NAMES.map{|name| container_to_service_name(name)}
  end

  # Convert containers to service names
  def service_name(thing)
    case thing
    when /\.service$/ then thing
    when /[A-Z]/      then service_label_to_service_name(thing)
    else container_to_service_name(thing)
    end
  end

  def container_to_service_name(container)
    container = container.name unless container.is_a?(String) #convert from container object to plain string of container name
    container = "meter-#{container}" unless container.start_with?('meter-')
    container += '.service'
  end
  def service_label_to_service_name(service_label)
    service_name = SERVICE_LABEL_MAP[service_label]
    service_name = "meter-#{service_name}" unless service_name.start_with?('meter-')
    service_name += '.service'
  end
  def service_label_to_container_name(service_label)
    SERVICE_LABEL_MAP[service_label]
  end

  def human_to_service(service)
    if ( SERVICE_LABEL_MAP.has_key?(service) )
      container = SERVICE_LABEL_MAP[service]
      container = "meter-#{container}" unless container.start_with?('meter-')
      container += '.service'
    else
      "#{service}.service" # in case a service name was passed in, and doesn't need conversion
    end
  end

  module_function :disable_meter_service, :disable_meter_services, :collector_service_names, :container_to_service_name,
                  :human_to_service, :service_label_to_container_name, :service_label_to_service_name

end
