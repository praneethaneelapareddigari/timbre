defmodule TimbreWeb.ChannelCase do
  @moduledoc "Test case for channel tests, with the database sandbox enabled."
  use ExUnit.CaseTemplate

  using do
    quote do
      import Phoenix.ChannelTest
      import TimbreWeb.ChannelCase

      @endpoint TimbreWeb.Endpoint
    end
  end

  setup tags do
    Timbre.DataCase.setup_sandbox(tags)
    :ok
  end
end
