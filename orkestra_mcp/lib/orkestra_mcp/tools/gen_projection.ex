defmodule OrkestraMcp.Tools.GenProjection do
  @moduledoc "Generate an Orkestra Projector module with project/2 clauses and its isolated migration file"

  use Hermes.Server.Component, type: :tool

  schema do
    field(:module_name, :string,
      required: true,
      description: "Full projector module name, e.g. MyApp.Orders.OrderProjector"
    )

    field(:repo_module, :string,
      required: true,
      description: "The Ecto.Repo module for this projection, e.g. MyApp.OrderProjection.Repo"
    )

    field(:events, :string,
      required: true,
      description: ~s(JSON array of event module names: ["MyApp.Events.OrderPlaced"])
    )
  end

  @impl true
  def execute(%{module_name: module_name, repo_module: repo_module, events: events_json}, _frame) do
    project_dir = Application.get_env(:orkestra_mcp, :project_dir)
    events = Jason.decode!(events_json)

    {projector_source, projector_path} =
      OrkestraMcp.Generator.gen_projection(module_name, repo_module, events)

    {migration_source, migration_path} =
      OrkestraMcp.Generator.gen_projection_migration(module_name)

    written_projector =
      OrkestraMcp.Generator.write!(projector_source, project_dir, projector_path)

    written_migration =
      OrkestraMcp.Generator.write!(migration_source, project_dir, migration_path)

    {:ok,
     "Created #{written_projector}\nCreated #{written_migration}\n\n```elixir\n#{projector_source}\n```"}
  end
end
