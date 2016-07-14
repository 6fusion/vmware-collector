#!/usr/bin/env ruby
# Script to easily get some common stuff from the OnPrem API
# 5/7/15 Bob S.

require 'rest-client'
require 'trollop'
require 'pry'
require 'oauth2'
require_relative 'on_premapi'; # Note: Auth params, constants and methods are set here

opts = Trollop.options do 
    banner <<-EOS

on_premapi_get:  Get stuff from OnPrem API
Usage:
    ruby on_premapi_get.rb [options]

(Note: API auth params are hard coded for #{Default_apiurl})

Where [options] are:
EOS
    # Don't use a -n option, doesn't seem to work on short form?
    opt :type, 'endpoint type [required] (org, org-mach, inf, mach, meter, reading, inf-reading)', :type => :string, :required => true
    opt :id, 'id path to endpoint (ex: "-i 1 2 3" for org: 1, inf: 2, mach: 3)', type: :ints
    opt :all, 'get all (default: one)'
    opt :user, 'API user email', :default => Default_user
    opt :password, 'API user password', :default => Default_passwd
    opt :url, 'API url', :default => Default_apiurl
    opt :show_token, 'Show OnPrem token used (default: dont show)'
    opt :col_header, 'Don`t show column header (default: show header)', :default => false
    opt :day, 'Hourly readings so far today for all full hours (readings related endpoints only)'
    opt :limit, "Response limit", :default => Default_resp_limit
    opt :order, "Sort by name (org, inf, mach, meter only) (default: sort by id)"
    opt :count, "Only output a count of the response objects (default: output all response data)(requires option 'all')"
    opt :quiet, "Supress helpful messages (ie: token life, etc.)"
end

Auth_params[:OAUTH_URL] =   "#{opts[:url]}/oauth/authorize"
Auth_params[:USER_EMAIL] =  opts[:user]
Auth_params[:USER_PASSWD] = opts[:password]

#### Main ####

# Reuse oauth tokens saved locally.  Saves time on repetitive runs.
oauth_token = saved_token(Auth_params, opts[:quiet])

if opts[:show_token]
    STDERR.puts "OnPrem API Token: #{oauth_token}"
end

# URL Params list for API request
urlParams = {
    "fields" => '',
    "limit" => opts[:limit].to_s
}

# Validate input, define endpoint path
case opts[:type]
    when /org-mach/i
        if opts[:id].nil? or opts[:id].length < 1
            abort "Error, incorrect id path for organization. Must specify the org id"
        end
        endpoint = "/organizations/#{opts[:id][0]}/machines"
        opts[:all] = true
        
    when /org/i
        endpoint = "/organizations"
        if opts[:all] == false
            if opts[:id].nil? or opts[:id].length < 1
                abort "Error, incorrect id path for organization. Must specify the org id (or --all)"
            end
            endpoint.concat("/#{opts[:id][0]}")
            urlParams.delete("limit")
         end

    when /inf-read/i
        if opts[:id].nil? or opts[:id].length < 2
            abort "Error, incorrect id path for infrastructure-readings. Must specify the org and inf id"
        end

        endpoint = "/organizations/#{opts[:id][0]}/infrastructures/#{opts[:id][1]}/readings"

        if opts[:day]
            urlParams.merge(add_hourly_params())
        end

    when /inf/i
        if opts[:id].nil?
            abort "Error, incorrect id path for infrastructure. Must specify the org id"
        end
        endpoint = "/organizations/#{opts[:id][0]}/infrastructures"

        if opts[:all] == false
            if opts[:id].nil? or opts[:id].length < 2
                abort "Error, incorrect id path for infrastructure. Must specify the org and inf ids (or org, inf --all)"
            end
            endpoint.concat("/#{opts[:id][1]}")
            urlParams.delete("limit")
        end

    when /mach/i
        if opts[:id].nil? or opts[:id].length < 2
            abort "Error, incorrect id path for machine. Must specify the org and inf ids"
        end

        endpoint = "/organizations/#{opts[:id][0]}/infrastructures/#{opts[:id][1]}/machines"

        # If we only want a count, speed up the response a bit by limiting the fields returned to just 'name'
        if opts[:count]
            urlParams["fields"] =  "name"
        end
        
        if opts[:all] == false
            if opts[:id].nil? or opts[:id].length < 3
                abort "Error, incorrect id path for machine. Must specify the org, inf and mach ids (or org, inf, mach --all)"
            end
            endpoint.concat("/#{opts[:id][2]}")
            urlParams.delete("limit")
        end

    when /read/i
        if opts[:id].nil? or opts[:id].length < 3
            abort "Error, incorrect id path for machine reading. Must specify the org, inf and mach ids"
        end

        endpoint = "/organizations/#{opts[:id][0]}/infrastructures/#{opts[:id][1]}/machines/#{opts[:id][2]}/readings"

        if opts[:day]
            urlParams = urlParams.merge(add_hourly_params())
        end

    when /meter/i
        if opts[:id].nil? or opts[:id].length < 1
            abort "Error, incorrect id path for meter. Must specify the org id"
        end
        endpoint = "/organizations/#{opts[:id][0]}/meters"

    else
        abort "Error: endpoint type not found: #{opts[:type]}"
end

#puts "Endpoint: #{endpoint}"

#### Get the endpoint data ######

resp_hash = get_url(oauth_token, endpoint, urlParams)

##### Display the endpoint data #####

# Note: order is significant for this case structure!
case endpoint
    when /readings/
        line_format = "%-4s%-4s%-8s%-22s%-22s%-8s%-8s%-8s%-8s%-8s%-8s%-8s"        
        if opts[:col_header] == false
            if opts[:count] == false
                puts sprintf(line_format, 'Org','Inf','Mach',
                    'Start Date','End Date', 'CPU','Mem','D-IO','Lan-IO','Wan-IO','Disk', 'WACs').green
            else
                puts sprintf("%-10s", 'Response Object Count').green
            end    
        end    

        if opts[:count] == false
            resp_hash[:embedded][:readings].each do |reading|
                puts sprintf(line_format, opts[:id][Org],opts[:id][Inf],opts[:id][Mach],reading[:reading_start_date],
                 reading[:reading_end_date],reading[:cpu_mhz],reading[:memory_megabytes],reading[:disk_io_kilobytes],
                 reading[:lan_io_kilobits],reading[:wan_io_kilobits],reading[:storage_gigabytes],reading[:consumption_wac])
            end
        else        
            puts resp_hash[:embedded][:readings].length       
        end    

    when /machines/
        line_format = "%-5s%-5s%-7s%-30s%-8s%-18s%-12s%-12s%-20s%-20s"
        if opts[:col_header] == false
            if opts[:count] == false
                puts sprintf(line_format, 'Org','Inf','Id',
                    'Name','CPU-Cnt','CPU-Mhz','Memory','Status','Disks','Nics').green
            else
                puts sprintf("%-10s", 'Response Object Count').green
            end    
        end
        
        if opts[:order]
            resp_hash[:embedded][:machines].sort_by! {|n| n[:name]}
        end
           
        if opts[:all]
            if opts[:count] == false
                resp_hash[:embedded][:machines].each do |mach|
                    id = extract_id(mach[:_links][:self][:href], 'machines')
                    # Get disks & nics for this machine
                    #disks, resp = get_disks(oauth_token, mach[:_links][:disks][:href])
                    #nics, resp = get_nics(oauth_token, mach[:_links][:nics][:href])
                    disks = ["?"]; nics = ["?"]
                    puts sprintf(line_format, opts[:id][Org],opts[:id][Inf],id,mach[:name],mach[:cpu_count],
                        mach[:cpu_speed_mhz],mach[:maximum_memory_bytes],mach[:status],disks.join(","),nics.join(","))
                    #sleep(2) 
                end
            else
                puts resp_hash[:embedded][:machines].length       
            end         
        else
            puts sprintf(line_format, opts[:id][Org],opts[:id][Inf],opts[:id][Mach],resp_hash[:name],resp_hash[:cpu_count],
                resp_hash[:cpu_speed_mhz],resp_hash[:maximum_memory_bytes],resp_hash[:status],"see below","see below\n")

            # Print details for each disk
            line_format = "%-10s%-7s%-22s%-8s%-18s%-2s"
            if opts[:col_header] == false
                puts sprintf(line_format, 'Disks','Id','Name','Type','Max bytes','Status').green
            end

            disks, resp = get_disks(oauth_token, resp_hash[:_links][:disks][:href])
            if disks.empty?
                    puts ' none'
            else
                resp[:embedded][:disks].each do |disk|
                    id = extract_id(disk[:_links][:self][:href], 'disks')
                    puts sprintf(line_format, '',id,disk[:name],disk[:type],disk[:maximum_size_bytes],disk[:status])
                end
            end
            puts

            # Print details for each nic
            line_format = "%-10s%-7s%-22s%-8s%-18s%-20s%-9s"
            if opts[:col_header] == false
                puts sprintf(line_format, 'NICs','Id','Name','Kind','IP Address','MAC Address','Status').green
            end

            nics, resp = get_nics(oauth_token, resp_hash[:_links][:nics][:href])
            if nics.empty?
                    puts ' none'
            else
                resp[:embedded][:nics].each do |nic|
                    id = extract_id(nic[:_links][:self][:href], 'nics')
                    puts sprintf(line_format, '',id,nic[:name],nic[:kind],nic[:ip_address],nic[:mac_address],nic[:status])
                end
            end
            puts

            # # Print details for each disk & nic
            # disks, resp = get_disks(resp_hash[:_links][:disks][:href])
            # resp[:embedded][:disks].each do |disk|
            #     id = extract_id(disk[:_links][:self][:href], 'disks')
            #     puts "Disk: #{id}"
            # end

            # nics, resp = get_nics(resp_hash[:_links][:nics][:href])
            # resp[:embedded][:nics].each do |nic|
            #     id = extract_id(nic[:_links][:self][:href], 'nics')
            #     puts "Nic: #{id}"
            # end
        end    

    when /meter/
        line_format = "%-6s%-32s%-12s%-10s%-8s%-25s%-12s"
        if opts[:col_header] == false
            puts sprintf(line_format, 'Org','Name','Kind','Version','Enabled','Last Processed','Status').green
        end

        if opts[:order]
            resp_hash[:embedded][:meters].sort_by! {|n| n[:name]}
        end
           
        resp_hash[:embedded][:meters].each do |meter|
            id = extract_id(meter[:_links][:self][:href], 'vmware_meters')
            puts sprintf(line_format, id,meter[:name],meter[:kind],meter[:release_version],meter[:enabled],
                meter[:last_processed_on],meter[:status])
        end

    when /infrastructures/
        line_format = "%-6s%-6s%-25s%-8s%-40s"
        if opts[:col_header] == false
            puts sprintf(line_format, 'Org','Inf','Name','Status','Tags').green
        end

        if opts[:order]    
            resp_hash[:embedded][:infrastructures].sort_by! {|n| n[:name]}
        end

        if opts[:all]
            resp_hash[:embedded][:infrastructures].each do |inf|
                id = extract_id(inf[:_links][:self][:href], 'infrastructures')
                puts sprintf(line_format, opts[:id][Org],id,inf[:name],inf[:status],inf[:tags])
            end
        else
             puts sprintf(line_format, opts[:id][Org], opts[:id][Inf],resp_hash[:name],resp_hash[:status],resp_hash[:tags])
        end    

    when /organizations/
        line_format = "%-6s%-40s%-8s%-20s%-20s"
        if opts[:col_header] == false
            puts sprintf(line_format, 'Org','Name','Status','Phone','Fax').green
        end

        if opts[:order]    
            resp_hash[:embedded][:organizations].sort_by! {|n| n[:name]}
        end

        if opts[:all]
            resp_hash[:embedded][:organizations].each do |org|
                id = extract_id(org[:_links][:self][:href], 'organizations')
                puts sprintf(line_format, id,org[:name],org[:status],org[:phone],org[:facsimile])
            end
        else
            puts sprintf(line_format, opts[:id][Org],resp_hash[:name],resp_hash[:status],resp_hash[:phone],resp_hash[:facsimile])
        end    

    else
        abort "Endpoint type not found?"
end

