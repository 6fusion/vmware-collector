class LogsSocketController < WebsocketRails::BaseController

  def initialize_session
    logger.debug "LOGS SESSION INITALIZED"
    # perform application setup here
    controller_store[:logstream] ||= LogStream.instance

  end

  # def client_connected
  #   logger.debug "LOGS CLIENT CONNECTED"
  # end

  def start_tailing
    logger.debug "LOGS: start_tailing"
    controller_store[:logstream].start

    @stream_thread = Thread.new {
      loop do
        msg = controller_store[:logstream].get
        send_message :new_message, msg, namespace: 'logs'
      end }
    @stream_thread.abort_on_exception = true
  end


  def stop_tailing
    logger.debug "LOGS: stop_tailing"
    controller_store[:logstream].stop
    @stream_thread.join
  end


end
