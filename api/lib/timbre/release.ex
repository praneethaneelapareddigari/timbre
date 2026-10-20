defmodule Timbre.Release do
  @moduledoc """
  Tasks run inside the production release, where Mix isn't available:

      bin/timbre eval "Timbre.Release.migrate()"
  """
  @app :timbre

  def migrate do
    Application.load(@app)

    for repo <- Application.fetch_env!(@app, :ecto_repos) do
      {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true))
    end
  end
end
