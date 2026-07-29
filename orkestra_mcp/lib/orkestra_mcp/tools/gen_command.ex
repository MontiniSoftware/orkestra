defmodule OrkestraMcp.Tools.GenCommand do
  @moduledoc "Generate an Orkestra Command module with typed params"

  use Hermes.Server.Component, type: :tool

  schema do
    field(:module_name, :string,
      required: true,
      description: "Full module name, e.g. MyApp.Orders.Commands.PlaceOrder"
    )

    field(:params, :string,
      required: true,
      description:
        ~s(JSON array of params: [{"name":"product_id","type":"string","required":true}])
    )
  end

  @impl true
  def execute(%{module_name: module_name, params: params_json}, _frame) do
    project_dir = Application.get_env(:orkestra_mcp, :project_dir)
    params = Jason.decode!(params_json)
    {source, file_path} = OrkestraMcp.Generator.gen_command(module_name, params)
    written = OrkestraMcp.Generator.write!(source, project_dir, file_path)
    {:ok, "Created #{written}\n\n```elixir\n#{source}\n```"}
  end
end
