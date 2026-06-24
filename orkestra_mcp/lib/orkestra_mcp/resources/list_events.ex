defmodule OrkestraMcp.Resources.ListEvents do
  @moduledoc "Lists all Orkestra Event modules in the project"

  use Hermes.Server.Component,
    type: :resource,
    uri: "orkestra://events",
    mime_type: "application/json"

  @impl true
  def read(_params, _frame) do
    project_dir = Application.get_env(:orkestra_mcp, :project_dir)
    %{events: events} = OrkestraMcp.Introspection.discover(project_dir)
    {:ok, Jason.encode!(events, pretty: true)}
  end
end
