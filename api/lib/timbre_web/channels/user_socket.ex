defmodule TimbreWeb.UserSocket do
  @moduledoc """
  WebSocket entry point for live sessions. There are no accounts, so every
  connection is anonymous; participants identify themselves with a display
  name when they join a session topic.
  """
  use Phoenix.Socket

  channel "session:*", TimbreWeb.SessionChannel

  @impl true
  def connect(_params, socket, _connect_info), do: {:ok, socket}

  @impl true
  def id(_socket), do: nil
end
