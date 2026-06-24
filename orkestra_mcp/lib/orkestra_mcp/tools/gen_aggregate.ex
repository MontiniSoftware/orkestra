defmodule OrkestraMcp.Tools.GenAggregate do
  @moduledoc "Generate an Orkestra Aggregate module with decide/evolve clauses"

  use Hermes.Server.Component, type: :tool

  schema do
    field(:module_name, :string,
      required: true,
      description: "Full aggregate module name, e.g. MyApp.Orders.OrderAggregate"
    )

    field(:stream_id_field, :string,
      required: true,
      description: "The command param used as stream ID, e.g. order_id"
    )

    field(:commands, :string,
      required: true,
      description: ~s(JSON array of command module names: ["MyApp.Orders.Commands.PlaceOrder"])
    )

    field(:events, :string,
      required: true,
      description: ~s(JSON array of event module names: ["MyApp.Orders.Events.OrderPlaced"])
    )
  end

  @impl true
  def execute(
        %{
          module_name: module_name,
          stream_id_field: stream_id_field,
          commands: commands_json,
          events: events_json
        },
        _frame
      ) do
    project_dir = Application.get_env(:orkestra_mcp, :project_dir)
    commands = Jason.decode!(commands_json)
    events = Jason.decode!(events_json)

    {source, file_path} =
      OrkestraMcp.Generator.gen_aggregate(module_name, stream_id_field, commands, events)

    written = OrkestraMcp.Generator.write!(source, project_dir, file_path)
    {:ok, "Created #{written}\n\n```elixir\n#{source}\n```"}
  end
end
