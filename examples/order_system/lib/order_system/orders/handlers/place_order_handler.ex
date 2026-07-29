defmodule OrderSystem.Orders.Handlers.PlaceOrderHandler do
  @moduledoc "Handles PlaceOrder commands via the aggregate."
  use Orkestra.CommandHandler,
    command: OrderSystem.Orders.Commands.PlaceOrder

  alias Orkestra.Aggregate.Root
  alias OrderSystem.Orders.OrderAggregate

  @impl true
  def execute(command, _metadata) do
    case Root.execute(OrderAggregate, command,
           event_store: Orkestra.EventStore.InMemory,
           bus: Orkestra.MessageBus.impl(),
           publish: true
         ) do
      {:ok, _events, _state} -> :ok
      {:ok, _events} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end
end
