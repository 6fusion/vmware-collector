module Executables
  class ApiSync
    def initialize(scheduler)
      logger.info 'Initializing UC6Connector'
      @scheduler = scheduler
      begin
        @uc6_connector = UC6Connector.new
      rescue Exception => e
        logger.fatal "Unable to start UC6Connector: #{e.message}"
        exit(1)
      end
    end

    def execute
      logger.info 'Executing UC6 submission checks'

      begin
        @uc6_connector.submit
      rescue StandardError => e
        logger.fatal "Encountered unhandled exception: #{e.message}."
        logger.debug e.backtrace
        @scheduler.shutdown
        exit(1)
      end

      logger.info 'Shutting down UC6 submission handler'
    end
  end
end
