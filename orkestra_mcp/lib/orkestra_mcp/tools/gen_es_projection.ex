defmodule OrkestraMcp.Tools.GenEsProjection do
  @moduledoc "Generate an Orkestra ES Projector module with project_es/2 clauses and index_mapping/0"

  use Hermes.Server.Component, type: :tool

  schema do
    field(:module_name, :string,
      required: true,
      description: "Full ES projector module name, e.g. MyApp.Orders.OrderESProjector"
    )

    field(:repo_module, :string,
      required: true,
      description: "The Ecto.Repo module for checkpoint storage, e.g. MyApp.OrderProjection.Repo"
    )

    field(:cluster_module, :string,
      required: true,
      description: "The Snap.Cluster module, e.g. MyApp.ESCluster"
    )

    field(:index, :string,
      required: true,
      description: ~s(The Elasticsearch index name, e.g. "orders")
    )

    field(:events, :string,
      required: true,
      description: ~s(JSON array of event module names: ["MyApp.Events.OrderPlaced"])
    )
  end

  @impl true
  def execute(
        %{
          module_name: module_name,
          repo_module: repo_module,
          cluster_module: cluster_module,
          index: index,
          events: events_json
        },
        _frame
      ) do
    project_dir = Application.get_env(:orkestra_mcp, :project_dir)
    events = Jason.decode!(events_json)

    {source, file_path} =
      OrkestraMcp.Generator.gen_es_projection(
        module_name,
        repo_module,
        cluster_module,
        index,
        events
      )

    written = OrkestraMcp.Generator.write!(source, project_dir, file_path)

    {:ok, "Created #{written}\n\n```elixir\n#{source}\n```"}
  end
end
