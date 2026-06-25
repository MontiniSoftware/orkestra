defmodule OrkestraMcp.Tools.GenEsQueries do
  @moduledoc "Generate an ES Queries module with search/3, list/3, and get_by_id/3 helpers for an ES projection"

  use Hermes.Server.Component, type: :tool

  schema do
    field(:module_name, :string,
      required: true,
      description: "Full ES Queries module name, e.g. MyApp.Orders.ESQueries"
    )

    field(:projector_module, :string,
      required: true,
      description: "The ES projector module, e.g. MyApp.Orders.OrderESProjector"
    )
  end

  @impl true
  def execute(%{module_name: module_name, projector_module: projector_module}, _frame) do
    project_dir = Application.get_env(:orkestra_mcp, :project_dir)

    {source, file_path} = OrkestraMcp.Generator.gen_es_queries(module_name, projector_module)
    written = OrkestraMcp.Generator.write!(source, project_dir, file_path)

    {:ok, "Created #{written}\n\n```elixir\n#{source}\n```"}
  end
end
