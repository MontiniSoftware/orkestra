defmodule MyApp.Inventory.Commands.TrackStock do
  use Orkestra.Command

  param(:sku, :string, required: true)
  param(:warehouse_id, :string, required: true)
end
