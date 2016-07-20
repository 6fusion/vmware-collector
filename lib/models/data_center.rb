require 'mongoid'
require 'host'

class DataCenter
  include Mongoid::Document
  include Mongoid::Timestamps

  field :data_center_name, type: String

  embeds_many :hosts
  accepts_nested_attributes_for :hosts

  def self.build_from_vsphere_response(_attribute_set)
    infrastructure = Infrastructure.new

    # Not clear yet how going to get the attributes and how to split up

    # machine.assign_machine_attributes(attribute_set)
    # machine.assign_machine_disks(attribute_set[:disks])
    # machine.assign_machine_nics(attribute_set[:nics])
    machine
  end

  # May want to add a step to convert units properly
end
