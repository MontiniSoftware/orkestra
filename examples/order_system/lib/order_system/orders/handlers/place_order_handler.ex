defmodule OrderSystem.Orders.Handlers.PlaceOrderHandler do
  @moduledoc "Handles PlaceOrder commands via the aggregate."
  use Orkestra.CommandHandler,
    command: OrderSystem.Orders.Commands.PlaceOrder

  alias Orkestra.Aggregate.Root
  alias OrderSystem.Orders.OrderAggregate

  @impl true
  def execute(command, _metadata) do
    Root.execute(OrderAggregate, command,
      event_store: Orkestra.EventStore.InMemory,
      bus: Application.get_env(:order_system, :message_bus),
      publish: true
    )
  end
end
