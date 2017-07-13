module Executables
  class Infrastructure
    def initialize(scheduler)
      @scheduler = scheduler
      @collector = begin
        InfrastructureCollector.new
      rescue StandardError => e
        $logger.fatal "Unable to start infrastructure collection. #{e.message}"
        $logger.debug e
        exit(1)
      end
    end

    def execute
      $logger.info '- Starting Collecting Infrastructures'
      begin
        # Give up after 9 minutes (this keeps us from falling behind by more than one run)
        Timeout.timeout(NINE_MINUTES_IN_SECONDS) do
          @collector.run
        end
      rescue Timeout::Error => e
        $logger.error 'Unable to collect information infrastructure; process timed out.'
      rescue StandardError => e
        $logger.fatal "Encountered unhandled exception: #{e.message}."
        $logger.debug e.backtrace
        @scheduler.shutdown
        exit(1)
      end
      $logger.info '- Shutting down collecting Infrastructures'
    end
  end
end
