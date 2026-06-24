import Config

# MCP stdio requires clean stdout — all logs to stderr, warnings only
config :logger, :default_handler,
  config: %{
    type: :standard_error
  }

config :logger, level: :warning

if config_env() == :test do
  config :orkestra_mcp, start_server: false
end
