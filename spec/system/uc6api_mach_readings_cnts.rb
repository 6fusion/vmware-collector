#!/usr/bin/env ruby
# Script to help reconcile large numbers of machine readings on a specific organization on UC6 API
# 5/7/15 Bob S.

require 'rest-client'
require 'trollop'
require 'pry'
require 'oauth2'
require_relative 'uc6api'; # Note: Auth params, constants and methods are set here 

opts = Trollop.options do 
    banner <<-EOS

uc6api_mach_readings_cnts:  Get readings for all machines in an organizations via the UC6 API
Usage:
    ruby uc6api_mach_readings_cnts.rb [options]

(Note: API auth params are hard coded for #{Default_apiurl})

Where [options] are:
EOS
    # Don't use a -n option, doesn't seem to work on short form?
    opt :org, 'organization id [required]', :type => :int, :required => true
    opt :inf, 'infrastructure id (default: all infrastructures)', :type => :string
    opt :daily, 'Show reading so far today for all full hours (default: show daily totals)'
    opt :user, 'API user email', :default => Default_user
    opt :password, 'API user password', :default => Default_passwd
    opt :since, 'Show readings since this date/time (format like: 2015-07-20T00:00:00Z) (overides daily option)', :type => :string
    opt :until, 'Show readings until this date/time (format like: 2015-07-20T00:00:00Z) (overides daily option)', :type => :string
end

Auth_params[:OAUTH_URL] =   "#{Default_apiurl}/oauth/authorize"

if opts[:user]
    Auth_params[:USER_EMAIL] =  opts[:user]
else
    Auth_params[:USER_EMAIL] =  Default_user
end

if opts[:password]
    Auth_params[:USER_PASSWD] = opts[:password]
else
    Auth_params[:USER_PASSWD] = Default_passwd
end

ThisOrg = opts[:org]

#### Main ####

# Always start with a new fresh token
oauth_token = get_token(Auth_params)

# URL Params list for API request
url_params = {
    "fields" => '',
    "limit" => Default_resp_limit.to_s
}

# Show all hourly readings so far today (instead of the default daily readings)
if opts[:daily]
    reading_hourly_params = url_params.merge(add_hourly_params())
else
    reading_hourly_params = url_params.clone
end

# Show readings 'since' option
if opts[:since]
    reading_hourly_params["since"] = opts[:since].to_s
end
# Show readings 'until' option
if opts[:until]
    reading_hourly_params["until"] = opts[:until].to_s
end

# Get all Infs for this Org
reading_cnts = Array.new
infs_endpoint = "/organizations/#{ThisOrg}/infrastructures"
inf_resp_hash = get_url(oauth_token, infs_endpoint, url_params)

inf_resp_hash[:embedded][:infrastructures].each do |inf|
    inf_id = extract_id(inf[:_links][:self][:href], 'infrastructures')

    # Show only the inf specified
    if opts[:inf]
        next if inf_id != opts[:inf]
    end

    # Get Machs for each Inf
    machs_endpoint = "/organizations/#{ThisOrg}/infrastructures/#{inf_id}/machines"
    machs_resp_hash = get_url(oauth_token, machs_endpoint, url_params)
    
    machs_resp_hash[:embedded][:machines].each do |mach|
        mach_id = extract_id(mach[:_links][:self][:href], 'machines')

        # Get reading counts for each Mach
        readings_endpoint = "/organizations/#{ThisOrg}/infrastructures/#{inf_id}/machines/#{mach_id}/readings"
        #puts reading_hourly_params
        readings_resp_hash = get_url(oauth_token, readings_endpoint, reading_hourly_params)
        reading_cnt = readings_resp_hash[:embedded][:readings].length
        reading_cnts.push ([inf_id,mach_id,reading_cnt])
        puts "Org: #{ThisOrg}, Inf: #{inf_id}, Mach: #{mach_id}, Reading Cnt: #{reading_cnt}"
    end
    #puts "Org: #{ThisOrg}, Inf: #{inf_id}, Machine Cnt: #{machs_resp_hash[:embedded][:machines].length}"
end
