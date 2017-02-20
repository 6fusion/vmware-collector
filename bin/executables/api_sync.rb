module Executables
  class ApiSync
    def initialize(scheduler)
      logger.info 'Initializing OnPremConnector'
      @scheduler = scheduler
      begin
        @on_prem_connector = OnPremConnector.new
      rescue Exception => e
        logger.fatal "Unable to start OnPremConnector: #{e.message}"
        exit(1)
      end
    end

    def execute
      logger.info 'Executing OnPrem submission checks'

      begin
        @on_prem_connector.submit
      rescue StandardError => e
        logger.fatal "Encountered unhandled exception: #{e.message}."
        logger.debug e.backtrace.join("\n")
        @scheduler.shutdown
        exit(1)
      end

      logger.info 'Shutting down OnPrem submission handler'
    end
  end
end
