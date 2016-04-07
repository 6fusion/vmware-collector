# require 'singleton'
# require 'thread/channel'

# class LogStream
#   include Singleton

#   def initialize
#     STDERR.puts "INITAILZING LOG STREAMER"
#     @channel = Thread.channel
#     @send_thread = nil
#     @streamer_threads = Array.new
#     @streamer_thread  = nil
#     #!! dry up with controller
#     # @log_cmd = if ( File.exists?('/usr/bin/journalctl') )
#     #              `journalctl -D/var/log/journal --since '#{since}'`
#     #            else
#     #              `vagrant ssh -- journalctl  --since \\'#{since}\\'`
#     #            end
#   end

#   def get
#     @channel.receive
#   end

#   def start
#     STDERR.puts "STARTING LOG STREAMER"
#     # @streamer_thread ||= Thread.new {
#       # IO.popen(@log_cmd){|journal_io|
#       #   @channel.send journal_io.read}
#     containers.each{|container|
#       STDERR.puts "starting thread for #{container.info['Names']}"
#       @streamer_threads << Thread.new {
#         container.streaming_logs(stdout: true) {|stream, chunk|
#           @channel.send chunk } } }
#   end

#   def stop
#     STDERR.puts "STOPPING LOG STREAMER"
#     @streamer_threads.each{|t| t.join}
#     @streamer_threads = []
#   end

#   def containers
#     #!! is their any benefit to using docker.sock?
#     @containers ||= Docker::Container.all({}, Docker::Connection.new('tcp://localhost:2375', {}))
#                   .select{|container| container.json['Name'].match(/meter/i)}
#   end



# end
