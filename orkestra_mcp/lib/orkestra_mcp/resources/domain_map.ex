defmodule OrkestraMcp.Resources.DomainMap do
  @moduledoc "Cross-references commands, events, handlers, and aggregates into a readable domain map"

  use Hermes.Server.Component,
    type: :resource,
    uri: "orkestra://domain-map",
    mime_type: "text/plain"

  @impl true
  def read(_params, _frame) do
    project_dir = Application.get_env(:orkestra_mcp, :project_dir)
    map = OrkestraMcp.Introspection.build_domain_map(project_dir)
    {:ok, map}
  end
end
