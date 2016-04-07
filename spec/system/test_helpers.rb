####################################################
# Test helper functions used in rspec integration tests

require 'psych'
require 'airborne'
#require 'awesome_print'

### Define consts ###
UUID_pattern = /^[a-f0-9]{8}(-[a-f0-9]{4}){3}-[a-f0-9]{12}$/

uc6admin = {
    :NAME => "6fusion Staging",
    :LOCAL_TEST_URI => 'urn:ietf:wg:oauth:2.0:oob',
    :APP_ID => '188d002dd473d0707bcf01352fdbe4b7eb417d5299ac4c19dd426775fbe2a8e1',
    :APP_SECRET => '7ed3fb7bed55954dd142be207b05b789ebd635e46dea35193f16f0512143d37c',
    :APP_CALLBACK_URL => 'http://localhost:3001/',
    :SITE_BASE_URL => 'https://api-staging.6fusion.com/',
    :SITE_OAUTH_PATH => '/oauth/authorize',
    :USER_EMAIL => 'uc6admin@6fusion.com',
    :USER_PASSWORD => 'may the schwartz be with you'
}
# Token: 088b0849fa7803fd4c0c80bb22458eff2da0596ba41f4073d0d3743c6ec43fb1

test_acct = {
    :NAME => "6fusion Staging",
    :LOCAL_TEST_URI => 'urn:ietf:wg:oauth:2.0:oob',
    :APP_ID => '188d002dd473d0707bcf01352fdbe4b7eb417d5299ac4c19dd426775fbe2a8e1',
    :APP_SECRET => '7ed3fb7bed55954dd142be207b05b789ebd635e46dea35193f16f0512143d37c',
    :APP_CALLBACK_URL => 'http://localhost:3001/',
    :SITE_BASE_URL => 'https://api-staging.6fusion.com/',
    :SITE_OAUTH_PATH => '/oauth/authorize',
    :USER_EMAIL => 'testorg@6fusiontest.com',
    :USER_PASSWORD => '1q2w!Q@W'
}
# Token: 51fc7d71ba241e9b0435ea72ca3ef73d77a512716d10a9500e25c4b1fc7be3fa

prod_test_acct = {
    :NAME => "6fusion Prod",
    :LOCAL_TEST_URI => 'urn:ietf:wg:oauth:2.0:oob',
    :APP_ID => 'b88c0d556a27b26ca5d1ffcd8f0b1b6447dcd28de8506974ab9dca37377a48a8',
    :APP_SECRET => '29eaae133bcff7507594b4c9d83a7d261cb70be78f6d3caca63f2a3b36cdab8c',
    :APP_CALLBACK_URL => 'http://localhost:3001/',
    :SITE_BASE_URL => 'https://api.6fusion.com/',
    :SITE_OAUTH_PATH => '/oauth/authorize',
    :USER_EMAIL => 'bsteinbeiser@6fusion.com',
    :USER_PASSWORD => 'b0b56Fc0de'
}
# Token: 85f643f5b49b1e89b8dcf020f0e81d9dfea99148f4340e5cc0ff1a1887b1bad5

Auth_params = uc6admin

# To colorize log output
class String
    def red;    "\033[31m#{self}\033[0m" end
    def green;  "\033[32m#{self}\033[0m" end
end

# Save the test data yaml file
def save_yaml(filename)
  File.open(filename, 'w') { |f| f.write Setup::Test_data.to_yaml }
end

