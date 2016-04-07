# Note: There's a lot of jumping around between referring to /host/home/core and plain /home/core. /host/home/core is used for commands run
#  directly by ruby inside the meter-registration container. /host/home/core is used for commands run via the HostCommandHelper::run method, which
#  is also run inside this container, but *after* a chroot into the /host directory (which has been mounted inside the registration
#  container and points to / on the host OS)

class LogsController < ApplicationController
  layout 'dashboard'
  include DockerHelper

  def level
    meter_configuration_document = MeterConfigurationDocument.first || MeterConfigurationDocument.new

    log_level = logger_to_human(meter_configuration_document.uc6_log_level || 1)
    db_debug = (meter_configuration_document.mongoid_log_level and meter_configuration_document.mongoid_log_level.eql?(Logger::DEBUG)) || false
    vSphere = (meter_configuration_document.mongoid_log_level and meter_configuration_document.mongoid_log_level.eql?(Logger::DEBUG)) || false

    render json: { levels: Logger::SEV_LABEL.reject{|l|l.in?(%w(ANY UNKNOWN))}.map(&:downcase),
                   selected: log_level.downcase,
                   database: db_debug }

  end

  def update
    @meter_configuration_document = MeterConfigurationDocument.first || MeterConfigurationDocument.new

    @meter_configuration_document.update_attributes(level_params)
    # If mongo hasn't been set to debug, nil it, so that it will fall back to using the UC6 log level in the meters
    @meter_configuration_document.unset(:mongoid_log_level) if level_params[:mongoid_log_level] != Logger::DEBUG

    if ( @meter_configuration_document.save )
      signal_meters
      render nothing: true
    else
      render json: {error: 'Unable to save log level for mongo'}, status: 400
    end
  end

  def download
    time = download_params[:duration_number] || 1
    unit = download_params[:duration_unit]   || 'day'
    valid_params = (time =~ /\A\d+\Z/) and (unit =~ /\A(?:hour|day|week)s*\Z/) # Basic validations

    if valid_params
      # Export system logs
      logger.debug "Writing log file to #{journalctl_output_file} on host"
      HostCommandHelper::run("/bin/journalctl --since '#{time} #{unit} ago' > /home/core/#{journalctl_output_file}")

      begin
        # Export mongo DB if requested; compress all files before sending
        HostCommandHelper::run("docker exec meter-database mongodump --db=#{database_name} --out=/host/home/core") if download_params[:include_database_export].eql?('1')
        zip_log_files
      rescue StandardError => e
        logger.error "Error exporting database; sending only system logs"
        logger.info e.message
        logger.debug e.backtrace.join("\n")
        send_file("/host/home/core/#{journalctl_output_file}", filename: "meter_logs_#{export_timestamp}.txt")
      else
        logger.info "Sending zip download file (time: #{time}, unit: #{unit}) "
        send_file("/host/home/core/#{zip_output_file}", filename: zip_output_file)
      ensure
        delete_log_files
      end

    else
      redirect_to url_for(controller: 'dashboard', action: 'index',  anchor: 'Logs', notification: 'Please ensure a correct time span is entered')
    end
  end

  def download_params
    params.require(:logs).permit(:duration_number, :duration_unit, :include_database_export)
  end

  def level_params
    config = params[:meter_configuration_document]
    [:uc6_log_level, :mongoid_log_level].each{|level|
      config[level] = human_to_logger(config[level]) }

    params.require(:meter_configuration_document).permit(:uc6_log_level,:mongoid_log_level,:vsphere_debug)
  end

  private
  def human_to_logger(level_as_string)
    level_as_string.is_a?(String) ?
      Logger::SEV_LABEL.index(level_as_string.upcase) :
      level_as_string # just return whatever was passed in if it's not a string
  end

  def logger_to_human(level_as_int)
    Logger::SEV_LABEL[level_as_int]
  end

  def zip_log_files
    HostCommandHelper::run("cd /home/core && zip -r #{zip_output_file} #{journalctl_output_file} #{mongodump_directory}")
  end

  def delete_log_files
    FileUtils.rm_rf("/host/home/core/#{mongodump_directory}", secure: true)
    File.unlink("/host/home/core/#{journalctl_output_file}")
    # Delete any previous log zips (can't delete current as it needs to be streamed to client)
    Dir.glob('/host/home/core/meter_logs_*.zip').reject{|f| f.eql?("/host/home/core/#{zip_output_file}")}.each{|f| File.unlink(f) }
  end

  # Wrap some paths and whatnot in accessors
  def zip_output_file
    "meter_logs_#{export_timestamp}.zip"
  end
  def database_name
    @database_name ||= begin
                         mongoid_config = GlobalConfiguration::GlobalConfig.instance
                         mongoid_config[:mongoid_database]
                       end
  end
  def journalctl_output_file
    'meter_logs.txt'
  end
  def mongodump_directory
    database_name
  end
  def export_timestamp
    @export_timestamp ||= Time.now.utc.to_s.gsub(/\s/, '_').gsub(/\:/, '-') # More readable than seconds since epoch
  end

end
