module Systemd
  class Unit
    attr_reader :name, :description, :unit_path

    def initialize(prop_array)
      @name,
      @description,
      @load_state,
      @active_state,
      @sub_state,
      @followed,
      @unit_path,
      @job_id,
      @job_type,
      @job_path = prop_array
    end

  end
end
