require 'global_configuration'

namespace 'configuration' do
  desc 'Print current meter configuration'
  task :current do
    include GlobalConfiguration
    puts configuration.to_s
  end
end
