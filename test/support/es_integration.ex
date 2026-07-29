if Code.ensure_loaded?(Snap.Cluster) do
  defmodule Orkestra.Test.ESIntegrationCluster do
    @moduledoc """
    A real Snap cluster used exclusively by the integration test suite
    (`test/integration/`, tagged `@moduletag :integration`).

    Unlike `Orkestra.Test.ESCluster` — which is wired to a Mox mock HTTP
    adapter for the unit tests — this cluster uses the default Finch adapter
    and talks to a real Elasticsearch node (from `docker-compose.es.yml`).
    Its configuration is injected at runtime by `Orkestra.Test.ESIntegration`.
    """

    use Snap.Cluster, otp_app: :orkestra
  end

  defmodule Orkestra.Test.ESIntegration do
    @moduledoc """
    Helpers for the `Orkestra.ES` integration suite.

    Provides one-time cluster startup (idempotent across test modules),
    per-run unique index prefixes so parallel/interleaved runs never collide,
    and wildcard index cleanup.
    """

    alias Orkestra.Test.ESIntegrationCluster, as: Cluster

    @doc "The cluster module used by the integration suite."
    def cluster, do: Cluster

    @doc """
    Configures and starts the integration cluster's supervision tree.

    Called once from `test/test_helper.exs`, on the long-lived test-runner
    process, so the Finch pool survives across every integration module.
    Idempotent and non-raising: on any failure it returns `:error` (a default
    `mix test` run without Elasticsearch must not be broken by this). The ES
    URL comes from `ELASTICSEARCH_URL` (default `http://localhost:9200`).
    """
    def start_cluster do
      Application.put_env(:orkestra, Cluster,
        url: System.get_env("ELASTICSEARCH_URL", "http://localhost:9200")
      )

      case Cluster.start_link() do
        {:ok, _pid} -> :ok
        {:error, {:already_started, _pid}} -> :ok
        _ -> :error
      end
    rescue
      _ -> :error
    end

    @doc """
    Prepares the cluster for an integration module.

    Ensures the supervision tree is up (in case `start_cluster/0` was not run)
    and disables `action.destructive_requires_name` so per-run `cleanup/1` can
    delete every index behind a prefix with a single wildcard call (ES 8
    defaults that setting to `true`, which rejects wildcard/_all destructive
    actions). Raises if the cluster is unreachable.
    """
    def ensure_cluster! do
      start_cluster()

      case Snap.put(Cluster, "/_cluster/settings", %{
             "persistent" => %{"action.destructive_requires_name" => false}
           }) do
        {:ok, _} -> :ok
        {:error, reason} -> raise "ES integration cluster unreachable: #{inspect(reason)}"
      end
    end

    @doc """
    Returns a short unique index/alias prefix for a test module.

    `base` is a human-readable discriminator (e.g. `"lifecycle"`). The suffix
    combines a random component and a positive unique integer, so two runs (or
    two modules) never share physical indexes.
    """
    def unique_prefix(base) do
      rand = :crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower)
      "it_#{base}_#{rand}_#{:erlang.unique_integer([:positive])}"
    end

    @doc """
    Deletes every index whose name starts with `prefix` (alias-aware).

    Uses the ES delete-index API with a `<prefix>*` wildcard and
    `ignore_unavailable`, so it is safe to call even when nothing was created.
    Returns `:ok` regardless of the outcome (best-effort cleanup).
    """
    def cleanup(prefix) do
      Snap.delete(Cluster, "/#{prefix}*", ignore_unavailable: true, expand_wildcards: "all")
      :ok
    rescue
      _ -> :ok
    end

    @doc "Refreshes an alias/index so recent writes become searchable."
    def refresh(index) do
      Snap.Indexes.refresh(Cluster, index)
    end

    @doc """
    Compiles a fresh module from `quoted` under a unique name derived from
    `base`, returning the module atom.

    Used by the integration suites to mint schema/repository fixtures whose
    `index:` is a per-run random prefix, so runs never collide and leftover
    state is impossible.
    """
    def define!(base, quoted) do
      mod =
        Module.concat([__MODULE__, :Fixtures, :"#{base}_#{:erlang.unique_integer([:positive])}"])

      {:module, ^mod, _, _} = Module.create(mod, quoted, Macro.Env.location(__ENV__))
      mod
    end
  end
end
