module DockerHelper

  CONTAINER_NAME_MAP = { 'infrastructure-collector' => 'Infrastructure Collector',
                         'inventory-collector'      => 'Inventory Collector',
                         'meter-database'           => 'Database',
                         'metrics-collector'        => 'Metrics Collector',
                         'meter-registration'       => 'Meter Console',
                         'missing-readings-handler' => 'Missing Metrics Collector',
                         'uc6-connector'            => 'UC6 Connector' }

  CONTAINER_NAMES = Set.new( CONTAINER_NAME_MAP.keys )
  METER_CONTAINER_NAMES = CONTAINER_NAMES - %w(meter-database meter-registration)

  class Docker::Container
    def image
      Docker::Image.get(info['Image']).refresh!
    end
    def repository
      info['Image'].split(':')[0]
    end
    def name
      json['Name'].delete('/')
    end
  end

  class Docker::Image
    def tags
      info['RepoTags'] || []
    end
    def repository
      repo_tag = tags.find{|tag| tag.match(/\w+:\w/) }
      repo_tag ?
        repo_tag.split(':').first :
        nil
    end
  end


  def active_containers
    Docker::Container.all.select{|container|
      CONTAINER_NAMES.include?(container.name) }
  end

  def active_meter_containers
    Docker::Container.all.select{|container|
      METER_CONTAINER_NAMES.include?(container.name) }
  end

  def stopped_services
    active = active_containers
    CONTAINER_NAMES.reject{|name| active.find{|c| name == c.name } }.map{|name| CONTAINER_NAME_MAP[name] }
  end

  def images_with_tag(tag)
    Docker::Image.all.select{|image|
      image.tags.find{|t| t.match(/#{tag}$/) } }
  end

  def change_tag(image, old_tag, new_tag)
    image.tag(repo: image.repository, tag: new_tag, force: true)
    name = image.tags.find{|tag| tag.match(/#{old_tag}$/) }
    image.remove(name: name) if name
  end

  def signal_meters(signal='HUP')
    active_meter_containers.each{|container|
      container.kill(signal: signal) }
  end

  def current_container
    Docker::Container.get(ENV['HOSTNAME'])
  end

  def current_version
    version = current_container.image.tags.find{|tag| tag.match(%r|#{Version::VERSION_REGEXP}|)}
    version ? Version.new(version).to_s : current_container.image.id[0..12]
  end

  def latest_local_image
    latest = latest_local_image_version.to_s
    meter_images.find{|image| image.tags.find{|tag| tag.eql?("#{namespace}/#{repository}:#{latest}")} }
  end

  def latest_local_image_version
    meter_images.map{|image| Version.new(image.tags.sort.first)}.max  # The sort forces numeric tags (i.e., versions) to occur prior to tags like 'current'
  end
  def meter_images
    Docker::Image.all.select{|image| image.tags.find{|tag| tag.match(%r|#{namespace}/#{repository}|)}}
  end


  #!! consolidate with dockerhubhelper
  def repository
    configuration.container_repository.blank? ? 'vmware-meter' : configuration.container_repository
  end
  def namespace
    configuration.container_namespace.blank? ? '6fusion' : configuration.container_namespace
  end
  def configuration
    MeterConfigurationDocument.first || MeterConfigurationDocument.new
  end

  def container_to_human(container)
    CONTAINER_NAME_MAP[ container.name ]
  end


  module_function :active_containers, :active_meter_containers,
                  :change_tag, :configuration, :current_container, :current_version,
                  :images_with_tag, :latest_local_image, :latest_local_image_version,
                  :meter_images, :namespace,
                  :repository,  :stopped_services, :signal_meters

end
