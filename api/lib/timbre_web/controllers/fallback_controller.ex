defmodule TimbreWeb.FallbackController do
  @moduledoc "Turns `{:error, _}` results from controller `with` chains into JSON errors."
  use TimbreWeb, :controller

  def call(conn, {:error, %Ecto.Changeset{} = changeset}) do
    conn
    |> put_status(422)
    |> json(%{errors: Ecto.Changeset.traverse_errors(changeset, &translate_error/1)})
  end

  def call(conn, {:error, :not_found}), do: error(conn, :not_found, "not found")

  def call(conn, {:error, :bad_request, message}), do: error(conn, :bad_request, message)

  def call(conn, {:error, :ai_not_configured}) do
    error(conn, :service_unavailable, "transcription is not configured (set OPENAI_API_KEY)")
  end

  def call(conn, {:error, {:ai_failed, message}}), do: error(conn, :bad_gateway, message)

  def call(conn, {:error, reason}), do: error(conn, :internal_server_error, inspect(reason))

  defp error(conn, status, message) do
    conn
    |> put_status(status)
    |> json(%{errors: %{detail: message}})
  end

  defp translate_error({msg, opts}) do
    Enum.reduce(opts, msg, fn {key, value}, acc ->
      String.replace(acc, "%{#{key}}", fn _ -> to_string(value) end)
    end)
  end
end
