module NetworkHelper

  def can_connect?(host, port, resolve=true)
    exception = nil
    begin
      Timeout::timeout(10) {
        Resolv.new.getaddress(host) if resolve
        TCPSocket.new(host, port).close
        true }
    rescue Timeout::Error => e
      raise StandardError.new("timeout during check: #{e.message}")
    rescue Resolv::ResolvError => e
      exception = e
      raise StandardError.new("could not be resolved: #{e.message}")
    rescue Errno::ECONNREFUSED => e
      exception = e
      host = Resolv.new.getaddress(host) if resolve
      raise "could not be connected to at #{host}:#{port}: #{e.message}"
    ensure
      if ( e )
        puts e.class
        Rails.logger.error e.message
        Rails.logger.debug e.backtrace
      end
    end
  end

  end
