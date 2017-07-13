# This module provides an interface for comparison of objects we store in mongo.
# It allows the LocalInventory class to compare items, on assignment, and determine if they are
# updated, and, consequently, if they need to be updated in mongo

module Matchable
  def item_matches?(other)
    # !!! Why is relations_match?(other) commented out? Need to test this...
    attributes_match?(other) and relations_match?(other)
  end

  def relations_match?(other)
    embedded_relations.each do |_name, relation|
      my_embedded = send(relation.key)
      other_embedded = other.send(relation.key)

      if my_embedded.is_a?(Array)
        unless (my_embedded.size == other_embedded.size) &&
            my_embedded.reject do |item|
              other_embedded.any? { |other_item| item.attributes_match?(other_item) }
            end.empty?
          return false
        end
      else
        return false unless (my_embedded.nil? && other_embedded.nil?) || (my_embedded && my_embedded.item_matches?(other_embedded))
      end
    end
    true
  end

  def attributes_match?(other)
    other &&
        attribute_map.reject do |key, _value|
          read_attribute(key.to_sym).eql?(other.read_attribute(key.to_sym))
        end.empty?
  end

  # This is meant only as a "default"
  #  Most classes included this module will probably want to override this method to
  #  return only the fields that matter to that class
  def attribute_map
    attribute_hash = {}
    embeds = embedded_relations.keys
    fields.reject do |k, _v|
      k =~ /^_id|created_at|updated_at|record_status$/ ||
          embeds.include?(k)
    end.each do |k, _v|
      attribute_hash[k.to_sym] = k.to_sym
    end
    attribute_hash
  end
end
