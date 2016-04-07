FactoryGirl.define do
  factory :host do
    name 'Basic Host 1'
    platform_id 'Uniq-Host-Id-1'
    cpu_cores 4
    memory 1000
    cpu_hz 2000
    sockets 4
    threads 2
    inventory []
    nics []
  end
end
