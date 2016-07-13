# Retrieves machine readings from OnPrem API

require 'rest-client'
require 'awesome_print'
require_relative 'test_helpers'

# Calculate a time in the past
hoursAgo = 1
tm = DateTime.now - (hoursAgo/24.0)
pastTime = Time.parse(tm.to_s).utc.iso8601


def get_machines (org, inf, urlParams)

    # Build url params
    params = ".json?"
    urlParams.each do |key,value|
        if value != ''
            params = params + key + "=" + value + "&"
        end
    end

    # Build request URL
    base_url = 'https://api-staging.6fusion.com/api/v2'
    endpoint = "/organizations/#{org}/infrastructures/#{inf}/machines"
    req_url = base_url + endpoint + params

    #puts "URL: #{req_url}"

    begin
        response = RestClient.get req_url
    rescue => e
        puts "  Error: #{e.message}".red
        #puts e.backtrace
        abort "Aborting!"
    end

    #puts "Response status: #{response.code}"

    # Convert JSON response to a hash using symbols
    resp_hash = JSON.parse(response, symbolize_names: true)
end

# Readings machine path
org = '70'
inf = '111'

# URL Params list for API request
urlParams = {
    "access_token"  => get_token(Auth_params),
    "tags" => '',
    "limit"  => '1000',
    "fields" => '',
    "offset" => '',
}

# Get all machines
resp_hash = get_machines(org, inf, urlParams)

#ap resp_hash
machinesCount = resp_hash[:embedded][:machines].length

if machinesCount  > 0
    #puts "Last: #{resp_hash[:embedded][:machines][-1][:name]}"

    line_format = "%4s%4s%6s%22s%22s%8s%13s%12s%12s%12s"
    puts sprintf(line_format, 'Org','Inf','Mach',
        'Name','Virtual Name','CPU-Cnt','CPU-Mhz','Memory','Status','Tags').green

    resp_hash[:embedded][:machines].each { |machine|
        # Get machine id from each 'self' link
        mach_id = extract_id(machine[:_links][:self][:href], 'machines')

        puts sprintf(line_format, org,inf,mach_id,machine[:name],"??",machine[:cpu_count],
            machine[:cpu_speed_mhz],machine[:maximum_memory_bytes],machine[:status],machine[:tags])
    }
else
    puts "No Machines found for Org: #{org}, Inf: #{inf}".red
end
