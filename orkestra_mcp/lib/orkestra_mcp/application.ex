defmodule OrkestraMcp.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children =
      if Application.get_env(:orkestra_mcp, :start_server, true) do
        [
          Hermes.Server.Registry,
          {OrkestraMcp.Server, transport: :stdio}
        ]
      else
        []
      end

    opts = [strategy: :one_for_one, name: OrkestraMcp.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
