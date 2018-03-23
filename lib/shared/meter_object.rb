module MeterObject

  def already_submitted?
    $logger.debug { "Checking 6fusion Meter for #{self.class}: #{self.name}/#{self.platform_id}" }
    begin
      response = $hyper_client.head(self)
      response and (response.code == 200)
    rescue StandardError => e
      $logger.warn { e.message }
      $logger.debug { e.backtrace[0..20].join("\n") }
      false
    end
  end

  def post_to_api
    begin
      if already_submitted?{ hyper_client.head_machine(custom_id) }
        self.update_attribute(:record_status, 'updated')
      else
        $logger.info { "Creating #{self.class}: #{self.name}/#{self.custom_id} in 6fusion Meter" }
        response = $hyper_client.post(self)
        #self.remote_id = response.json['id']
        # TODO is this the best place for this? Maybe more of a controller op?
        #update_attribute(:record_status, 'verified_create') # record_status will be ignored by local_inventory class, so we need to update it "manually"
        self.record_status = 'verified_create'
        self.save
      end
    rescue => e
      $logger.error { "Error creating #{self.class} #{self.custom_id} in the 6fusion Meter API" }
      $logger.error { e.message }
      $logger.debug { e.backtrace[0..20].join("\n") }
      raise
    end
    self
  end

end
