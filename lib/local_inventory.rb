# This collection of classes is used to help batch insert operations into mongo
#  since Mongoid currently has no ability to batch insert operations

##################################################
# Arrayish access for storing to mongo
class MongoArray < Array
end

class ReadingInventory < MongoArray
  def save
    unless ( empty? )
      Reading.collection.insert_many(map(&:as_document))
      clear # reset ourself (i.e., the array)
    end
  end
end
##################################################
# Hash like access to mongo
class MongoHash < Hash

  def initialize(klass, key=:platform_id)
    super()
    @klass = klass
    @key = key
    # Fill in hash values
    filtered_items.each {|item|
      self.store(item[@key],item) }
    # Initialize some state
    @initial_inventory = keys
    @updates = Array.new
  end

  def filtered_items
    @klass.ne(status: 'deleted')
  end

  def save
    unless ( @updates.empty? )
      $logger.info "Saving #{@updates.size} updates to database"
      pending_inserts = @updates.reject{|item| item.persisted? }
      # Batch all the inserts
      #!! this results in absent timestamps. Hopefully will be alleviated with mongoid 5
      @klass.collection.insert_many(pending_inserts.map(&:as_document)) unless pending_inserts.empty?
      # Iterate over modified items and save
      (@updates - pending_inserts).each{|item|
        Infrastructure.where(remote_id: item.remote_id).map {|i| i.update_attributes(record_status: 'updated')} if item.is_a?(Infrastructure)
        item.save
        self.store(item[@key], item) }
      # Refresh hash with inserts
      @klass.where(:_id.in => pending_inserts.map(&:id)).each{|m|
        self.store(m[@key],m) }
      @updates = []
    end
  end

  def []=(key,new_item)
    add_item = false

    if ( has_key?(key) )
      previous = fetch(key)

      # If the new item being assigned doesn't match the existing,
      #  add the new item to the batch that will be submitted as "updates"
      if !previous.item_matches?(new_item)
        $logger.info "Updating item in local inventory with ID: #{key}"
        $logger.debug "Item: #{previous.to_json} updated to #{new_item.to_json}"
        new_item.record_status = 'updated'
        add_item = true
      else
        new_item.record_status = 'unchanged'
      end

      # If relations have changed on the item
      unless ( previous.relations_match?(new_item) )
        add_item = true
        new_item.record_status = 'updated'
        $logger.info "Updating item in local inventory with ID: #{key}"
        $logger.debug "Item: #{previous.to_json}\n updated to\n #{new_item.to_json}"
        # Iterate over each "embeds" relation
        previous.class.embedded_relations.each do |name, relation|
          previous_embedded = previous.send(relation.key)
          new_item_embedded = new_item.send(relation.key)

          # If it's an embeds_many relation, iterate over each embedded item
          if ( previous_embedded.is_a?(Array) )
            # Determine if anything has been deleted
            missing_ids = (previous_embedded.reject{|p| p.respond_to?(:record_status) and
                                                        p.record_status and
                                                        p.record_status.match(/delete/) }
                                            .map(&:platform_id) - new_item_embedded.map(&:platform_id))

            # Grab the class of the first embedded item (which one doesn't matter, they all have to be the same)
            #  and instantiate a new copy with the only two things we care about: the platform ID and a record_status of deleted
            missing_ids.each {|platform_id|
              $logger.info "Flagging #{relation.key}:#{platform_id} for deletion #{%Q|for #{previous.platform_id}| if previous.respond_to?(:platform_id)} "
              new_item_embedded << previous_embedded.first.class.new(platform_id: platform_id, record_status: 'to_be_deleted') }
          #!!elsif previous is not an array
          end
        end
      end
    else
      $logger.info "Adding item to local inventory with ID: #{key}"
      $logger.debug "Item: #{new_item.to_json}"
      new_item.record_status = 'created' if new_item.respond_to?(:record_status)
      add_item = true
    end

    @updates << new_item if add_item
  end

  def sync_missing
    # What existed before gap minus what currently exists
    # [1,2,3] - [1,2] = 3 ... So 3 no longer exists and has been deleted
    deleted = (@initial_inventory - keys)
    $logger.debug "Flagging #{deleted} for deletion"
    unless deleted.empty?
      @klass.in(@key => deleted).update_all(status: 'deleted')
      deleted.each{|key| delete(key)}
    end
  end

