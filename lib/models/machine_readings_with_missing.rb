require 'mongoid'

class MachineReadingsWithMissing
  include Mongoid::Document

  field :value, type: Hash
end
