defmodule MyApp.Orders.Handlers.UpdateIndex do
  use Orkestra.EventHandler,
    events: [MyApp.Orders.Events.OrderPlaced, MyApp.Orders.Events.OrderCancelled]

  @impl true
  def handle_event(_event, _metadata), do: :ok
end
