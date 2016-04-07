FactoryGirl.define do
  factory :machine do
    remote_id 1
    platform_id 'vm-1'
    name 'Basic VM'
    os 'Linux'
    virtual_name 'Basic virtual name'
    cpu_count 2
    cpu_speed_mhz 2000
    memory_bytes 1000
    status 'created'
    tags nil
    metrics {}
    submitted_at nil
    infrastructure_remote_id nil
    infrastructure_platform_id nil
    disks []
    nics []
  end
end
