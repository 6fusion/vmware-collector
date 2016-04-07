require 'moped'
# This file is used by Rack-based servers to start the application.

retry_count = 0
begin

  require ::File.expand_path('../config/environment', __FILE__)

  console = ActiveSupport::Logger.new($stdout)
  console.formatter = Rails.logger.formatter
  console.level = Rails.logger.level
  Rails.logger.extend(ActiveSupport::Logger.broadcast(console))

  run Rails.application

rescue Moped::Errors::ConnectionFailure => e
  retry_count += 1
  if ( retry_count < 10 )
    puts "Database not up yet.... waiting to retry"
    sleep(4)
    retry
  else
    raise e
  end
end
