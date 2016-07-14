require 'logger'
require 'singleton'

module Logging
  def logger
    MeterLog.instance.logger
  end

  class MeterLog
    include Singleton
    attr_accessor :logger

    @@level = Logger::INFO

    def self.log_level=(desired_level)
      @@level = desired_level
    end

    def initialize
      STDOUT.sync = true # disable output buffering; makes it hard to follow docker logs
      @logger = Logger.new(STDOUT)
      @logger.progname = File.basename($PROGRAM_NAME, '.rb')
      # @logger.formatter = proc { |severity, _datetime, progname, msg|
      #   "#{progname}(#{severity}): #{msg}\n"
      # }
    end
  end
end
