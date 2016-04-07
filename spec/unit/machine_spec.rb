require 'spec_helper'
require 'machine'

# The matching is only part not hitting vSphere and good for unit test
# Rather than mock/stub, will test rest of Machine as integration test

# !!! Todo: Re-work these tests
describe "Machine" do
  describe "#matches?(other)" do
    xit "matches itself" do
      expect(machine.matches?(machine)).to eq(true)
    end

    xit "doesn't match if other's machine attributes are different" do
      other = machine.clone
      other.name = "new name"
      expect(machine.matches?(other)).to eq(false)
    end

    # Need to restructure data building to avoid need for cloning
    xit "doesn't match if other's disk attributes are different" do
      other = machine.clone
      disk1 = other.disks.first
      disk1.size = 42

      expect(machine.matches?(other)).to eq(false)
    end

    # Remember ip_address is not handled by match for NIC
    xit "doesn't match if other's nic attributes are different" do
      other = machine.clone
      nic1 = other.nics.first
      nic1.mac_address = 'some new mac address'

      expect(machine.matches?(other)).to eq(false)
    end

    # IP Address is not in the nic_attributes because it comes from the VM guest hardware devices IP
    # So, make sure it is included in the matching
    xit "doesn't match if other's nic ip_address is different" do
      other = machine.clone
      nic1 = other.nics.first
      nic1.ip_address = 'some new mac ip address'

      expect(machine.matches?(other)).to eq(false)
    end
  end
end
