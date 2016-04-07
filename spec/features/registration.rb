require 'feature_helper'
require 'registration'
require 'machine'
using RbVmomiExtensions

describe "Registration" do
  DATA_CENTER_NAME = 'DC-Main'

  before do
    DatabaseCleaner.clean
    @vm1 = create_vm('test_reg_on_uc6', DATA_CENTER_NAME)
    @vm2 = create_vm('test_reg_not_on_uc6', DATA_CENTER_NAME)
  end

  after do
    DatabaseCleaner.clean
    destroy_vm('test_reg_on_uc6')
    destroy_vm('test_reg_not_on_uc6')
  end

  it "maps UC6 inventory to vSphere inventory" do
    # Create two machines locally -- simulate machines from UC6 connector
    uc6_machine_with_vsphere = Machine.create(name: 'test_reg_on_uc6')
    uc6_machine_no_vsphere   = Machine.create(name: 'test_reg_on_uc6_no_vsphere')

    # Map platform_id from vSphere to local (from UC6)
    Registration::initialize_platform_ids

    uc6_machine_with_vsphere.reload
    uc6_machine_no_vsphere.reload

    uc6_machine_with_vsphere.platform_id.must_equal(@vm1.moref)
    uc6_machine_no_vsphere.platform_id.must_equal(nil)

    Machine.where(name: 'test_reg_not_on_uc6').must_equal([])
  end
end
