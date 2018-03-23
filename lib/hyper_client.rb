require 'uri'

require 'json'
require 'rest_client_extensions'

class HyperClient

  def initialize
    RestClient.proxy = api_proxy
  end

  def get_infrastructure(id)
    get("#{api_endpoint}/infrastructures/#{id}")
  end

  # HEAD
  def head(item)
    case
    when item.is_a?(Infrastructure) then head_infrastructure(item.custom_id)
    when item.is_a?(Machine) then head_machine(item.custom_id)
    end
  end
  def head_infrastructure(id); do_head("#{api_endpoint}/infrastructures/#{id}"); end
  def head_machine(id); do_head("#{api_endpoint}/machines/#{id}"); end

  # TODO genericize with other CRUD methods? becomes "do(:head)" ?
  def do_head(url, headers = {})
    first_attempt = true
    begin
      url, params = decode_url(url)
      merged_headers = headers.merge(params)
      merged_headers = merged_headers.merge(access_token: oauth_token)
      wrapped_request { RestClient.head(url, params: merged_headers) }
    rescue RestClient::Unauthorized => e
      if first_attempt
        first_attempt = false
        reset_token
        retry
      end
    rescue RestClient::RequestTimeout => e
      if first_attempt
        first_attempt = false
        retry
      end
    rescue RestClient::ResourceNotFound => e
      $logger.info "#{e.message} for HEAD request to #{url}"
      nil
    rescue StandardError => e
      $logger.error "#{e.message} for HEAD request to #{url}"
      $logger.error e.inspect
      $logger.debug merged_headers.to_json
      $logger.debug e
      raise e
    end
  end
  

  # POST
  def post(item)
    case
    when item.is_a?(Infrastructure) then post_infrastructure(item)
    when item.is_a?(Machine) then post_machine(item)
    end
  end
  def post_infrastructure(infrastructure)
    do_post("#{api_endpoint}/organizations/#{organization_id}/infrastructures", infrastructure.api_format)
  end
  def post_machine(machine)
    do_post("#{api_endpoint}/infrastructures/#{machine.infrastructure_custom_id}/machines", machine.api_format)
  end
  def post_samples(machine_id, samples_json)
    do_post("#{api_endpoint}/machines/#{machine_id}/samples", samples_json)
  end
  def post_disk(machine_id, disk_json)
    do_post("#{api_endpoint}/machines/#{machine_id}/disks", disk_json)
  end
  def put_disk(disk_json)
    put("#{api_endpoint}/disks/#{disk_json[:custom_id]}", disk_json)
  end
  def post_nic(machine_id, nic_json)
    do_post("#{api_endpoint}/machines/#{machine_id}/nics", nic_json)
  end
  def do_post(url, headers = {})
    first_attempt = true
    begin
      merged_headers = headers.merge(access_token: oauth_token)
      $logger.debug "Posting: #{url}, params: #{merged_headers}"
      wrapped_request { RestClient.post(url, merged_headers.to_json, accept: :json, content_type: :json) }
    rescue RestClient::Unauthorized => e
      if first_attempt
        first_attempt = false
        reset_token
        retry
      end
    rescue RestClient::RequestTimeout => e
      if first_attempt
        first_attempt = false
        retry
      end
    rescue StandardError => e
      $logger.error "#{e.message} for POST to #{url}"
      $logger.debug merged_headers
      $logger.debug e.inspect
      raise e
    end
  end




  def get_machines(infrastructure_id: nil, url: nil)
    infrastructure_id ?
      get("#{api_endpoint}/machines?infrastructure_id=#{infrastructure_id}") :
      get(url)
  end
  def put_machine(machine_json)
    put("#{api_endpoint}/machines/#{machine_json[:custom_id]}", machine_json)
  end

  def put_nic(nic_json)
    put("#{api_endpoint}/nics/#{nic_json[:custom_id]}", nic_json)
  end

  def decode_url(url)
    params = ''
    url, params = url.split('?') if url.include?('?')
    [url, URI.decode_www_form(params).to_h]
  end



  def get(url, headers = {})
    first_attempt = true
    begin
      url, params = decode_url(url)
      url += '.json' unless url.end_with?('.json')
      merged_headers = headers.merge(params).merge(accept: :json, content_type: :json)
      merged_headers = merged_headers.merge(access_token: oauth_token)
      wrapped_request { RestClient.get(url, params: merged_headers) }
    rescue RestClient::Unauthorized => e
      if first_attempt
        first_attempt = false
        reset_token
        retry
      end
    rescue RestClient::RequestTimeout => e
      if first_attempt
        first_attempt = false
        retry
      end
    rescue RestClient::ResourceNotFound => e
      $logger.warn "#{e.message} for get request to #{url}"
      nil
    rescue StandardError => e
      $logger.error "#{e.message} for get request to #{url}"
      $logger.error e.inspect
      $logger.debug merged_headers.to_json
      $logger.debug e
      raise e
    end
  end


  def put(url, headers = {})
    first_attempt = true
    begin
      merged_headers = headers.merge(access_token: oauth_token)
      $logger.debug "Putting: #{url}, params: #{merged_headers}"
      wrapped_request { RestClient.put(url, merged_headers.to_json, content_type: :json, accept: :json) }
    rescue RestClient::Unauthorized => e
      if first_attempt
        first_attempt = false
        reset_token
        retry
      end
    rescue RestClient::RequestTimeout => e
      if first_attempt
        first_attempt = false
        retry
      end
    rescue StandardError => e
      $logger.error "#{e.message} for put request to #{url}"
      $logger.error e.inspect
      $logger.debug merged_headers.to_json
      $logger.debug e.backtrace.join("\n")
      raise e
    end
  end

  def delete(url, headers = {})
    first_attempt = true
    begin
      merged_headers = headers.merge(access_token: oauth_token)
      $logger.debug "Posting delete: #{url}, params: #{merged_headers}"
      wrapped_request { RestClient.delete(url, params: merged_headers) } # !!! .to_json bombed out?
    rescue RestClient::Unauthorized => e
      if first_attempt
        first_attempt = false
        reset_token
        retry
      end
    rescue RestClient::RequestTimeout => e
      if first_attempt
        first_attempt = false
        retry
      end
    rescue StandardError => e
      $logger.error "#{e.message} for delete request to #{url}"
      $logger.error e.inspect
      $logger.debug merged_headers.to_json
      $logger.debug e
      raise e
    end
  end

  # Gets data for all links and returns array of results
  # !! may need to consider some enumerable/cursorable form of this (avoid using too much memory, ex 100000 machines)
  def get_all_resources(initial_page_url, opts = {})
    all_json_data = []
    http_req = initial_page_url.start_with?('http')

    response = get(initial_page_url, opts)
    response_json = response.json
    all_json_data.concat(response_json['embedded'].values.flatten)
    while response_json['_links']['next']
      next_results_href = response_json['_links']['next']['href']
      # When in development, sometimes need http and links are all https
      next_results_href.sub!('https', 'http') if http_req && Rails.env.eql?('development')

      response = get(next_results_href) # original opts are included in the returned "next" url
      response_json = response.json
      all_json_data.concat(response_json['embedded'].first[1])
    end

    all_json_data
  end

  def organization_id
    @organization_id ||= ENV['ON_PREM_ORGANIZATION_ID']
  end

  def oauth_token
    # first_attempt = true
    @oauth_token ||= ENV['ON_PREM_OAUTH_TOKEN']
    # if @configuration.present_value?(:on_prem_oauth_token)
    #   $logger.debug 'Returning locally saved oauth token'
    #   @configuration[:on_prem_oauth_token]
    # else
    #   begin
    #     $logger.debug "Retrieving oauth token for #{@configuration[:on_prem_login_email]}"
    #     $logger.debug 'Attempting to retrieve oauth access token'
    #     response = refresh_token_from_refreshtoken || refresh_token_from_credentials
    #     @configuration[:on_prem_oauth_token] = response.token
    #     if response.refresh_token && !response.refresh_token.blank?
    #       @configuration[:on_prem_refresh_token] = response.refresh_token
    #     else
    #       $logger.warn 'Did not receive refresh token from oauth token request.'
    #       raise RestClient::Unauthorized # Utilize the rescue below to attempt the request again
    #     end
    #     response.token
    #   rescue RestClient::Unauthorized => e
    #     if first_attempt
    #       $logger.debug 'Error obtaining oauth token. Retrying...'
    #       first_attempt = false
    #       retry
    #     end
    #     $logger.error 'Unable to authorize user account for submission API'
    #     $logger.error e.inspect
    #     $logger.debug @configuration.to_s
    #     raise e
    #   rescue StandardError => e
    #     $logger.error e.class
    #     $logger.error e
    #     raise e
    #   end
    # end
  end

  # def oauth_client
  #   @oauth_client ||= begin
  #     connection_opts = if @configuration.present_value?(:on_prem_proxy_host)
  #                         {proxy: {uri: "#{@configuration[:on_prem_proxy_host]}:#{@configuration[:on_prem_proxy_port]}",
  #                                  user: @configuration[:on_prem_proxy_user],
  #                                  password: @configuration[:on_prem_proxy_password]}}
  #                       else
  #                         {}
  #                       end

  #     if @configuration.present_value?(:on_prem_refresh_token)
  #       OAuth2::Client.new(nil, nil, site: @configuration[:on_prem_oauth_endpoint], connection_opts: connection_opts)
  #     else
  #       OAuth2::Client.new(@configuration[:on_prem_application_id],
  #                          @configuration[:on_prem_application_secret],
  #                          site: @configuration[:on_prem_oauth_endpoint],
  #                          connection_opts: connection_opts)
  #     end
  #   end
  # end

  # def oauth_password_client
  #   @oauth_password_client ||= begin
  #     OAuth2::Client.new(@configuration[:on_prem_application_id],
  #                        @configuration[:on_prem_application_secret],
  #                        site: @configuration[:on_prem_oauth_endpoint],
  #                        connection_opts: @configuration.present_value?(:on_prem_proxy_host) ?
  #                            {proxy: {uri: "#{@configuration[:on_prem_proxy_host]}:#{@configuration[:on_prem_proxy_port]}",
  #                                     user: @configuration[:on_prem_proxy_user],
  #                                     password: @configuration[:on_prem_proxy_password]}} : {})
  #   end
  # end

  # def oauth_refreshtoken_client
  #   @oauth_refreshtoken_client ||= begin
  #     OAuth2::Client.new(nil, nil,
  #                        site: @configuration[:on_prem_oauth_endpoint],
  #                        connection_opts: @configuration.present_value?(:on_prem_proxy_host) ?
  #                            {proxy: {uri: "#{@configuration[:on_prem_proxy_host]}:#{@configuration[:on_prem_proxy_port]}",
  #                                     user: @configuration[:on_prem_proxy_user],
  #                                     password: @configuration[:on_prem_proxy_password]}} : {})

  #   end
  # end

  # Blank out the oauth token so a new request for one will be made
  # def reset_token
  #   $logger.debug 'Resetting oauth token'
  #   @oauth_token = nil
  #   @configuration.delete(:on_prem_oauth_token)
  # end

  private
  def api_proxy
    # TODO Verify nil vs blank kubernetes environment vars
    @api_proxy ||= begin
                     if ENV['ON_PREM_PROXY_HOST']
                       host_uri = URI.parse(ENV['ON_PREM_PROXY_HOST'])
                       proxy_string = host_uri.scheme + '://'
                       if ENV['ON_PREM_PROXY_USER']
                         proxy_string += ENV['ON_PREM_PROXY_USER']
                         proxy_string += ENV['ON_PREM_PROXY_PASSWORD'] ? ":#{ENV['ON_PREM_PROXY_PASSWORD']}@" : '@'
                       end
                       proxy_string += host_uri.host
                       proxy_string += ":#{ENV['ON_PREM_PROXY_PORT']}" if ENV['ON_PREM_PROXY_PORT']
                       proxy_string
                     end
                   end
  end

  def api_endpoint
    @api_endpoint ||= "#{ENV['METER_API_PROTOCOL'] || 'https'}://#{ENV['ON_PREM_API_HOST']}:#{ENV['ON_PREM_API_PORT']}/api/v1"
  end

  def wrapped_request
    # !! should this be reworked to look at expires_in/_at and preemptively request?
    #   are there other situations where we need to legitimately re-request a token
    first_attempt = true
    response = nil
    begin
      response = yield
    rescue RestClient::Unauthorized => e
      $logger.debug 'Receieved 401 Unauthorized for request'
      if first_attempt
        $logger.debug 'Retrying request'
        first_attempt = false
        reset_token
        retry
      else
        raise e
      end
    end
    response
  end

  # def refresh_token_from_refreshtoken
  #   $logger.debug 'Attempting to refresh oauth token'
  #   if @configuration.present_value?(:on_prem_refresh_token)
  #     begin
  #       token = OAuth2::AccessToken.from_hash(oauth_refreshtoken_client, refresh_token: @configuration[:on_prem_refresh_token])
  #       token.refresh!
  #     rescue OAuth2::Error => e
  #       $logger.error 'Could not retrieve oauth token from OnPrem'
  #       $logger.info e.message
  #       $logger.debug e.backtrace.join("\n")
  #       nil
  #     end
  #   end
  # end

  # def refresh_token_from_credentials
  #   $logger.debug "Attempting to refresh oauth token with credentials for #{@configuration[:on_prem_login_email]}"

  #   if @configuration.present_value?(:on_prem_login_password)
  #     oauth_password_client.password.get_token(@configuration[:on_prem_login_email],
  #                                              @configuration[:on_prem_login_password],
  #                                              scope: @configuration[:on_prem_api_scope])
  #   else
  #     $logger.error 'Cannot retrieve oauth token by credentials; not OnPrem login password available'
  #     nil
  #   end
  # end
end
