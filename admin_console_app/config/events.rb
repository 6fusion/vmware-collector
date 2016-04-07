WebsocketRails::EventMap.describe do
  # You can use this file to map incoming events to controller actions.
  # One event can be mapped to any number of controller actions. The
  # actions will be executed in the order they were subscribed.
  #
  # Uncomment and edit the next line to handle the client connected event:
  #   subscribe :client_connected, :to => Controller, :with_method => :method_name
  #
  # Here is an example of mapping namespaced events:
  #   namespace :product do
  #     subscribe :new, :to => ProductController, :with_method => :new_product
  #   end
  # The above will handle an event triggered on the client like `product.new`.

  # subscribe :client_connected,    to: LogsSocketController, with_method: :client_connected
  # subscribe :client_disconnected, to: LogsSocketController, with_method: :client_disconnected
  # subscribe :new_message,         to: LogsSocketController, with_method: :new_message

#  subscribe :new_message,         to: LogsSocketController, with_method: :new_message


  # subscribe :client_connected,    to: LogsSocketController, with_method: :client_connected
  # subscribe :client_disconnected, to: LogsSocketController, with_method: :client_disconnected
  # subscribe :client_connected,    to: Uc6SyncSocketController, with_method: :client_connected
  # subscribe :client_disconnected, to: Uc6SyncSocketController, with_method: :client_disconnected
    # subscribe :new_message,         to: LogsSocketController, with_method: :new_message


  # namespace :logs do
  #   subscribe :start_tailing, to:  LogsSocketController, with_method: :start_tailing
  #   subscribe :stop_tailing,  to:  LogsSocketController, with_method: :stop_tailing
  # end

  namespace :uc6_sync do
    subscribe :start, to: Uc6SyncSocketController, with_method: :start
   end

  namespace :upgrade do
    subscribe :pull, to: UpgradeSocketController, with_method: :update_containers
  end

end
