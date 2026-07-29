defmodule OrkestraMcp.Tools.GenQueries do
  @moduledoc "Generate a Queries module with list/2 and get_by/2 helpers for a read model"

  use Hermes.Server.Component, type: :tool

  schema do
    field(:module_name, :string,
      required: true,
      description: "Full Queries module name, e.g. MyApp.Orders.Queries"
    )

    field(:schema_module, :string,
      required: true,
      description: "The Ecto schema module to query, e.g. MyApp.Orders.OrderReadModel"
    )
  end

  @impl true
  def execute(%{module_name: module_name, schema_module: schema_module}, _frame) do
    project_dir = Application.get_env(:orkestra_mcp, :project_dir)

    {source, file_path} = OrkestraMcp.Generator.gen_queries(module_name, schema_module)
    written = OrkestraMcp.Generator.write!(source, project_dir, file_path)

    {:ok, "Created #{written}\n\n```elixir\n#{source}\n```"}
  end
end