end

class MachineInventory < MongoHash
  require 'machine'

  def initialize(infrastructure=nil, key=:platform_id)
    @infrastructure = infrastructure
    super(Machine,key)
  end

  def filtered_items
    # FIXME is there a reason we're not just using InventoriedTimestamps directly?
    filtered_machines = @infrastructure ?
                          Machine.where(infrastructure_platform_id: @infrastructure.platform_id).ne(status: 'deleted') :
                          Machine.ne(status: 'deleted')

    latest_machine = filtered_machines.order_by(inventory_at: 'desc').first

    filtered_machines = filtered_machines.where(inventory_at: latest_machine.inventory_at) if latest_machine
    filtered_machines
  end

  def delete(platform_id)
    machine = fetch(platform_id, nil)
    if ( machine )
      machine.status = 'deleted'
      machine_as_document = machine.as_document
      machine_as_document.delete('_id')
      machine_as_document['disks'].each{|d|d.delete('_id')}  if machine_as_document['disks'].present?
      machine_as_document['nics'].each{|d|d.delete('_id')} if machine_as_document['nics'].present?
      $logger.debug "Adding deletion record for #{platform_id}"
      self[platform_id] = Machine.new(machine_as_document)
    else
      $logger.warn "Attempt to delete machine #{platform_id} which is not stored to inventory."
    end
  end

  def save_a_copy_with_updates(inventory_time)
    updated_platform_ids = @updates.map{|updated| updated[@key]} # @key is platform_id for machines
    machines_to_copy = values.reject{|v| updated_platform_ids.include?(v[@key]) }

    # Add old machines to "updates" so they get reinserted into mongo as new records
    machines_to_copy.each do |machine|
      machine.record_status = 'unchanged'
      @updates << machine
    end

    @updates.map! do |machine|
      clone_mach = machine.clone
      clone_mach.disks = machine.disks.reject{|d| d.record_status and d.record_status.eql?('verified_deleted')}.map{|d| d.clone }
      clone_mach.nics = machine.nics.reject{|n| n.record_status and n.record_status.eql?('verified_deleted')}.map{|n| n.clone }
      clone_mach.inventory_at = inventory_time
      clone_mach
    end

    begin
      if ( @updates.size > 0 )
        $logger.debug "Saving #{@updates.size} machines to local inventory"
        Machine.collection.insert_many(@updates.map(&:as_document))
        clear
        filtered_items.where({inventory_at: inventory_time}).each {|m|
          store(m.platform_id,m) unless m.status.eql?('deleted') }

        values.each do |machine|
          machine.embedded_relations.each do |name, relation|
            embedded = machine.send(relation.key).to_a  #<< to_a to dodge mongoid's delete_if
            embedded.delete_if{|item| item.respond_to?(:record_status) and ( item.record_status and item.record_status.match(/delete/) ) }
          end
        end
        @updates = []
      else
        $logger.warn "Ignoring request to save empty machine inventory."
      end
    rescue StandardError => e
      $logger.fatal e
      $logger.debug e.backtrace.join("\n")
    end

  end

  # Before each save, we want to make sure we're as current as possible on any remote IDs that
  #  may have been filled in by the OnPrem Connector.
  #!! performance test this. it may be good to iterate over all machines and see if any are
  #  missing the remote_id first
  # def refresh_remote_ids
  #   aggregation = Machine.collection.aggregate( [ { '$match': { status:    { '$ne': 'deleted' },
  #                                                               remote_id: { '$exists': true } } },
  #                                                 { '$group': { '_id': { platform_id: '$platform_id',
  #                                                                        remote_id: '$remote_id'  } } }
  #                                               ] )
  #   aggregation.each do |result_pair|
  #     platform_id = result_pair['_id']['platform_id']
  #     remote_id =   result_pair['_id']['remote_id']
  #     begin
  #       if ( machine = fetch(platform_id) )
  #         machine.remote_id ||= remote_id
  #       end
  #     rescue KeyError => e
  #       #this really shouldn't be possible
  #       $logger.debug "Machine not found for platform ID: #{platform_id} when mapping remote ID"
  #       $logger.debug e
  #     end
  #   end
  # end

  def at_or_before(inventory_time)
    clear #!! optimal?

    # Get a machine with an inventory_at at or earlier than what's requested
    nearest_machine = Machine.lte(inventory_at: inventory_time).sort(inventory_at: :desc).first

    if ( nearest_machine )
      nearest_time = nearest_machine.inventory_at
      # Use that timestamp to fill this hash
      filtered_items.where(inventory_at: nearest_time).each {|machine|
        store(machine.platform_id,machine) }
    end
    self
  end

  def set_to_time(inventory_time)
    clear #!! any way to avoid this? gte #record keys and remove those absent?
    filtered_items.where(inventory_at: inventory_time).each {|machine|
      store(machine.platform_id,machine) }
  end

