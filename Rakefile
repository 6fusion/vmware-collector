require 'bundler'
Bundler.require(:default)

$:.unshift File.expand_path('lib'), File.expand_path('lib/shared'), File.expand_path('lib/models')

Dir.glob('tasks/*.rake').each { |r| load r}
