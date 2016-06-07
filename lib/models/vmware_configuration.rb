require 'mongoid'
require 'host'

class VmwareConfiguration
  include Mongoid::Document
  include Mongoid::Timestamps

  field :configured, type: Boolean
end
