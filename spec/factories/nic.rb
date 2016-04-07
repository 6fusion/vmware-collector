# Not using this now -- Infrastructure host's use plain Hashs for Nic data
FactoryGirl.define do
  factory :nic do
    remote_id nil
    platform_id 'nic-1'
    record_status 'created'
    name 'nic-1'
    kind 'lan'
    ip_address '123'
    mac_address '456'
  end
end
