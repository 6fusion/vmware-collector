#### Common UC6 api related stuff ####

require 'time_difference'

# Set default for 'limit' url param to eliminate any paging of the api response
Default_resp_limit = 1000

Default_apiurl = 'https://api-staging.6fusion.com'
# Default_user = 'uc6admin@6fusion.com',
# Default_passwd = 'may the schwartz be with you'
Default_user = 'test@example.com'
Default_passwd = 'testuser'

# Constants
Org=0; Inf=1; Mach=2;
Base_url = "#{Default_apiurl}/api/v2"
Auth_params = {
    :NAME =>        '6fusion Staging',
    :APP_ID =>      '188d002dd473d0707bcf01352fdbe4b7eb417d5299ac4c19dd426775fbe2a8e1',
    :APP_SECRET =>  '7ed3fb7bed55954dd142be207b05b789ebd635e46dea35193f16f0512143d37c',
    :OAUTH_URL =>   "#{Default_apiurl}/oauth/authorize",
#    :USER_EMAIL =>  Default_user,
#    :USER_PASSWD => Default_passwd,
    :SCOPE => 'admin_organization'
#    :SCOPE => 'manage_meters'
}

Token_file = ".UC6Token"
Token_expire_time = 59

# Process to reuse oauth tokens saved locally.  Saves time on repetitive runs.
# Check if a token file exists
def saved_token(auth_params, quiet)
    if File.exists?(Token_file)   
        file = File.open(Token_file, "r")
        oauth_token = file.gets
        #puts "File time: #{file.mtime}, Now: #{Time.now}"
        token_age = TimeDifference.between(file.mtime, Time.now).in_minutes
        file.close

        if token_age > Token_expire_time
            STDERR.puts "Saved token is #{token_age} minutes old, getting a new one"
           file = File.open(Token_file, "w+")
            oauth_token = get_token(auth_params)
            file.write(oauth_token)
            file.close
        else
            if quiet == false
                STDERR.puts "Using a saved token #{token_age} minutes old"
            end
        end
    else
        if quiet == false
           STDERR.puts "Creating new token file (#{Token_file})"
        end
        oauth_token = get_token(auth_params)
        File.write(Token_file, oauth_token)
    end
    return oauth_token
end

# To colorize log output
class String
    def red;    "\033[31m#{self}\033[0m" end
    def green;  "\033[32m#{self}\033[0m" end
end

# Extract a remote id from a self link
def extract_id(self_link, type)
  link = self_link.match(/#{type}\/(?<id>\d+)/)
  id = link['id']
end

# Get an oauth token for access to UC6 API based on Auth_params
def get_token (params)
    client = OAuth2::Client.new(params[:APP_ID], params[:APP_SECRET], :site => params[:OAUTH_URL])

    begin
        token = client.password.get_token(params[:USER_EMAIL], params[:USER_PASSWD], :scope => params[:SCOPE]).token
    rescue => e
        puts "Error: Can't get oauth token, check credentials for '#{params[:NAME]}'"
        puts "#{e.message}"
        abort "Aborting script"
    end
    return token
end

# Get url based on token, endpoint and params
def get_url (token, endpoint, url_params)

    # Build url param string from passed hash
    url_params["access_token"] = token
    params = ".json?"
    url_params.each do |key,value|
        if value != ''
            params = params + key + "=" + value + "&"
        end
    end

    req_url = Base_url + endpoint + params
    #puts"URL: #{req_url}"

    # GET request from API
    begin
        response = RestClient.get req_url
    rescue => e
        puts "  #{JSON.parse(e.response)["message"]}  (#{e.message})".red
        #puts e.backtrace
        abort "Aborting!"
    end
    # Convert JSON response to a hash using symbols
    resp_hash = JSON.parse(response, symbolize_names: true)

    # If there is a 'next' link then there is more data, warn user of this
    if resp_hash[:_links][:next] != nil
        puts "WARNING!: All response data may not be shown, increase 'limit' setting".red
    end
    
    return resp_hash    
end

# Get all disks related to a machine
def get_disks(token, disks_url)
    disk_ids = Array.new 
    endpoint = disks_url.scan(/\/organizations.*disks/)
    resp_hash = get_url(token, endpoint[0], {})
    resp_hash[:embedded][:disks].each do |disk|
        disk_ids.push extract_id(disk[:_links][:self][:href], 'disks')
    end
    return [disk_ids, resp_hash]
end

# Get all nics related to a machine
def get_nics(token, nics_url)
    nic_ids = Array.new 
    endpoint = nics_url.scan(/\/organizations.*nics/)
    resp_hash = get_url(token, endpoint[0], {})
    resp_hash[:embedded][:nics].each do |nic|
        nic_ids.push extract_id(nic[:_links][:self][:href], 'nics')
    end
    return nic_ids, resp_hash
end

# Add midnight and current hour (in UTC 8601 format) for current day/time to url params
# to get all hourly readings so far today.
def add_hourly_params()

    current_utc_hour = Time.now.utc.strftime("%H").to_i

    if current_utc_hour > 0
        last_utc_hour = current_utc_hour - 1
    end

    myhash = Hash.new
    myhash["since"] = Time.now.utc.strftime("%Y-%m-%dT00:00:00Z")
    myhash["hours"] = last_utc_hour.to_s

    return myhash
end
