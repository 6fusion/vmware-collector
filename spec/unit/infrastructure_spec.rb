require 'spec_helper'
require 'infrastructure'

describe "Infrastructure" do

  subject { FactoryGirl.build(:infrastructure) }

  describe "scopes" do
    it ".to_be_created_or_updated returns correct records" do
      FactoryGirl.create(:infrastructure, record_status: 'created')
      FactoryGirl.create(:infrastructure, record_status: 'updated')
      FactoryGirl.create(:infrastructure, record_status: 'deleted')
      FactoryGirl.create(:infrastructure, record_status: 'disabled')
      FactoryGirl.create(:infrastructure, record_status: 'verified')

      expect(Infrastructure.to_be_created_or_updated.size).to eq(2)
    end

    it ".enabled returns correct records" do
      inf_enabled = FactoryGirl.create(:infrastructure,
                                       meter_instance: FactoryGirl.build(:meter_instance,
                                                                         enabled: true))
      inf_disabled = FactoryGirl.create(:infrastructure,
                                       meter_instance: FactoryGirl.build(:meter_instance,
                                                                         enabled: false))
      expect(Infrastructure.enabled.size).to eq(1)
    end
  end


  describe "#api_format" do
    it "returns hash of correct key value pairs" do
      # This information is just stored as Mongo Doc in Console for now but not used
      # Eventually we will use this data
      expect(subject.api_format).to eq({:name=>"Basic Infrastructure 1",
                                        :summary=> { :hosts=>2,
                                                     :networks=>2,
                                                     :volumes=>0,
                                                     :sockets=>8,
                                                     :cores=>8,
                                                     :threads=>4,
                                                     :speed_mhz=>4000,
                                                     :memory_bytes=>2000,
                                                     :storage_bytes=>0,
                                                     :lan_bandwidth_mbits=>0,
                                                     :wan_bandwidth_mbits=>0 },
                                        :hosts=>[ { :uuid=>nil,
                                                    :cluster=>nil,
                                                    :cpu_speed_hz=>2000,
                                                    :cpu_model=>nil,
                                                    :cores=>4,
                                                    :sockets=>4,
                                                    :threads=>2,
                                                    :memory_bytes=>1000,
                                                    :vendor=>nil,
                                                    :model=>nil,
                                                    :os=>"VMware ESXi",
                                                    :os_version=>nil,
                                                    :cpus=>nil,
                                                    :host_bus_adapters=>nil,
                                                    :nics=>[] },
                                                  { :uuid=>nil,
                                                    :cluster=>nil,
                                                    :cpu_speed_hz=>2000,
                                                    :cpu_model=>nil,
                                                    :cores=>4,
                                                    :sockets=>4,
                                                    :threads=>2,
                                                    :memory_bytes=>1000,
                                                    :vendor=>nil,
                                                    :model=>nil,
                                                    :os=>"VMware ESXi",
                                                    :os_version=>nil,
                                                    :cpus=>nil,
                                                    :host_bus_adapters=>nil,
                                                    :nics=>[] }
                                                ],
                                        :networks=>[ { :name=>"generic network name 1",
                                                       :kind=>"LAN" },
                                                     { :name=>"generic network name 1", :kind=>"LAN" }
                                                   ],
                                        :volumes=>[]
                                       })

    end
  end


  describe "(private)#infrastructure_total and #total_*" do
    # Build Inf with 2 hosts Here (Easy to see expected totals)
    let(:inf_with_hosts) do
      host_1 = build(:host, cpu_cores: 2, memory: 1500, cpu_hz: 2000)
      host_2 = build(:host, cpu_cores: 4, memory: 2000, cpu_hz: 3000)
      infrastructure = build(:infrastructure)
      infrastructure.hosts = [host_1, host_2]
      infrastructure
    end

    it "has correct (private) #infrastructure_total" do
      expect(inf_with_hosts.send(:infrastructure_totals)).to eq({ cpu_cores: 6,
                                                                  cpu_mhz: 5000,
                                                                  memory: 3500,
                                                                  lan_bandwidth_mbits: 0,
                                                                  sockets: 8,
                                                                  threads: 4
                                                                })
    end

    it "has correct #total_server_count" do
      expect(inf_with_hosts.total_server_count).to eq(2)
    end

    it "has correct #total_cpu_cores" do
      expect(inf_with_hosts.total_cpu_cores).to eq(6)
    end

    it "has correct #total_cpu_mzh" do
      expect(inf_with_hosts.total_cpu_mhz).to eq(5000)
    end

    it "has correct #total_memory" do
      expect(inf_with_hosts.total_memory).to eq(3500)
    end
  end


  describe "#item_matches?(other)" do
    it "uses correct #attribute_map" do
      # Note: attribute_maps are used by classes that include Matchable
      expect(subject.attribute_map).to eq({name: :name})
    end

    # !!! Note: item_matches?(other) currently doesn't check relations
    # Need to decide if we want item_matches? to check relations, or use item_matches? and relations_match for same check
    # item_matches used to check that attributes_match? and relations_match? ... Not, it's just a wrapper
    # for attributes_match?
    it "matches itself" do
      expect(subject.item_matches?(subject)).to eq(true)
    end

    xit "doesn't match if other's machine attributes are different" do
      inf_other_mach_attrs = FactoryGirl.build(:infrastructure, name: 'Different Name')
      expect(subject.item_matches?(inf_other_mach_attrs)).to eq(false)
    end

    xit "doesn't match if has network and other doesn't" do
      inf_no_networks = FactoryGirl.build(:infrastructure, networks: [])

      expect(subject.item_matches?(inf_no_networks)).to eq(false)
    end

    xit "doesn't match if other's network attributes are different" do
      # Note: Remember Network platform IDs are Integers (the device IDs in VSphere)
      inf_other_networks = FactoryGirl.build(:infrastructure,
                                             networks: [
                                               build(:network, platform_id: 100),
                                               build(:network, platform_id: 101)
                                             ])

      expect(subject.item_matches?(inf_other_networks)).to eq(false)
    end

    xit "doesn't match if has hosts and other doesn't" do
      inf_no_hosts = FactoryGirl.build(:infrastructure, hosts: [])

      expect(subject.item_matches?(inf_no_hosts)).to eq(false)
    end

    xit "doesn't match if other's host attributes are different" do
      inf_other_hosts = FactoryGirl.build(:infrastructure,
                                          hosts: [
                                            build(:host),
                                            build(:host, platform_id: 'different-platform-id')
                                          ])

      expect(subject.item_matches?(inf_other_hosts)).to eq(false)
    end
  end


  # #cpu_speed_for(vm_moref) could use refactoring
  describe "#cpu_speed_for" do
    let(:host_with_inventory_1) {
      host_with_inventory_1 = FactoryGirl.build(:host,
                                                platform_id: 'uniq-host-id-1',
                                                cpu_hz: 1000)
      vm_1 = FactoryGirl.build(:machine, platform_id: 'vm-1')
      vm_2 = FactoryGirl.build(:machine, platform_id: 'vm-2')
      host_with_inventory_1.inventory = [vm_1.platform_id, vm_2.platform_id]
      host_with_inventory_1
    }

    let(:host_with_inventory_2) {
      host_with_inventory_2 = FactoryGirl.build(:host,
                                                platform_id: 'uniq-host-id-2',
                                                cpu_hz: 2000)
      vm_3 = FactoryGirl.build(:machine, platform_id: 'vm-3')
      vm_4 = FactoryGirl.build(:machine, platform_id: 'vm-4')
      host_with_inventory_2.inventory = [vm_3.platform_id, vm_4.platform_id]
      host_with_inventory_2
    }

    let(:inf_with_host_inventory) {
      FactoryGirl.build(:infrastructure,
                        hosts: [host_with_inventory_1, host_with_inventory_2])
    }

    # #vm_to_host_map is used by cpu_speed_for
    it "#vm_to_host_map returns correct value" do
      expect(inf_with_host_inventory.vm_to_host_map).to eq({
         "vm-1" => host_with_inventory_1,
         "vm-2" => host_with_inventory_1,
         "vm-3" => host_with_inventory_2,
         "vm-4" => host_with_inventory_2 })
    end
  end


  describe "#disable and #enabled? (infrastructure's meter_instance')" do
    # Currently, Infrastructure does not support enabling / re-enabling an Infrastructure
    # Simple to add when needed though...
    it "allows disabling the infrastructure (disables its meter_instance" do
      # Note: Infrastructure factory defaults to meter_instance factory with enabled true
      expect(subject.enabled?).to eq(true)
      subject.disable
      expect(subject.enabled?).to eq(false)
    end
  end


  # Ensure "inventoriability" remains intact
  describe "InfrastructureInventory" do
    xit 'can be updated' do
      inventory[subject.platform_id] = subject
      inventory.save
      expect(inventory[subject.platform_id].matches?(complete_infrastructure)).to eq(false)
      inventory[subject.platform_id] = complete_infrastructure
      expect(inventory[subject.platform_id].matches?(complete_infrastructure)).to eq(true)
    end
  end
end
