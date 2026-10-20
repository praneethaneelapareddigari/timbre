defmodule TimbreWeb.Router do
  use TimbreWeb, :router

  pipeline :api do
    plug :accepts, ["json"]
  end

  # Ops probes — unauthenticated, no `:accepts` plug so bare LB/k8s probes work.
  scope "/", TimbreWeb do
    get "/healthz", HealthController, :live
    get "/readyz", HealthController, :ready
  end

  scope "/api", TimbreWeb do
    pipe_through :api

    get "/hello", HelloController, :show

    resources "/recordings", RecordingController, only: [:index, :show, :create, :update, :delete]
    post "/recordings/:id/transcribe", RecordingController, :transcribe

    post "/sessions", SessionController, :create
    get "/sessions/:code", SessionController, :show
  end

  # Media is fetched by <audio> elements, whose Accept headers aren't JSON, so
  # it sits outside the :api pipeline.
  scope "/api", TimbreWeb do
    get "/recordings/:id/audio", RecordingController, :audio
  end

  # Production: Phoenix also serves the built React app (see SpaController).
  scope "/", TimbreWeb do
    get "/", SpaController, :index
  end
end
