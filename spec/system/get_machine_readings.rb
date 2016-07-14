# Retrieves machine readings from OnPrem API

require 'rest-client'
require 'awesome_print'
require_relative 'test_helpers'

# Calculate a time in the past
hoursAgo = 1
tm = DateTime.now - (hoursAgo/24.0)
pastTime = Time.parse(tm.to_s).utc.iso8601


def get_mach_readings (org, inf, mach, urlParams)

    # Build url params
    params = ".json?"
    urlParams.each do |key,value|
        if value != ''
            params = params + key + "=" + value + "&"
        end
    end

    # Build request URL
    base_url = 'https://api-staging.6fusion.com/api/v2'
    endpoint = "/organizations/#{org}/infrastructures/#{inf}/machines/#{mach}/readings"
    req_url = base_url + endpoint + params

    puts "URL: #{req_url}"

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
org = '62'
inf = '74'
machines = [4213, 5325]

# URL Params list for API request
urlParams = {
    "access_token"  => get_token(Auth_params),
    "offset" => '',
    "limit"  => '1000',
    "fields" => '',
#    "since"  => '2015-03-30T00:00:00Z',
    "since"  => '',
    "until"   => '',
    "hours"  => '5',
    "days"   => '',
    "months" => '',
}

# Get readings for all machines
machines.each do |mach|

    resp_hash = get_mach_readings(org, inf, mach, urlParams)

    readingsCount = resp_hash[:embedded][:readings].length
    #ap resp_hash

    if readingsCount  > 0
        puts "Last: #{resp_hash[:embedded][:readings][-1][:reading_start_date]}"

        line_format = "%4s%4s%6s%22s%22s%8s%8s%8s%8s%8s%8s%8s"
        puts sprintf(line_format, 'Org','Inf','Mach',
            'Start Date','End Date', 'CPU','Mem','D-IO','Lan-IO','Wan-IO','Disk', 'WACs').green

        resp_hash[:embedded][:readings].each { |reading|
        puts sprintf(line_format, org,inf,mach,reading[:reading_start_date],
            reading[:reading_end_date],reading[:cpu_mhz],reading[:memory_megabytes],reading[:disk_io_kilobytes],
            reading[:lan_io_kilobits],reading[:wan_io_kilobits],reading[:storage_gigabytes],reading[:consumption_wac])

        }
    else
        puts "No Readings found for Org: #{org}, Inf: #{inf}, Machine: #{mach}".red
    end

end
