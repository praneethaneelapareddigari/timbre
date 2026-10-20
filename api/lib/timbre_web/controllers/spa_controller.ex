defmodule TimbreWeb.SpaController do
  @moduledoc """
  Serves the built React app's `index.html` in production, where Phoenix hosts
  the frontend too (single origin, so the API and WebSocket need no CORS).
  In development the Vite server on :5173 serves the UI instead.
  """
  use TimbreWeb, :controller

  def index(conn, _params) do
    path = Application.app_dir(:timbre, "priv/static/index.html")

    if File.exists?(path) do
      conn
      |> put_resp_content_type("text/html")
      |> put_resp_header("cache-control", "no-cache")
      |> send_file(200, path)
    else
      conn
      |> put_resp_content_type("text/plain")
      |> send_resp(404, "Frontend not built. In development, open http://localhost:5173.")
    end
  end
end
