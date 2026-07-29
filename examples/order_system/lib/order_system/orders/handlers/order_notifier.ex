defmodule OrderSystem.Orders.Handlers.OrderNotifier do
  @moduledoc """
  Reacts to order events by logging notifications.

  In production, this would send emails, push notifications, etc.
  """
  use Orkestra.EventHandler,
    events: [
      OrderSystem.Orders.Events.OrderPlaced,
      OrderSystem.Orders.Events.OrderCancelled
    ]

  require Logger

  @impl true
  def handle_event(%{type: type, data: data}, _metadata) do
    case type do
      "OrderSystem.Orders.Events.OrderPlaced" ->
        Logger.info(
          "Order #{data.order_id} placed: #{data.product_name} x#{data.quantity} = $#{data.total}",
          orkestra: :order_notifier
        )

      "OrderSystem.Orders.Events.OrderCancelled" ->
        Logger.info("Order #{data.order_id} cancelled: #{data.reason}",
          orkestra: :order_notifier
        )
    end

    :ok
  end
end
