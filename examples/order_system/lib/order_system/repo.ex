defmodule OrderSystem.Repo do
  use Ecto.Repo,
    otp_app: :order_system,
    adapter: Ecto.Adapters.Postgres
end
