defmodule MyApp.Orders.Commands.PlaceOrder do
  use Orkestra.Command

  param(:product_id, :string, required: true)
  param(:quantity, :integer, default: 1)
end
