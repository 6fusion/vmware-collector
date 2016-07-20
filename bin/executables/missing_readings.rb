module Executables
  class MissingReadings
    def initialize(scheduler)
      @scheduler = scheduler
      @missing_readings_handler = MissingLocalReadingsHandler.new
    end

    def execute
      logger.info 'Executing missing readings verification'

      begin
        start_time = Time.now
        @missing_readings_handler.run
        logger.debug "Missing readings handler run took #{Time.now - start_time} seconds to complete"
      rescue StandardError => e
        logger.fatal "Encountered unhandled exception: #{e.message}."
        logger.debug e.backtrace
        @scheduler.shutdown
        exit(1)
      end

      logger.info 'Shutting down missing readings verification'
    end
  end
end
