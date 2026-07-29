defmodule OrderSystem.Orders.Commands.CancelOrder do
  @moduledoc "Command to cancel an existing order."
  use Orkestra.Command

  param(:order_id, :string, required: true)
  param(:reason, :string, default: "customer_request")
end
