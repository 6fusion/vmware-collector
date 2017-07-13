module VSphere
  def self.session
    @vsphere_session ||= VSphereSession.new.session
  end

  def self.refresh
    $logger.debug 'Refreshing vSphere session'
    @vsphere_session = VSphereSession.new.session
  end

  def self.root_folder
    wrapped_vsphere_request { session.serviceInstance.content.rootFolder }
  end

  def self.sessions
    wrapped_vsphere_request { session.serviceInstance.content.sessionManager }
  end

  def self.wrapped_vsphere_request
    retried_session = false
    response = nil
    begin
      response = yield # !! necessary?
    rescue StandardError => e # !! need the proper class that's thrown
      $logger.debug e
      unless retried_session
        retried_session = true
        # if ( defined?(@vsphere_session) )
        #   @vsphere_session.refresh
        # else
        # Above @vsphere_session.refresh was throwing NoMethodError undefined method `refresh' for #<RbVmomi::VIM:0x007f932808e130>
        # Will try refresh this way
        VSphere.refresh
        # end
        $logger.info 'Session expired; requesting new session'
        retry
      end
      raise e
    end
    response
  end

  class VSphereSession
    attr_accessor :session

    def initialize
      $logger.info 'Connecting to vSphere'
      @session = get_vsphere_session
    end

    def refresh
      @session = get_vsphere_session
    end

    def logout
      RbVmomi::VIM::SessionManager(@session, 'SessionManager').Logout
    end

    # Ensure our session gets cleaned up
    def self.finalize(session)
      proc do
        if session
          puts "#{File.basename($PROGRAM_NAME, '.rb')}: Logging out of vSphere session "\
               "'#{session.serviceInstance.content.sessionManager.currentSession.key}' for "\
               "#{session.serviceInstance.content.sessionManager.currentSession.userName}. "\
               "Total API calls: #{session.serviceInstance.content.sessionManager.currentSession.callCount}"
          RbVmomi::VIM::SessionManager(session, 'SessionManager').Logout
        end
      end
    end

    private

    def get_vsphere_session
      Timeout.timeout(10) do
        RbVmomi::VIM.connect(host: ENV['VSPHERE_HOST'],
                             user: ENV['VSPHERE_USER'],
                             password: ENV['VSPHERE_PASSWORD'],
                             insecure: (ENV['VSPHERE_IGNORE_SSL_ERRORS'] == 'true'),
                             debug: (ENV['VSPHERE_DEBUG'] == 'true'))
      end
    rescue Errno::ECONNREFUSED => e
      $logger.fatal("Connection to vSphere refused: #{e.message}")
      $logger.fatal(e.message)
      $logger.debug e.backtrace.join("\n")
      raise e
    rescue Net::OpenTimeout, Timeout::Error => e
      $logger.fatal('Could not connect to vSphere: connection attempt timed out.')
      $logger.fatal(e.message)
      $logger.debug e.backtrace.join("\n")
      raise e
    rescue OpenSSL::SSL::SSLError => e
      $logger.fatal('Could not connect to vSphere: SSL verification error.')
      $logger.fatal e.message
      $logger.debug e.backtrace.join("\n")
      raise e
    rescue StandardError => e
      $logger.fatal("Error connecting to vSphere: #{e.message}")
      $logger.fatal e.message
      $logger.debug e.backtrace.join("\n")
      raise e
    ensure
      ObjectSpace.define_finalizer(self, self.class.finalize(@session.dup)) if @session
    end
  end
end
