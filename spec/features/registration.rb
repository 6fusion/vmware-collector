require 'feature_helper'
require 'registration'
require 'machine'
using RbVmomiExtensions

describe "Registration" do
  DATA_CENTER_NAME = 'DC-Main'

  before do
    DatabaseCleaner.clean
    @vm1 = create_vm('test_reg_on_on_prem', DATA_CENTER_NAME)
    @vm2 = create_vm('test_reg_not_on_on_prem', DATA_CENTER_NAME)
  end

  after do
    DatabaseCleaner.clean
    destroy_vm('test_reg_on_on_prem')
    destroy_vm('test_reg_not_on_on_prem')
  end

  it "maps OnPrem inventory to vSphere inventory" do
    # Create two machines locally -- simulate machines from OnPrem connector
    on_prem_machine_with_vsphere = Machine.create(name: 'test_reg_on_on_prem')
    on_prem_machine_no_vsphere = Machine.create(name: 'test_reg_on_on_prem_no_vsphere')

    # Map platform_id from vSphere to local (from OnPrem)
    Registration::initialize_platform_ids

    on_prem_machine_with_vsphere.reload
    on_prem_machine_no_vsphere.reload

    on_prem_machine_with_vsphere.platform_id.must_equal(@vm1.moref)
    on_prem_machine_no_vsphere.platform_id.must_equal(nil)

    Machine.where(name: 'test_reg_not_on_on_prem').must_equal([])
  end
end
