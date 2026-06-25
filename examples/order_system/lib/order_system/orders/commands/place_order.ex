defmodule OrderSystem.Orders.Commands.PlaceOrder do
  @moduledoc "Command to place a new order."
  use Orkestra.Command

  param :order_id, :string, required: true
  param :product_name, :string, required: true
  param :quantity, :integer, default: 1
  param :price, :float, required: true
  param :customer_email, :string, required: true
end
