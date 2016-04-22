FactoryGirl.define do
  factory :infrastructure do
    platform_id 'vm-1'
    remote_id nil
    name 'Basic Infrastructure 1'
    record_status 'created'
    tags nil

    hosts { [build(:host), build(:host, platform_id: 'uniq-id-2')] }
    # Note: Remember Network platform_ids are integers
    networks { [build(:network), build(:network, platform_id: 2)] }

    #factory :complete_infrastructure do
      #name 'Complete Infrastructure 1'
      #total_server_count 2
      #total_cpu_cores { 4 }
      #total_cpu_mhz { 4*2999 }
      #total_memory { 1024*8 }
      #networks { [ build(:public_network), build(:private_network) ] }
    #end
  end
end
