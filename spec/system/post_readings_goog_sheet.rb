# Post UC6 machine readings from data in a google spread sheet

require 'roo'
require 'pry'

#https://docs.google.com/a/6fusion.com/spreadsheets/d/18Pjmhf6LWCH8ophmJA63E3jmeikyjPs2QleRBxOkT_s/edit?usp=sharing
# Setup your spreadsheet document key and credentials
key = "18Pjmhf6LWCH8ophmJA63E3jmeikyjPs2QleRBxOkT_s"
# NOTE:  This probably wont work after 5/5/15! 
#    https://developers.google.com/google-apps/spreadsheets/#about_authorization_protocols
user = 'bsteinbeiser@6fusion.com'
password = 'b0b56fusionc0de'

# Spreadsheet column data indexes
OrgId = 0;      InfId = 1;      MachId = 2;     RdTime = 3;
CpuPct = 4;     CpuMem = 5;     DiskId = 6;     DiskUsage = 7;  
DiskRd = 8;     DiskWt = 9;     Nic1Id = 10;    Nic1Tx = 11;     
Nic1Rx = 12;    Nic2Id = 13;    Nic2Tx = 14;    Nic2Rx = 15;

header_row = 6

# Open the google sheet
puts "\nOpening google sheet"
begin
    gsheet = Roo::Google.new(key, user: user, password: password)
rescue => e
    puts "  Error: opening google sheet: #{e.message}".red
    abort "Aborting script"
end

# Notes: LAN/WAN i/o readings are determined by the NIC.  A LAN nic is provisioned
# with 'kind=0', a WAN nic is provisioned with 'kind=1'
#
# After readings are sent to the API they are periodically rolled into 1 hour increments
# This takes some amount of time before the are available to be read/GET
# If the request doesn't specify a period (since/until params) only daily readings will
# be displayed.  Here are the period rules (from Rolando 1/20/15):
#   0 to 6 days = hourly,  7 to 90 days = daily, greater than 90 days = monthly
# Also new readings posted over 60 days old are ignored (need to verify?)

describe 'POST: Readings' do

    after(:each) do |example|
        check_exception(example)
    end

    gsheet.each_with_index do |row, index|

        # Get all non-blank rows below the header        
        if index > header_row and row[OrgId].to_i.zero? == false

            # Not sure why but occasionally readings get a '.0' appended. The .to_i added seems to fix this.
            params = {
                :disks => [ {
                    :id => row[DiskId].to_i,
                    :readings => [ {
                        :reading_at => row[RdTime],
                        :usage_bytes => row[DiskUsage].to_i,
                        :read_kilobytes => row[DiskRd].to_i,
                        :write_kilobytes => row[DiskWt].to_i
                    } ]
                } ],
                :nics => [ {
                    :id => row[Nic1Id].to_i,
                    :readings => [ {
                        :reading_at => row[RdTime],
                        :transmit_kilobits => row[Nic1Tx].to_i,
                        :receive_kilobits => row[Nic1Rx].to_i 
                        } ],
                },
                {
                    :id => row[Nic2Id].to_i,
                    :readings => [ {
                        :reading_at => row[RdTime],
                        :transmit_kilobits => row[Nic2Tx].to_i,
                        :receive_kilobits => row[Nic1Rx].to_i
                        } ]  
                } ], 
                :readings => [ {
                    :reading_at => row[RdTime],
                    :cpu_usage_percent => row[CpuPct],
                    :memory_bytes => row[CpuMem].to_i
                    } ]
            }    
 
            it "Posting reading at row #{index}" do
                @params = params
                path = "/organizations/#{row[OrgId].to_i}/infrastructures/#{row[InfId].to_i}/machines/#{row[MachId].to_i}/readings"
                #puts "URL: #{Base_url}#{path}"
                #ap params
                post "#{path}.json?synchronize=yes&access_token=#{Setup::Token}", params
                expect_status(202)
            end
        end
    end
end
