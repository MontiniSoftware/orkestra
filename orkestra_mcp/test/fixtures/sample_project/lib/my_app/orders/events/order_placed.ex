defmodule MyApp.Orders.Events.OrderPlaced do
  use Orkestra.Event

  field(:order_id, :string, required: true)
  field(:product_id, :string, required: true)
  field(:quantity, :integer)
end
