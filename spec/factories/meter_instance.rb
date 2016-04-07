FactoryGirl.define do
  factory :meter_instance do
    remote_id nil
    enabled true
    name 'Basic Meter Instance 1'
    status 'online'
    vcenter_server 'basic_vcenter_server' # What should this be?
  end
end
