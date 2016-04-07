module Systemd
  class Job
    attr_reader :job_id, :unit_name, :job_type, :object_path, :unit_path

    def initialize(prop_array)
      @job_id,
      @unit_name,
      @job_type,
      @job_state,
      @object_path,
      @unit_path  = prop_array
    end

  end
end
