defmodule OrkestraMcp.Tools.GenEvent do
  @moduledoc "Generate an Orkestra Event module with typed fields"

  use Hermes.Server.Component, type: :tool

  schema do
    field(:module_name, :string,
      required: true,
      description: "Full module name, e.g. MyApp.Orders.Events.OrderPlaced"
    )

    field(:fields, :string,
      required: true,
      description: ~s(JSON array of fields: [{"name":"order_id","type":"string","required":true}])
    )
  end

  @impl true
  def execute(%{module_name: module_name, fields: fields_json}, _frame) do
    project_dir = Application.get_env(:orkestra_mcp, :project_dir)
    fields = Jason.decode!(fields_json)
    {source, file_path} = OrkestraMcp.Generator.gen_event(module_name, fields)
    written = OrkestraMcp.Generator.write!(source, project_dir, file_path)
    {:ok, "Created #{written}\n\n```elixir\n#{source}\n```"}
  end
end
