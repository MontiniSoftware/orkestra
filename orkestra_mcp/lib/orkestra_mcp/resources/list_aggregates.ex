defmodule OrkestraMcp.Resources.ListAggregates do
  @moduledoc "Lists all Orkestra Aggregate modules in the project"

  use Hermes.Server.Component,
    type: :resource,
    uri: "orkestra://aggregates",
    mime_type: "application/json"

  @impl true
  def read(_params, _frame) do
    project_dir = Application.get_env(:orkestra_mcp, :project_dir)
    %{aggregates: aggregates} = OrkestraMcp.Introspection.discover(project_dir)
    {:ok, Jason.encode!(aggregates, pretty: true)}
  end
end
