require 'rbvmomi_extensions'
require 'vsphere_session'

class VSphereEventCollector
  using RbVmomiExtensions

  def initialize(start_time, end_time)
    @start_time = start_time
    @end_time = end_time
  end

  def event_history
    @event_history ||= VSphere.session.serviceContent.eventManager.CreateCollectorForEvents(filter: event_filter_spec)
  end

  def events
    @events ||= begin
      vm_events = Hash.new { |h, k| h[k] = Hash.new { |h2, k2,| h2[k2] = Set.new } }

    event_history.ReadNextEvents(maxCount: 500).each do |event|
      event_type = event.class.to_s

      created_time = event.createdTime
      rounded_event_time = created_time.change(min: created_time.min - (created_time.min % 5))

      moref = event.vm.vm.moref

      if vm_create_events.include?(event_type)
        vm_events[rounded_event_time][:created] << moref
      else
        if vm_events[rounded_event_time][:created].include?(moref)
          # If a single event includes a create and remove, just ignore that machine completely
          vm_events[rounded_event_time][:created].delete(moref)
        else
          vm_events[rounded_event_time][:deleted] << event.vm.vm.moref
        end
      end
    end

    event_history.DestroyCollector()

    vm_events
  end
  end

  private

  # !! can a deleted machine be resurrected?
  def vm_create_events
    # !! check on: MigrationEvent VmEmigratingEvent VmMigratedEvent
    @vm_create_events ||= Set.new(%w(VmClonedEvent VmCreatedEvent VmDeployedEvent VmDiscoveredEvent VmRegisteredEvent))
  end

  def vm_remove_events
    # !! check on: MigrationEvent VmEmigratingEvent  VmDeployFailedEvent VmDisconnectedEvent VmOrphanedEvent  VmFailedMigrateEvent VmFailoverFailed
    @vm_remove_events ||= Set.new(%w(VmRemovedEvent))
  end

  def event_filter_spec
    time_spec = RbVmomi::VIM.EventFilterSpecByTime(beginTime: @start_time.strftime('%Y-%m-%dT%H:%M:%S'),
                                                   endTime: @end_time.strftime('%Y-%m-%dT%H:%M:%S'))

    $logger.debug "vm_create_events: #{vm_create_events.to_a}"
    $logger.debug "vm_remove_events: #{vm_remove_events.to_a}"
    $logger.debug "time_spec: #{time_spec.inspect}"

    RbVmomi::VIM.EventFilterSpec(eventTypeId: (vm_create_events + vm_remove_events).to_a,
                                 time: time_spec)
  end
end
