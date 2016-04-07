# Script to run all other test scripts. Specify script on command line
#  Typical usage: SPEC="script_file" rspec -d documentation run_suite.rb
require_relative 'test_helpers'

RSpec.configure do |config|
  config.default_path = '~/Projects/vmware-meter/spec/system'
end

class Setup

    #Yaml_file = "spec/requests/api/v2/test_data.yml"
    #Test_data = Psych.load_file(Yaml_file)

    Airborne.configure do |config|
        #config.base_url = 'http://54.89.1.103:8080/api/v2'
        config.base_url = 'https://api-staging.6fusion.com/api/v2'
        #config.base_url = 'https://api.6fusion.com/api/v2'
    end

end

# All available test specs
api_specs = [
    'initial_tests',
    'post_readings_goog_sheet'
]

gui_specs = [
    'uc6_console_login',
    'watir-rails-test'
]

# Validate spec input file to run
if ENV["SPEC"].nil?
    puts "ERROR: No spec specified!"
    abort "Usage: SPEC='<spec file>' rspec run_suite.rb"
else
    this_spec = ENV["SPEC"] 
    puts "Spec: #{this_spec}"
end

if api_specs.include? this_spec 
    ### Define API related vars ###
    Setup::Token = get_token(Auth_params)
    puts "Server: #{Auth_params[:NAME]}, Token: #{Setup::Token}"
    require_relative this_spec
elsif 
    gui_specs.include? this_spec
    require_relative this_spec
else
    puts "Spec: #{ENV["SPEC"]} not found!"
end
