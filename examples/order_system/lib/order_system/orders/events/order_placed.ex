defmodule OrderSystem.Orders.Events.OrderPlaced do
  @moduledoc "Emitted when a new order is placed."
  use Orkestra.Event

  field(:order_id, :string, required: true)
  field(:product_name, :string, required: true)
  field(:quantity, :integer, required: true)
  field(:price, :float, required: true)
  field(:customer_email, :string, required: true)
  field(:total, :float, required: true)
end
