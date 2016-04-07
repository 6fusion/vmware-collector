class StatusController < ApplicationController
  include DockerHelper
  include SystemdHelper

  def services
    @containers = active_containers.map{|container|
      { name: container_to_human(container),
        status: container.info['Status'] } }

    stopped_services.each{|name|
      @containers << { name: name, status: 'paused' } }

    respond_to do |format|
      format.json { render json: @containers }
    end
  end

  def appliance
    stats = Hash.new
    exit_code, output = HostCommandHelper::run("df -t overlay -BG | tail -n1")
    disk_size, disk_used = output.split(/\s+/)[1,2]
    disk_size.sub!('G','')
    disk_used.sub!('G','')

    stats[:disk_size] = disk_size.to_i
    stats[:disk_used] = disk_used.to_i

    uptime, load = `uptime`.match(/up (.+),\s+\d users,\s+load average: ([\d\.]+)/)[1,2]
    stats[:uptime] = uptime
    stats[:load] = load

    respond_to do |format|
      format.json { render json: stats }
    end
  end

  def health
    database_size = Mongoid.default_session.collection_names.sum{|collection|
      Mongoid.default_session.command(collstats: collection)[:storageSize]} / 1024.0**2
    queued_metrics = Reading.where({record_status: 'created'}).count

    services = "#{active_containers.size} / #{CONTAINER_NAMES.size}"

    respond_to do |format|
      format.json { render json: { database_size: "#{database_size.round} MiB",
                                   queued_metrics: queued_metrics,
                                   service_count: services } }
    end
  end


end
