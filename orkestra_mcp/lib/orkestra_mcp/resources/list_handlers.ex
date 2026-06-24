defmodule OrkestraMcp.Resources.ListHandlers do
  @moduledoc "Lists all Orkestra CommandHandler and EventHandler modules in the project"

  use Hermes.Server.Component,
    type: :resource,
    uri: "orkestra://handlers",
    mime_type: "application/json"

  @impl true
  def read(_params, _frame) do
    project_dir = Application.get_env(:orkestra_mcp, :project_dir)

    %{command_handlers: ch, event_handlers: eh} =
      OrkestraMcp.Introspection.discover(project_dir)

    result = %{command_handlers: ch, event_handlers: eh}
    {:ok, Jason.encode!(result, pretty: true)}
  end
end
