module Executables
  class MissingReadingsCleaner
    def initialize(scheduler)
      @scheduler = scheduler
      @missing_readings_handler = MissingLocalReadingsHandler.new
    end

    def execute
      logger.info 'Executing cleanning process'

      begin
        start_time = Time.now
        @missing_readings_handler.unlock_old_inventory_timestamps
      rescue StandardError => e
        logger.fatal "Encountered unhandled exception: #{e.message}."
        logger.debug e.backtrace
        @scheduler.shutdown
        exit(1)
      end

      logger.info 'Shutting down cleannig process'
    end
  end
end
