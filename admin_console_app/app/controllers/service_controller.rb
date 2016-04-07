class ServiceController < ApplicationController
  include DockerHelper
  include DockerHubHelper
  include SystemdHelper

  # Restart individual containers
  # The 0.5 second delay helps the UI/javascript not refresh too fast (so you don't end up with an
  #  apparent status of "disabled" after clicking enabled just because the systemd methods return too quickly
  def restart
    containers = [params[:container]] || METER_CONTAINERS
    containers.each do |container|
      if ( service = human_to_service(container) )
        systemd = Systemd::Manager.new
        systemd.stop(service,  "replace")
        sleep(0.5) # Give systemd a chance to settle
        systemd.start(service, "replace")
      end
    end
    sleep(1)
    render nothing: true, :status => 200
  end

  def start
    params[:container] ?
      enable_meter_service(params[:container]) :
      enable_meter_services
    sleep(1)
    render nothing: true, :status => 200
  end

  # If no args are provided, stop all collector services
  def stop
    params[:container] ? #!! should rename this to service, or "service label" or somethign
      disable_meter_service(params[:container]) :
      disable_meter_services
    sleep(1)
    render nothing: true, :status => 200
  end

  # Reboot entire appliance at OS level
  def reboot
    logger.info "Rebooting at user request"
    HostCommandHelper::run("/usr/sbin/reboot")
    render nothing: true, :status => 200
  end

  # Shutdown appliance
  def poweroff
    systemd = Systemd::Manager.new

    logger.info "Shutting down at user request"
    systemd.start('poweroff.target', 'replace')
    render nothing: true, :status => 200
  end

end
