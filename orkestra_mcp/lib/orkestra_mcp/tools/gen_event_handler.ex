defmodule OrkestraMcp.Tools.GenEventHandler do
  @moduledoc "Generate an Orkestra EventHandler module with single-event, multi-event, or topic subscription"

  use Hermes.Server.Component, type: :tool

  schema do
    field(:module_name, :string,
      required: true,
      description: "Full handler module name, e.g. MyApp.Orders.Handlers.SendConfirmation"
    )

    field(:opts, :string,
      required: true,
      description:
        "JSON object with mode and details. Example: {\"mode\":\"single\",\"event\":\"MyApp.Events.OrderPlaced\"}"
    )
  end

  @impl true
  def execute(%{module_name: module_name, opts: opts_json}, _frame) do
    project_dir = Application.get_env(:orkestra_mcp, :project_dir)
    opts = Jason.decode!(opts_json)
    {source, file_path} = OrkestraMcp.Generator.gen_event_handler(module_name, opts)
    written = OrkestraMcp.Generator.write!(source, project_dir, file_path)
    {:ok, "Created #{written}\n\n```elixir\n#{source}\n```"}
  end
end
