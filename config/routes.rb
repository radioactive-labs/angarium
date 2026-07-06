Angarium::Engine.routes.draw do
  # Headless JSON API. Mount the engine in your app's routes, e.g.
  #   mount Angarium::Engine => "/webhooks"
  # yielding /webhooks/endpoints, /webhooks/deliveries/:id, etc.
  scope module: :api, defaults: {format: :json} do
    resources :endpoints, only: %i[index show create update destroy] do
      member do
        post :rotate_secret
        post :pause
        post :enable
        post :ping
      end
      resources :deliveries, only: %i[index]
    end

    resources :deliveries, only: %i[show] do
      member { post :redeliver }
      resources :attempts, only: %i[index]
    end
  end
end
