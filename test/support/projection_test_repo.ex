defmodule Orkestra.Test.ProjectionRepo do
  @moduledoc false

  use Ecto.Repo,
    otp_app: :orkestra,
    adapter: Ecto.Adapters.Postgres
end
