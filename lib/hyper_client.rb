require 'uri'

require 'global_configuration'
require 'json'
require 'logging'
require 'rest_client_extensions'

class HyperClient
  include GlobalConfiguration
  include Logging

  def initialize(configuration = GlobalConfiguration::GlobalConfig.instance)
    @configuration = configuration
    RestClient.proxy = @configuration[:uc6_proxy]
    @oauth_token = @configuration[:uc6_oauth_token]
  end

  def decode_url(url)
    params = ''
    url, params = url.split('?') if url.include?('?')
    [url, URI.decode_www_form(params).to_h]
  end

  # !!! Do we need the content_type: :json and accept: :json for all actions???
  def get(url, headers = {})
    first_attempt = true
    begin
      url, params = decode_url(url)
      merged_headers = headers.merge(params)

      # only merge the access token if it's empty
      merged_headers = merged_headers.merge(access_token: oauth_token) if oauth_token.present? && oauth_token != GlobalConfiguration::DEFAULT_EMPTY_VALUE
      logger.debug "Retrieving: #{url}, params: #{merged_headers}"
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
    rescue StandardError => e
      logger.error "#{e.message} for get request to #{url}"
      logger.error JSON.parse(e.response)['message']
      logger.debug merged_headers.to_json
      logger.debug e
      raise e
    end
  end

  def post(url, headers = {})
    first_attempt = true
    begin
      merged_headers = headers.merge(access_token: oauth_token)
      logger.debug "Posting: #{url}, params: #{merged_headers}"
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
      logger.error "#{e.message} for post request to #{url}"
      logger.debug merged_headers
      logger.debug e.response
      raise e
    end
  end

  def put(url, headers = {})
    first_attempt = true
    begin
      merged_headers = headers.merge(access_token: oauth_token)
      logger.debug "Putting: #{url}, params: #{merged_headers}"
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
      logger.error "#{e.message} for put request to #{url}"
      logger.error JSON.parse(e.response)['message']
      logger.debug merged_headers.to_json
      logger.debug e.backtrace
      raise e
    end
  end

  def delete(url, headers = {})
    first_attempt = true
    begin
      merged_headers = headers.merge(access_token: oauth_token)
      logger.debug "Posting delete: #{url}, params: #{merged_headers}"
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
      logger.error "#{e.message} for delete request to #{url}"
      logger.error JSON.parse(e.response)['message']
      logger.debug merged_headers.to_json
      logger.debug e
      raise e
    end
  end

  # Gets data for all links and returns array of results
  # !! may need to consider some enumerable/cursorable form of this (avoid using too much memory, ex 100000 machines)
  def get_all_resources(initial_page_url, opts = {})
    opts[:limit] = @configuration[:uc6_batch_size] unless opts.key?(:limit)
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

  def oauth_token
    first_attempt = true
    @oauth_token ||=
        if @configuration.present_value?(:uc6_oauth_token)
        logger.debug 'Returning locally saved oauth token'
        @configuration[:uc6_oauth_token]
        else
        begin
          logger.debug "Retrieving oauth token for #{@configuration[:uc6_login_email]}"
          logger.debug 'Attempting to retrieve oauth access token'
          response = refresh_token_from_refreshtoken || refresh_token_from_credentials
          @configuration[:uc6_oauth_token] = response.token
          if response.refresh_token && !response.refresh_token.blank?
            @configuration[:uc6_refresh_token] = response.refresh_token
          else
            logger.warn 'Did not receive refresh token from oauth token request.'
            raise RestClient::Unauthorized # Utilize the rescue below to attempt the request again
          end
          response.token
        rescue RestClient::Unauthorized => e
          if first_attempt
            logger.debug 'Error obtaining oauth token. Retrying...'
            first_attempt = false
            retry
          end
          logger.error 'Unable to authorize user account for submission API'
          logger.error JSON.parse(e.response)['message']
          logger.debug e
          logger.debug @configuration.to_s
          raise e
        rescue StandardError => e
          logger.error e.class
          logger.error e
          raise e
        end
        end
  end

  def oauth_client
    @oauth_client ||= begin
      connection_opts = if @configuration.present_value?(:uc6_proxy_host)
                          {proxy: {uri: "#{@configuration[:uc6_proxy_host]}:#{@configuration[:uc6_proxy_port]}",
                                   user: @configuration[:uc6_proxy_user],
                                   password: @configuration[:uc6_proxy_password]}}
                        else
                          {}
                        end

      if @configuration.present_value?(:uc6_refresh_token)
        OAuth2::Client.new(nil, nil, site: @configuration[:uc6_oauth_endpoint], connection_opts: connection_opts)
      else
        OAuth2::Client.new(@configuration[:uc6_application_id],
                           @configuration[:uc6_application_secret],
                           site: @configuration[:uc6_oauth_endpoint],
                           connection_opts: connection_opts)
      end
    end
  end

  def oauth_password_client
    @oauth_password_client ||= begin
      OAuth2::Client.new(@configuration[:uc6_application_id],
                         @configuration[:uc6_application_secret],
                         site: @configuration[:uc6_oauth_endpoint],
                         connection_opts: @configuration.present_value?(:uc6_proxy_host) ?
                             {proxy: {uri: "#{@configuration[:uc6_proxy_host]}:#{@configuration[:uc6_proxy_port]}",
                                      user: @configuration[:uc6_proxy_user],
                                      password: @configuration[:uc6_proxy_password]}} : {})
    end
  end

  def oauth_refreshtoken_client
    @oauth_refreshtoken_client ||= begin
      OAuth2::Client.new(nil, nil,
                         site: @configuration[:uc6_oauth_endpoint],
                         connection_opts: @configuration.present_value?(:uc6_proxy_host) ?
                             {proxy: {uri: "#{@configuration[:uc6_proxy_host]}:#{@configuration[:uc6_proxy_port]}",
                                      user: @configuration[:uc6_proxy_user],
                                      password: @configuration[:uc6_proxy_password]}} : {})

    end
  end

  # Blank out the oauth token so a new request for one will be made
  def reset_token
    logger.debug 'Resetting oauth token'
    @oauth_token = nil
    @configuration.delete(:uc6_oauth_token)
  end

  private

  def wrapped_request
    # !! should this be reworked to look at expires_in/_at and preemptively request?
    #   are there other situations where we need to legitimately re-request a token
    first_attempt = true
    response = nil
    begin
      response = yield
    rescue RestClient::Unauthorized => e
      logger.debug 'Receieved 401 Unauthorized for request'
      if first_attempt
        logger.debug 'Retrying request'
        first_attempt = false
        reset_token
        retry
      else
        raise e
      end
    end
    response
  end

  def refresh_token_from_refreshtoken
    logger.debug 'Attempting to refresh oauth token'
    if @configuration.present_value?(:uc6_refresh_token)
      begin
        token = OAuth2::AccessToken.from_hash(oauth_refreshtoken_client, refresh_token: @configuration[:uc6_refresh_token])
        token.refresh!
      rescue OAuth2::Error => e
        logger.error 'Could not retrieve oauth token from UC6'
        logger.info e.message
        logger.debug e.backtrace.join("\n")
        nil
      end
    end
  end

  def refresh_token_from_credentials
    logger.debug "Attempting to refresh oauth token with credentials for #{@configuration[:uc6_login_email]}"

    if @configuration.present_value?(:uc6_login_password)
      oauth_password_client.password.get_token(@configuration[:uc6_login_email],
                                               @configuration[:uc6_login_password],
                                               scope: @configuration[:uc6_api_scope])
    else
      logger.error 'Cannot retrieve oauth token by credentials; not UC6 login password available'
      nil
    end
  end
end
