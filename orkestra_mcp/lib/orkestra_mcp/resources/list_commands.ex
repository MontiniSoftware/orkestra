defmodule OrkestraMcp.Resources.ListCommands do
  @moduledoc "Lists all Orkestra Command modules in the project"

  use Hermes.Server.Component,
    type: :resource,
    uri: "orkestra://commands",
    mime_type: "application/json"

  @impl true
  def read(_params, _frame) do
    project_dir = Application.get_env(:orkestra_mcp, :project_dir)
    %{commands: commands} = OrkestraMcp.Introspection.discover(project_dir)
    {:ok, Jason.encode!(commands, pretty: true)}
  end
end
