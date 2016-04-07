require 'json'
require 'rest-client'

module DockerHubHelper

  def latest_image_id
    tag = docker_tags.find{|tag| tag['name'].eql?(latest_version.to_s)}
    tag ? tag['layer'].to_s : ''
  end


  def latest_version
    Rails.cache.fetch(:latest_version, expires_in: 30.seconds) {
      docker_tags
       .map{|tag| Version.new(tag['name'])}
       .max || Version.new
     }
  end


  def latest_release_notes
    Rails.cache.fetch(:latest_release_notes, expires_in: 30.seconds) do
      fallback = 'Please contact 6fusion support for latest version release notes.'
      retried = false
      begin
        html = Nokogiri::HTML(RestClient.get("https://hub.docker.com/r/#{namespace}/#{repository}/"))
        rn_elem = html.search("[text()*='Release Notes']")

        all_notes = []
        return fallback unless rn_elem
        header_elem = rn_elem.first
        return fallback unless header_elem

        start_capturing = nil
        header_elem.parent.children.each{|elem|
          start_capturing ||= (elem == header_elem ? true : nil)
          all_notes << elem if start_capturing }

        all_notes.map(&:to_html).join
      rescue StandardError => e
        Rails.logger.error e.message
        Rails.logger.error e.backtrace
        fallback
      end
    end
  end

  def update_available?
    !DockerHelper::current_container.image.id.start_with?(DockerHubHelper::latest_image_id)
  end

  private
  def docker_tags
    Rails.cache.fetch(:docker_tags, expires_in: 30.seconds){
      begin
        JSON::parse(RestClient.get(tag_url)) # Assumes tags of interest are on first "page" of results
      rescue StandardError => e
        Rails.logger.error "Could not access docker tags at #{tag_url}"
        Rails.logger.debug e
        Rails.logger.debug e.http_body if e.is_a?(RestClient::Exception)
        []
      end
    }
  end

  def tag_url
#    "https://hub.docker.com/v2/repositories/#{namespace}/#{repository}/tags"
    "https://registry.hub.docker.com/v1/repositories/#{namespace}/#{repository}/tags"
 end

  def repository
    configuration.container_repository.blank? ? 'vmware-meter' : configuration.container_repository
  end
  def namespace
    configuration.container_namespace.blank? ? '6fusion' : configuration.container_namespace
  end

  #!! probably belongs in a helper
  def configuration
    MeterConfigurationDocument.first || MeterConfigurationDocument.new
  end

  module_function :latest_version, :latest_release_notes, :latest_image_id,
                  :docker_tags, :tag_url, :namespace, :repository, :configuration, :update_available?

end
