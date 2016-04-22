require 'matchable'

class PlatformRemoteId
  include Mongoid::Document
  include Mongoid::Timestamps
  include Matchable

  # example
  # platform_key: infrastructure_platform_id/machine_platform_id
  # remote_id is the machine's remote_id

  # platform_key: infrastructure_platform_id/machine_platform_id/disk_platform_id
  # remote_id is the disk's remote_id

  field :platform_key, type: String # Points to remote_id for the platform_key path
  # Remote ID it's a UUID
  field :remote_id, type: String

  index({ platform_key: 1 }, { unique: true })

  # Disk / Nic default to :unset to catch accidental nils passed through when creating Disk / Nic prids (introduces tricky to find bugs)
  def initialize(remote_id:,
                 infrastructure:,
                 machine: nil,
                 disk: :unset,
                 nic: :unset)

    raise "Disk cannot be set to nil" if disk.nil?
    raise "Nic cannot be set to nil" if nic.nil?
    raise "Cannot initialize with 'disk' and 'nic' params" if (disk != :unset and nic != :unset)
    super(remote_id: remote_id)

    new_platform_key = "i:#{infrastructure}"
    if machine
      new_platform_key << "/m:#{machine}"
      new_platform_key << "/d:#{disk}" unless disk == :unset
      new_platform_key << "/n:#{nic}" unless nic == :unset
    end

    self.platform_key = new_platform_key
  end

end
