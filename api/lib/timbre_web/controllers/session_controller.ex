defmodule TimbreWeb.SessionController do
  @moduledoc """
  `POST /api/sessions` mints a share code and starts its session process.
  Joining happens over the `session:<code>` channel.
  """
  use TimbreWeb, :controller

  alias Timbre.Sessions

  def create(conn, _params) do
    code = Sessions.new_code()
    {:ok, _pid} = Sessions.ensure_started(code)

    conn
    |> put_status(:created)
    |> json(%{data: %{code: code, sample_rate: Sessions.sample_rate()}})
  end

  def show(conn, %{"code" => code}) do
    case Sessions.valid_code?(code) && Sessions.whereis(code) do
      pid when is_pid(pid) -> json(conn, %{data: Sessions.snapshot(pid)})
      _ -> conn |> put_status(:not_found) |> json(%{errors: %{detail: "no such session"}})
    end
  end
end
