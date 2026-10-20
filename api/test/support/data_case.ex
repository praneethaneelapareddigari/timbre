defmodule Timbre.DataCase do
  @moduledoc """
  Test case for tests that touch the database. Each test runs inside a
  sandboxed transaction that is rolled back afterwards.
  """
  use ExUnit.CaseTemplate

  using do
    quote do
      alias Timbre.Repo

      import Ecto
      import Ecto.Changeset
      import Ecto.Query
      import Timbre.DataCase
    end
  end

  setup tags do
    Timbre.DataCase.setup_sandbox(tags)
    :ok
  end

  @doc """
  Checks out a sandbox connection. Non-async tests share it with every process
  (session servers, channel processes) so they can write too.
  """
  def setup_sandbox(tags) do
    pid = Ecto.Adapters.SQL.Sandbox.start_owner!(Timbre.Repo, shared: not tags[:async])
    ExUnit.Callbacks.on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)
  end

  def errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
