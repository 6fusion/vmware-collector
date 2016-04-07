require File.expand_path('../boot', __FILE__)

# Pick the frameworks you want:
require "active_model/railtie"
#require "active_job/railtie"
# require "active_record/railtie"
require "action_controller/railtie"
#require "action_mailer/railtie"
require "action_view/railtie"
require "sprockets/railtie"
#require "rails/test_unit/railtie"

# Require the gems listed in Gemfile, including any gems
# you've limited to :test, :development, or :production.
Bundler.require(*Rails.groups)

# # Normally these requires shouldn't be necessary, but they seem to be necessary to
# # support config.cache_classes = true (for production mode), probably due to the shared/atypical
# # directory layout vs rails convention
$:.unshift '../lib/shared', '../lib/models'
require 'global_configuration'

module AdminConsole
  class Application < Rails::Application
    # Settings in config/environments/* take precedence over those specified here.
    # Application configuration should go into files in config/initializers
    # -- all .rb files in that directory are automatically loaded.

    # Set Time.zone default to the specified zone and make Active Record auto-convert to this zone.
    # Run "rake -D time" for a list of tasks for finding time zone names. Default is UTC.
    # config.time_zone = 'Central Time (US & Canada)'

    # The default locale is :en and all translations from config/locales/*.rb,yml are auto loaded.
    # config.i18n.load_path += Dir[Rails.root.join('my', 'locales', '*.{rb,yml}').to_s]
    # config.i18n.default_locale = :de

    config.autoload_paths << Rails.root.join('../lib')
    config.autoload_paths << Rails.root.join('../lib/models')
    config.autoload_paths << Rails.root.join('../lib/shared')
    config.autoload_paths << Rails.root.join('vendor/lib')

    config.middleware.delete Rack::Lock

  end
end

Rails.application.configure do

  config.after_initialize do
    begin
      configuration = GlobalConfiguration::GlobalConfig.instance
      configuration[:uc6_meter_version] = DockerHelper::current_version
      Infrastructure.each do |inf|
        Rails.logger.info "Submitting #{inf.meter_instance.name}"
        inf.meter_instance.update_attribute(:release_version, DockerHelper::current_version)
        Rails.logger.warn "Error submitting meter configuration update to UC6" unless inf.meter_instance.submit_updated_self
      end
    rescue StandardError => e
      STDERR.puts e.message
      Rails.logger.error e.message
      Rails.logger.error e.backtrace.join("\n")
    end
  end

end

