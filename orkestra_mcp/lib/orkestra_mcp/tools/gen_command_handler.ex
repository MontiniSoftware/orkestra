defmodule OrkestraMcp.Tools.GenCommandHandler do
  @moduledoc "Generate an Orkestra CommandHandler module bound to a specific Command"

  use Hermes.Server.Component, type: :tool

  schema do
    field(:module_name, :string,
      required: true,
      description: "Full handler module name, e.g. MyApp.Orders.Handlers.PlaceOrderHandler"
    )

    field(:command_module, :string,
      required: true,
      description: "Full command module name, e.g. MyApp.Orders.Commands.PlaceOrder"
    )
  end

  @impl true
  def execute(%{module_name: module_name, command_module: command_module}, _frame) do
    project_dir = Application.get_env(:orkestra_mcp, :project_dir)
    {source, file_path} = OrkestraMcp.Generator.gen_command_handler(module_name, command_module)
    written = OrkestraMcp.Generator.write!(source, project_dir, file_path)
    {:ok, "Created #{written}\n\n```elixir\n#{source}\n```"}
  end
end
