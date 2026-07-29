defmodule MyApp.Orders.Handlers.PlaceOrderHandler do
  use Orkestra.CommandHandler, command: MyApp.Orders.Commands.PlaceOrder

  @impl true
  def execute(_command, _metadata), do: :ok
end
