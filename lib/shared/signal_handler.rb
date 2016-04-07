

module SignalHandler

  Signal.trap('HUP') {|signo|
    $hupped = true }

  # The class including this module must call this method periodically. We avoid doing
  #  any real work in the singal trap itself to to deadlock constraints for ruby
  #  (since signal traps are reentrant, anything that uses mutexes, like ruby's logger
  #   pose problems when used inside the trap)
  def processSignals
    if ( $hupped )
      configuration = GlobalConfiguration::GlobalConfig.instance
      Logging::logger.info "HUP receieved; refreshing configuration"
      configuration.refresh
      Logging::logger.level = configuration[:uc6_log_level]
      VSphere::refresh
      $hupped = false
      true
    else
      false
    end
  end

end
