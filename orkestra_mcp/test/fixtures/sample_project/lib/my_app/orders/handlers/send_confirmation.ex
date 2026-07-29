defmodule MyApp.Orders.Handlers.SendConfirmation do
  use Orkestra.EventHandler, event: MyApp.Orders.Events.OrderPlaced

  @impl true
  def handle_event(_event, _metadata), do: :ok
end
