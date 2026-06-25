Application.put_env(:orkestra, Orkestra.MessageBus,
  adapter: Orkestra.MessageBus.PubSub,
  app_prefix: nil
)

Application.put_env(:orkestra, Orkestra.MessageBus.PubSub, pubsub: Orkestra.PubSub)

{:ok, _} = Phoenix.PubSub.Supervisor.start_link(name: Orkestra.PubSub)

# Postgres integration tests — only when Ecto.Adapters.SQL.Sandbox is available.
# Tests requiring a running database are tagged @tag :postgres and excluded by
# default. CI with a Postgres instance opts in via --include postgres.
if Code.ensure_loaded?(Ecto.Adapters.SQL.Sandbox) do
  Application.put_env(:orkestra, Orkestra.Test.ProjectionRepo,
    url:
      System.get_env(
        "DATABASE_URL",
        "postgres://postgres:postgres@localhost/orkestra_test"
      ),
    migration_source: "orkestra_test_projection_schema_migrations",
    pool: Ecto.Adapters.SQL.Sandbox,
    pool_size: 5
  )

  case Orkestra.Test.ProjectionRepo.start_link() do
    {:ok, _} ->
      Ecto.Adapters.SQL.Sandbox.mode(Orkestra.Test.ProjectionRepo, :manual)

    {:error, reason} ->
      IO.puts("Skipping Postgres tests — ProjectionRepo start failed: #{inspect(reason)}")
      ExUnit.configure(exclude: [:postgres])
  end
end

if Code.ensure_loaded?(Snap.Cluster) do
  # Configure the test ES cluster. Orkestra.Test.ESHTTPAdapter wraps
  # Snap.MockHTTPClient so that child_spec/1 returns :skip (avoiding Mox
  # inter-process ownership issues in the Supervisor init callback) while
  # delegating all request/6 calls to the Mox mock for per-test expectations.
  Application.put_env(:orkestra, Orkestra.Test.ESCluster,
    url: "http://localhost:9200",
    http_client_adapter: Orkestra.Test.ESHTTPAdapter
  )

  # Start the test cluster once for the entire test suite. Tests set per-test
  # Mox expectations on Snap.MockHTTPClient to control HTTP responses.
  case Orkestra.Test.ESCluster.start_link() do
    {:ok, _} ->
      :ok

    {:error, reason} ->
      IO.puts("Skipping Elasticsearch tests — ESCluster start failed: #{inspect(reason)}")
      ExUnit.configure(exclude: [:elasticsearch])
  end
end

ExUnit.start(exclude: [:postgres, :elasticsearch, :integration])
