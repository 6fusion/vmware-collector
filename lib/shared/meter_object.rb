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
      Thread.main.raise e
    end
    self
  end

  def patch_to_api
    $logger.info { "Updating #{self.class}: #{self.name}/#{self.custom_id} in the 6fusion Meter" }
    begin
      response = $hyper_client.patch(self)
      if ( response.present? && response.code.eql?(200) )
        self.record_status = 'verified_update'
        self.save
      end
    rescue RestClient::ResourceNotFound => e
      $logger.warn { "Patch of #{self.name} failed. Posting..." }
      self.post_to_api
    rescue RestClient::ExceptionWithResponse => e
      if e.response.code == 404
        $logger.warn { "Patch of #{self.name} failed (404). Posting..." }
        self.post_to_api
      end
    rescue StandardError => e
      $logger.error "Error updating #{self.class} #{self.name}/#{self.custom_id} in the 6fusion Meter"
      Thread.main.raise e
    end
    self
  end
  
end
