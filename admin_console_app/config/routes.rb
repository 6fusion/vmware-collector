Rails.application.routes.draw do

  constraints(lambda { |req| req.protocol =~ /http:/ }) do
    match "/(*path)" => redirect { |p, r| URI(r.url).tap { |u| u.scheme = "https" }.to_s }, via: [:get]
  end

  constraints(lambda { |req| req.protocol =~ /https/ }) do
    root 'dashboard#index'
    resources :registration
    resources :dashboard,   only: [:index]
    resources :meter_configuration_documents,   only: [:create,:update]

    put 'logger/level',       to: 'logs#update'
    get 'logger/level',       to: 'logs#level'
    get 'logs/download',      to: 'logs#download'

    # These two routes are for effecting the host
    put 'service/reboot',   to: 'service#reboot'
    put 'service/poweroff', to: 'service#poweroff'
    # These three routes are for effecting containers
    put 'service/restart',  to: 'service#restart'
    put 'service/start',    to: 'service#start'
    put 'service/stop',     to: 'service#stop'

    get  '/login',          to: 'sessions#new'
    post 'sessions/create', to: 'sessions#create'
    put '/logout',          to: 'sessions#destroy'
    # put is a bit more appropriate, but being able to browse to /logout is convenient
    get '/logout',          to: 'sessions#destroy'

    get 'status/appliance',   to: 'status#appliance'
    get 'status/database',    to: 'status#database'
    get 'status/health',      to: 'status#health'
    get 'status/services',    to: 'status#services'
    put 'status/enable',      to: 'status#enable'
    put 'status/disable',     to: 'status#disable'
    put 'status/service',     to: 'status#service'
  end

end

