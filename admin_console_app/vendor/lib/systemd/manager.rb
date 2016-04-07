require 'dbus'

module Systemd
  class Manager

    MODES = %w{replace fail isolate ignore-dependencies ignore-requirements}

    def initialize
      @bus     = DBus.system_bus
      @service = @bus['org.freedesktop.systemd1']
    end

    # Get the version number for the currently running systemd instance.
    # @return [Integer] systemd version number (e.g., 212)
    def version
      mgr['Version'].to_i
    end

    # Return the feature configuration for the currently running systemd
    # instance.  Enabled features are prefixed with a plus (+), while disabled
    # features are prefixed with a dash (-).
    # @return [Array] list of enabled/disabled features.
    def features
      mgr['Features'].split(/\s+/)
    end

    # Check if the specified feature is enabled for the current systemd
    # instance.
    # @return [Boolean] true if the feature is enabled, false otherwise.
    def feature?(feat)
      !!features.find { |f|  f == "+#{feat.to_s.upcase}" }
    end

    # Get the file system paths where systemd will look for unit files.
    # @return [Array] list of directories.
    def unit_paths
      mgr['UnitPath']
    end

    # Check if systemd has detected that it's running in a virtualized
    # environment.
    # @return [Boolean] true if systemd thinks the system is virtualized.
    def virtualization?
      virtualization.empty?
    end

    # Get the specific type of virtualization systemd has detected,
    # for example 'kvm'.
    # @return [String] detected virtualzation type, or an empty string.
    def virtualization
      mgr['Virtualization']
    end

    # Get the system architecture.  For example, x86-64.
    # @return [String] architecture name.
    def architecture
      mgr['Architecture']
    end

    # Get the list of all currently loaded units.
    # @return [Array] list of `Systemd::Unit` objects.
    def units
      mgr.ListUnits[0].map { |u| Unit.new(u) }
    end

    # Get the list of all currently queued jobs.
    # @return [Array] list of `Systemd::Job` objects.
    def jobs
      mgr.ListJobs[0].map { |j| Job.new(j) }
    end

    # instruct systemd to reload all unit files.
    def reload
      mgr.Reload
    end

    # instruct systemd to save state to disk and restart itself.
    def reexecute
      mgr.Reexecute
    end

    # enable one or more units.
    # @param [String] units one or more unit files to enable.
    # @param [Boolean] runtime true if the unit should only be enabled for
    #   the current runtime (i.e., linked into `/run`), or false to persist.
    # @param [Boolean] force true to overwrite existing units, or false to
    #   preserve.
    def enable_units(*units, runtime: false, force: false)
      mgr.EnableUnitFiles(units, runtime, force)
    end

    # disable one or more units.
    # @param [String] units one or more unit files to disable.
    def disable_units(*units, runtime: false)
      mgr.DisableUnitFiles(units, runtime)
    end

    # start a unit.
    # @param [String] name name of the unit file to start.
    # @param [String] mode how to start the unit.  One of MODES.
    def start(name, mode)
      mode = validate_mode(mode)
      mgr.StartUnit(name, mode)
    end


    # start a unit.
    # @param [String] name name of the unit file to stop.
    # @param [String] mode how to start the unit.  One of MODES. `isolate`
    #  is not a valid mode for this call.
    def stop(name, mode)
      mode = validate_mode(mode, MODES - %w{isolate})
      mgr.StopUnit(name, mode)
    end

    private

    def validate_mode(name, valid = MODES)
      name = name.to_s.downcase
      raise ArgumentError, "Invalid mode: #{name}" unless valid.include?(name)
      name
    end

    def object
      @object ||= @service.object('/org/freedesktop/systemd1').tap do |o|
        o.introspect
      end
    end

    def mgr
      @mgr ||= object['org.freedesktop.systemd1.Manager']
    end

  end
end
