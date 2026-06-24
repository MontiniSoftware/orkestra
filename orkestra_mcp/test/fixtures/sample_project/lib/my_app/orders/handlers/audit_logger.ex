defmodule MyApp.Orders.Handlers.AuditLogger do
  use Orkestra.EventHandler, topic: "orders.events.*"

  @impl true
  def handle_event(_event, _metadata), do: :ok
end
