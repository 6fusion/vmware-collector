# This module provides an interface for comparison of objects we store in mongo.
# It allows the LocalInventory class to compare items, on assignment, and determine if they are
# updated, and, consequently, if they need to be updated in mongo

module Matchable

  def item_matches?(other)
    # !!! Why is relations_match?(other) commented out? Need to test this...
    attributes_match?(other) # and relations_match?(other)
  end

  def relations_match?(other)
    embedded_relations.each do |name, relation|
      my_embedded = self.send(relation.key)
      other_embedded = other.send(relation.key)

      if ( my_embedded.is_a?(Array) )
        unless ( (my_embedded.size == other_embedded.size) and
                 my_embedded.reject{|item|
                   other_embedded.any?{|other_item| item.attributes_match?(other_item) } }.empty? )
          return false
        end
      else
        return false unless (my_embedded.nil? and other_embedded.nil?) or (my_embedded and my_embedded.item_matches?(other_embedded))
      end
    end
    true
  end


  def attributes_match?(other)
    other and
      attribute_map.reject{ |key, value|
        read_attribute(key.to_sym).eql?(other.read_attribute(key.to_sym)) }.empty?
  end

  # This is meant only as a "default"
  #  Most classes included this module will probably want to override this method to
  #  return only the fields that matter to that class
  def attribute_map
    attribute_hash = Hash.new
    embeds = embedded_relations.keys
    fields.reject{|k,v|
      k =~ /^_id|created_at|updated_at|record_status$/ or
        embeds.include?(k) }.each {|k,v|
      attribute_hash[k.to_sym] = k.to_sym}
    attribute_hash
  end

end
