defmodule OrderSystem.Orders.Projectors.OrderPostgresProjector do
  @moduledoc """
  Projects order events into a PostgreSQL read model.

  Uses `Orkestra.Projector` with the default Postgres backend.
  Each event handler builds an `Ecto.Multi` fragment that is committed
  atomically alongside the checkpoint update.
  """
  use Orkestra.Projector,
    repo: OrderSystem.Repo,
    event_store: Orkestra.EventStore.InMemory

  project(OrderSystem.Orders.Events.OrderPlaced, fn _event, multi ->
    # For Postgres projectors, we build Ecto.Multi operations
    # In a real app, you'd insert/update Ecto schemas here
    multi
  end)

  project(OrderSystem.Orders.Events.OrderCancelled, fn _event, multi ->
    multi
  end)
end
