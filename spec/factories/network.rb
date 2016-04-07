FactoryGirl.define do
  factory :network do
    remote_id 1
    platform_id 1
    name 'generic network name 1'
    kind 'LAN'

    factory :private_network do
      name "Private Network"
      kind "LAN"
    end
    factory :public_network do
      name "Public Network"
      kind "WAN"
    end

  end
end
