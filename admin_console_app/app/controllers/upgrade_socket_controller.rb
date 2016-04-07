Thread::abort_on_exception = true

class UpgradeSocketController < WebsocketRails::BaseController
  include DockerHelper

  def update_containers
    Rails.logger.info "Starting meter upgrade process"

    config = MeterConfigurationDocument.first
    fromImage = "#{config.container_namespace}/#{config.container_repository}"

    send_message :start, { message: 'Retreiving updates from repository' }, namespace: 'upgrade'
    # Make a backup of the current cloud-config
    FileUtils::copy(host_cloud_config_file, host_cloud_config_file + '-' + DockerHelper::current_version)

    Thread.new do
      begin
        download_image(fromImage, DockerHubHelper::latest_version)
        download_dependencies
        update_coreos
        cleanup
      rescue StandardError => e
        Rails.logger.fatal e.message
        Rails.logger.fatal e.backtrace
      ensure
        send_message :finished, "Upgrade complete", namespace: 'upgrade'
      end
    end
  end

  private

  # Parse and download any other docker images the meter requires. Expects the dependencies to be included in the
  # cloud config (pulled from the updated meter image) in the format:
  # # DEPENDENCIES mongo:3.0 ruby:4.0.4
  # Note that the meter image itself should not be included
  def download_dependencies
    if ( dependency_line = cloud_config.split(/$/).find{|line| line.match(/#\s*DEPENDENCIES/)} )
      dependency_md = dependency_line.match(/DEPENDENCIES[:\s=](.+)/)
      if ( dependency_md )
        dependency_md[1].split(/[,\s]/).each{|image|
          download_image(*(image.split(':'))) }
      end
    end
  end

  # Reinitialize coroes/systemd with the updated cloud config
  def update_coreos
    File.write('/host' + host_cloud_config_file, cloud_config)
    exit_code, output = HostCommandHelper::run("/usr/bin/coreos-cloudinit --from-file #{host_cloud_config_file} 2> /dev/null")
    if ( exit_code != 0 )
      send_message( :status,
                    { message: "There was an error updating the appliance cloud config: #{$!}",
                      type: 'error'},
                    namespace: 'upgrade' )
      Rails.logger.error "Error updating cloud config: #{$!} (#{$?}) "
      Rails.logger.debug output
    end
  end

  # Download image from docker hub
  def download_image(fromImage, tag)
    begin
      logger.info "Downloading #{fromImage}:#{tag}"
      download_in_progess = false
      image = Docker::Image.create(fromImage: fromImage, tag: tag) do |status_message|
        send_message :new_message, { image: fromImage }, namespace: 'upgrade'

        response = JSON::parse(status_message)

        if ( response['status'] and response['status'].match(/Pulling from/) )
          # Nothing to relay to user for this
        elsif ( response['status'] =~ /already being pulled by another client/ )
          send_message( :status,
                        { message: 'Download already in progress from another process',
                          image: fromImage },
                        namespace: 'upgrade' )
        else
          send_message( :new_message,
                        { image: fromImage,           layer_id: response['id'],
                          status: response['status'], percent_complete: percent_complete(response) },
                        namespace: 'upgrade')
        end
      end

      send_message :new_message, { status: 'complete', image: fromImage }, namespace: 'upgrade'

      image.refresh!
      cycle_tags(image)
      image
    rescue Docker::Error::NotFoundError => e
      # Not a typical scenario, but if the image is already downloaded, the Docker::Image.create throws this NotFoundError -_-;
      send_message :new_message, { status: 'complete', image: fromImage }, namespace: 'upgrade'
    rescue StandardError => e
      # For reasons unknown, a Docker::Error::ArgumentError can be thrown, with the message Must have id, got: {"id"=>nil, :headers=>{}}
      # It's a pointless exception, so don't bother relaying it to the user
      unless ( e.message =~ /Must have id/ )
        Rails.logger.fatal e.message
        Rails.logger.debug e.backtrace.join("\n")
        send_message( :status,
                      { message: "Error downloading #{fromImage}:#{tag}:<br>#{e.message}",
                        image: fromImage,
                        type: 'error' },
                      namespace: 'upgrade' )
      end
    end
  end

  # Tag old (i.e., previous) images for removal, tag "current" images as previous, and tag new images as current
  def cycle_tags(image)
    previous_image = DockerHelper::images_with_tag('current').find{|i| i.repository.eql?(image.repository)} || active_containers.map(&:image).find{|i| i.repository.eql?(image.repository)}

    # Only move the tags if the newly downloaded stuff doesn't match what is already in place (e.g., ran the upgrade process 2X in row)
    if ( previous_image and
         !previous_image.id.start_with?(image.id) )

      old_image = DockerHelper::images_with_tag('previous').find{|i| i.repository.eql?(image.repository)}
      DockerHelper::change_tag(old_image, 'previous', 'delete') if old_image

      DockerHelper::change_tag(previous_image, 'current', 'previous')
    end

    image.tag(repo: image.repository, tag: 'current', force: true)
  end

  #!! possibly move this into the cycle_tags logic
  def cleanup
    DockerHelper::images_with_tag('delete').each{|image|
      image.remove }
  end

  # Interpret various status messages from docker pull output into a percentage
  def percent_complete(response)
    case response['status']
      when 'Pulling fs layer'         then 0
      when 'Download complete'        then 100
      when 'Already exists'           then 100
      when /Image is up to date/      then 100
      when 'Verifying Checksum'       then 100
      when 'Pulling dependent layers' then 0
      when 'Downloading'
        if ( response['progressDetail']['total'] == '-1' )
          (response['progressDetail']['current'].to_f / response['progressDetail']['start'].to_f * 100).round
        else
          (response['progressDetail']['current'].to_f / response['progressDetail']['total'].to_f * 100).round
        end
      else
        nil
    end
  end

  #!! maybe mount the dev version of this file as cloud-config.yml ?
  def host_cloud_config_file
    '/usr/share/oem/cloud-config.yml'
  end

  # Spin up a container corresponding to the latest downloaded image and cat out its cloud-config
  def cloud_config
    Rails.cache.fetch(:cloud_config, expires_in: 1.minute, compress: true) do
      exit_code, output = HostCommandHelper::run("/usr/bin/docker run --name cat_cloud_config #{DockerHelper::latest_local_image.id} cat /usr/share/oem/cloud-config.yml")
      if ( exit_code != 0 )
        Rails.logger.error "Unable to retrieve cloud_config.yml from latest image: error #{exit_code}"
        Rails.logger.debug output
      end

      exit_code = HostCommandHelper::run("/usr/bin/docker rm cat_cloud_config")
      Rails.logger.warn("Unable to remove cat_cloud_config container") unless exit_code == 0

      output
    end
  end

end