end


class InfrastructureInventory < MongoHash
  def initialize(key=:platform_id)
    super(Infrastructure, key)
  end

  def []=(key,new_item)
    if ( has_key?(key) )
      add_item = false
      previous = fetch(key)
      # If the new item being assigned doesn't match the existing,
      #  add the new item to the batch that will be submitted as "updates"
      if !previous.item_matches?(new_item)
        $logger.info "Updating item in local inventory with ID: #{key}"
        $logger.debug "Item: #{previous.to_json}"
        previous.attribute_map.keys.each{|key|
          $logger.debug { %Q|#{key} changing from #{previous.send("#{key}")} to #{new_item.send("#{key}")}| }
          previous.send("#{key}=", new_item.send("#{key}")) }

        previous.record_status = 'updated' if new_item.respond_to?(:record_status)
        add_item = true
      end

      # If relations have changed on the new item
      unless (previous.relations_match?(new_item) )
        $logger.info "Updating item in local inventory with ID: #{key}"
        $logger.debug "Item: #{previous.to_json}"
        # Iterate over each relation
        add_item = true
        previous.class.embedded_relations.each do |name, relation|
          previous.send("#{name}=", new_item.send(name))
        end
      end

      @updates << previous if add_item
    else
      $logger.info "Adding item to local inventory with ID: #{key}"
      $logger.debug "Item: #{new_item.to_json}"
      new_item.record_status = 'created' if new_item.respond_to?(:record_status)
      @updates << new_item
    end
  end


  def filtered_items
    Infrastructure.nin(record_status: ['deleted'])
  end
end


# class PlatformRemoteIdInventory < MongoHash
#   def initialize(key=:platform_key)
#     super(PlatformRemoteId, key)
#   end

#   def []=(key,item)
#     if item == nil
#       $logger.debug "Cannot add PRID key for value item=nil to PlatformRemoteIdInventory"
#       return
#     end

#     if ( has_key?(key) )
#       previous = fetch(key)
#        # In case somehow added PRID without remote_id
#       unless previous.remote_id
#         $logger.info "PRID with platform_key #{key} was missing remote_id. Updating with remote_id #{item.remote_id} now"
#         $logger.debug "Item: #{previous.to_json}"
#         @updates << previous
#       end
#     else
#       $logger.info "Adding new PRID with platform_key: #{key} and remote_id: #{item.remote_id}"
#       $logger.debug "Item: #{item.to_json}"
#       @updates << item
#     end
#   end
# end
