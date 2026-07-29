defmodule OrkestraMcp.Resources.ListProjections do
  @moduledoc "Lists all Orkestra Projector modules in the project"

  use Hermes.Server.Component,
    type: :resource,
    uri: "orkestra://projections",
    mime_type: "application/json"

  @impl true
  def read(_params, _frame) do
    project_dir = Application.get_env(:orkestra_mcp, :project_dir)
    %{projectors: projectors} = OrkestraMcp.Introspection.discover(project_dir)
    {:ok, Jason.encode!(projectors, pretty: true)}
  end
end
