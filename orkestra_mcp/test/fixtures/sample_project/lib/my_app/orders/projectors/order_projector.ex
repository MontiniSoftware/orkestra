defmodule MyApp.Orders.Projectors.OrderProjector do
  use Orkestra.Projector,
    repo: MyApp.OrderProjection.Repo,
    event_store: Orkestra.EventStore.InMemory

  project MyApp.Orders.Events.OrderPlaced, fn event, multi ->
    multi
  end

  project MyApp.Orders.Events.OrderCancelled, fn event, multi ->
    multi
  end
end
