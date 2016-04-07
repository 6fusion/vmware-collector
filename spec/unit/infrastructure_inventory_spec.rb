require 'spec_helper'
require 'infrastructure'
require 'local_inventory'

# InfrastructureInventory < MongoHash < Hash
describe "InfrastructureInventory" do
  # !!! Not sure why need to run DatabaseCleaner in these specs
  # Setup in spec_helper to run before each, but doesn't seem to work here...
  before(:each) { DatabaseCleaner.clean }
  after(:each) { DatabaseCleaner.clean }

  let(:infrastructure_inventory) { InfrastructureInventory.new }
  let(:inf_1) { FactoryGirl.build(:infrastructure, platform_id: 'plat_id_1', name: 'name_1') }
  let(:inf_2) { FactoryGirl.build(:infrastructure, platform_id: 'plat_id_2', name: 'name_2') }
  let(:inf_inv_updates) { infrastructure_inventory.instance_variable_get(:@updates) }

  describe "#[]=" do
    context "using platform_id as key" do
      before(:each) do
        # Create 2 items for more realistic inventory (rare have 1 item)
        infrastructure_inventory[inf_1.platform_id] = inf_1
        infrastructure_inventory[inf_2.platform_id] = inf_2
      end

      context "(before save)" do
        it "stores key/values in @updates" do
          expect(inf_inv_updates.find{|i| i.platform_id == inf_1.platform_id}).to eq(inf_1)
          expect(inf_inv_updates.find{|i| i.platform_id == inf_2.platform_id}).to eq(inf_2)
        end

        it "allows updating value for key" do
          inf_1.name = 'New Name Woo'
          infrastructure_inventory[inf_1.platform_id] = inf_1

          expect(inf_inv_updates.find{|i| i.platform_id == inf_1.platform_id}).to eq(inf_1)
          expect(inf_inv_updates.find{|i| i.platform_id == inf_2.platform_id}).to eq(inf_2)
        end

        it "shows size zero even with @updates" do
          expect(infrastructure_inventory.size).to eq(0)
        end
      end

      context "(after save)" do
        before(:each) { infrastructure_inventory.save }

        it "has correct count" do
          expect(infrastructure_inventory.size).to eq(2)
        end

        it "removes saved items from @updates" do
          expect(inf_inv_updates).to eq([])
        end

        it "has correct keys/values" do
          expect(infrastructure_inventory[inf_1.platform_id]).to eq(inf_1)
          expect(infrastructure_inventory[inf_2.platform_id]).to eq(inf_2)
        end

        context "updating value for key with attribute change" do
          before(:each) do
            inf_1.name = 'New Name Woo'
            infrastructure_inventory[inf_1.platform_id] = inf_1
          end

          let(:inf_1_inv) { infrastructure_inventory[inf_1.platform_id] }
          let(:inf_2_inv) { infrastructure_inventory[inf_2.platform_id] }

          describe "(in @updates)" do
            it "in @updates, has 1 update for inf with attribute change (name)" do
              expect(inf_inv_updates.size).to eq(1)
            end

            it "in @updates, stores updated key/value, ignores unchanged" do
              inf_1_inv_update = inf_inv_updates.find{|i| i.platform_id == inf_1.platform_id}
              inf_2_inv_update = inf_inv_updates.find{|i| i.platform_id == inf_2.platform_id}
              expect(inf_1_inv_update).to eq(inf_1)
              expect(inf_2_inv_update).to eq(nil)
            end
          end

          describe "(in inventory)" do
            it "has correct number infrastructures" do
              expect(infrastructure_inventory.size).to eq(2)
            end

            it "has correct infrastructures in inventory" do
              # Just check platform_id and name (may want to check more?)
              # Equality check seems to use _id, which doesn't recognize attributes
              expect(inf_1_inv.platform_id).to eq(inf_1.platform_id)
              expect(inf_1_inv.name).to eq(inf_1.name)
              expect(inf_2_inv.platform_id).to eq(inf_2.platform_id)
              expect(inf_2_inv.name).to eq(inf_2.name)
            end

            it "has correct record_status on each infrastructure in inventory" do
              expect(inf_1_inv.record_status).to eq('updated')
              expect(inf_2_inv.record_status).to eq('created')
            end
          end
        end
      end
    end

    # This test may not be necessary, but figure can't hurt because we use it this way (ie name)
    context "using alternate key" do
      it "'name' works fine" do
        inventory_using_name = InfrastructureInventory.new(key = :name)
        inventory_using_name[inf_1.name] = inf_1
        inventory_using_name.save

        expect(inventory_using_name[inf_1.name]).to eq(inf_1)
      end
    end
  end

  # !!! Todo: Finish testing this...
  describe "#filtered_items" do
    xit "excludes statuses 'deleted' and 'disabled'" do
      #inf_created = FactoryGirl.build(:infrastructure, platform_id: '1', status: 'created'
      #inf_deleted =
      #inf_disabled =
      #infrastructure_inventory[
    end
  end

end
