defmodule OrderSystem.Orders.Events.OrderCancelled do
  @moduledoc "Emitted when an order is cancelled."
  use Orkestra.Event

  field :order_id, :string, required: true
  field :reason, :string, required: true
  field :cancelled_at, :string, required: true
end