# Extract and verify contract id from a link
def extract_id(self_link, type)
  link = self_link.match(/#{type}\/(?<id>\d+)/)
  id = link['id']
  # Verify id is a valid non-zero number
  #puts "    #{type} ID#: #{id}    (extract_id:)"
  #expect(id).to match (/[1-9]+/)
  return id
end

# Attempt to debug request exceptions
def check_exception(example)
  if example.exception
      message = JSON.parse(response.body)["message"]

      if message.nil?
        puts "ERROR! (No message returned)"
      else
        puts "ERROR! MESSAGE: '#{message}'"
      end
      
      unless @params.nil?
        puts "Params: "
        ap @params
      end
  end
end

# Verify format of uuid using a regex pattern
#def verify_uuid(uuid)
#    uuid =~ /^[a-f0-9]{8}(-[a-f0-9]{4}){3}-[a-f0-9]{12}$/
#end

# Replace ':id' key with ':_links' in a test data element keys array
def format_keys(keys)
    # Change first element (:id) to :_links
    keys[0] = :_links
    #print "format_keys: keys ="
    #ap keys
    return keys
end

# Get an oauth token
def get_token(params)
    require 'rest_client'
    require 'oauth2'
    require 'nokogiri'

    client = OAuth2::Client.new(params[:APP_ID], params[:APP_SECRET], 
        :site => "#{params[:SITE_BASE_URL]}#{params[:SITE_OAUTH_PATH]}")
    #puts "-- Getting a valid authenticity_token from login page"
    info = RestClient.get("#{params[:SITE_BASE_URL]}/sign_in", :accept => :html)
    cookies = info.cookies

    doc = Nokogiri::HTML(info.body)
    auth_token = doc.css("input[name='authenticity_token']").first.attributes['value'].content
    begin
      response = RestClient.post("#{params[:SITE_BASE_URL]}/", {:url => '/', :authenticity_token => auth_token,
        'user[email]' => params[:USER_EMAIL], 'user[password]' => params[:USER_PASSWORD]}, {
        :cookies => cookies, :accept => :html})
    rescue => e
    # THIS LOGIN SHOULD BE A REDIRECT, AS THE LOGIN IS SUCCESSFUL
    cookies = e.response.cookies
    end

    #puts "-- User is now logged into its account"
    authorize_url = client.auth_code.authorize_url(:redirect_uri => params[:APP_CALLBACK_URL])
    #puts "-- Authorizing the user using: #{authorize_url.inspect}"
    oauth_client_token = nil
    authorization_page = nil

    authorization_page = RestClient.get(authorize_url, :accept => :html, :cookies => cookies) do |response, request, result|
      doc = Nokogiri::HTML(response.body)
      if response.code == 302
        # HAPPY PATH HERE (We already have a valid token from external URL)
        oauth_client_token = doc.css('a').first.attributes['href'].content.to_s.split('=').last
      else
        if doc.at_css('code#authorization_code')
          # HAPPY PATH HERE (We already have a valid token)
          #puts "-- Getting the information as token already exists"
          oauth_client_token = doc.css('code#authorization_code').first.content
        else
          begin
            auth_token = doc.css("input[name='authenticity_token']").first.attributes['value'].content
            redirect_uri = doc.css('input#redirect_uri').first.attributes['value'].content
            response_type = doc.css('input#response_type').first.attributes['value'].content
            scope = doc.css('input#scope').first.attributes['value'].content
            commit = 'Authorize'
          rescue
            puts "!!!! ERROR FOUND ON AUTHENTICATION! see below the HTML FOUND: \n"
            puts "HTML error message: #{Nokogiri::HTML(response.body).css("main").text}\n"
          end
          if redirect_uri == params[:LOCAL_TEST_URI]
            begin
              RestClient.post(authorize_url, { auth_token: auth_token, redirect_uri: redirect_uri,
                response_type: response_type, scope: scope, commit: commit},
              { :cookies => cookies, :accept => :html})
            rescue => e
              doc = Nokogiri::HTML(e.response.body)
              oauth_client_token = doc.css('a').first.attributes['href'].content.to_s.split('/').last
            end
          else
            begin
              RestClient.post(authorize_url, { auth_token: auth_token, redirect_uri: redirect_uri,
                response_type: response_type, scope: scope, commit: commit},
              { :cookies => cookies, :accept => :html})
            rescue => e
              puts "Response: #{e.response.inspect}"
              doc = Nokogiri::HTML(e.response.body)
              oauth_client_token = doc.css('a').first.attributes['href'].content.to_s.split('=').last
            end
          end
        end
      end
    end

    #puts "-- Using Grant token #{oauth_client_token}"
    token = client.auth_code.get_token(oauth_client_token, :redirect_uri => params[:APP_CALLBACK_URL])
    #puts "=== Access granted! please use the following token: #{token.token.inspect}"
    return token.token
end

