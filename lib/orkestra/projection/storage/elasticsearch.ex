if Code.ensure_loaded?(Snap.Cluster) do
  defmodule Orkestra.Projection.Storage.Elasticsearch do
    @moduledoc """
    Elasticsearch/OpenSearch storage adapter implementing `Orkestra.Projection.Storage`.

    ## Overview

    This adapter wires Orkestra projectors to Elasticsearch or OpenSearch as the
    read-model backend. It detects the engine at startup (ES 8.x vs OpenSearch 2.x),
    creates the projection index with strict mappings on first start, and returns
    pure write descriptors for each event — no HTTP is performed in `write/4`.

    ## write/4

    Returns a descriptor map describing the write operation for one event:

    - `{:ok, %{action: :index, id: id, doc: doc}}` — full-document upsert with
      a deterministic `_id`. The GenServer (Phase 7) owns `Snap.Document.index/6`.
    - `{:ok, %{action: :skip}}` — event handler returned `:skip`; no write needed.
    - `{:error, reason}` — handler returned an error.

    **`write/4` never calls `Snap.Document.index` or any HTTP function.** It is
    purely functional. The calling GenServer controls when and how to commit.

    ## reset/2

    Deletes all documents in the projection index via `_delete_by_query` with a
    `match_all` query. Used during rebuild (Phase 9) before replaying the event
    stream from position 0.

    ## Required adapter_opts

    When wiring up a projector with this adapter, the following opts are required:

    - `:cluster` — the `Snap.Cluster` module to use (e.g. `MyApp.ESCluster`)
    - `:index` — the Elasticsearch index name (e.g. `"orders"`)
    - `:handler` — 3-arity function `(projector_name, event, position) ->
      {:ok, doc, id} | :skip | {:error, reason}`

    For `reset/2`, also requires:

    - `:cluster` — the `Snap.Cluster` module
    - `:index` — the Elasticsearch index name

    ## init/1

    Called at projector startup (Phase 7 GenServer). Runs engine detection and
    ensures the index exists with `dynamic: strict` enforced on all mappings.
    Returns `{:ok, state}` where state includes `:cluster`, `:index`, and
    `:engine` (`:elasticsearch` or `:opensearch`).

    ## Security

    Credentials (Basic Auth or API key) flow from application config into the
    Snap cluster's HTTP `Authorization` header. **Never commit credentials to
    source control.** Use runtime configuration and a secrets manager in
    production. Always use `https://` in production clusters.

    ## Engine Detection

    At startup, `init/1` calls `GET /` on the cluster to detect the engine:

    - Response contains `version.distribution: "opensearch"` → `:opensearch`
    - Response contains `version` without `distribution` → `:elasticsearch`
    - Connection failure → defaults to `:elasticsearch` with a warning log

    The detected engine atom is stored in adapter state for downstream use by
    the GenServer (Phase 7) and future phases.
    """

    require Logger
    require OpenTelemetry.Tracer, as: Tracer

    @behaviour Orkestra.Projection.Storage

    @doc """
    Initialises the adapter at projector startup.

    Detects the ES/OpenSearch engine, creates the projection index with strict
    mappings if needed, and returns an adapter state map.

    Requires opts:
    - `:cluster` — the `Snap.Cluster` module
    - `:index` — the index name string
    - `:projector_module` — the projector module that implements `index_mapping/0`

    Returns `{:ok, %{cluster: cluster, index: index, engine: engine}}` or
    `{:error, reason}` if index creation fails.
    """
    @impl true
    @spec init(keyword()) :: {:ok, map()} | {:error, term()}
    def init(opts) do
      cluster = Keyword.fetch!(opts, :cluster)
      index = Keyword.fetch!(opts, :index)
      projector_module = Keyword.fetch!(opts, :projector_module)

      Tracer.with_span "orkestra.es.init", %{"es.index" => index} do
        with {:ok, engine} <- detect_engine(cluster),
             :ok <- ensure_index(cluster, index, projector_module) do
          {:ok, %{cluster: cluster, index: index, engine: engine}}
        end
      end
    end

    @doc """
    Returns a write descriptor for applying `event` to the Elasticsearch read model.

    The `:handler` option must be a 3-arity function:

        (projector_name :: String.t(), event :: map(), position :: non_neg_integer())
        -> {:ok, doc :: map(), id :: String.t()} | :skip | {:error, reason :: term()}

    Returns:
    - `{:ok, %{action: :index, id: id, doc: doc}}` when handler returns `{:ok, doc, id}`
    - `{:ok, %{action: :skip}}` when handler returns `:skip`
    - `{:error, reason}` when handler returns `{:error, reason}`

    **Does not perform any HTTP calls.** The calling GenServer owns execution.
    """
    @impl true
    @spec write(
            Orkestra.Projection.Storage.projector_name(),
            Orkestra.Projection.Storage.event(),
            non_neg_integer(),
            Orkestra.Projection.Storage.opts()
          ) :: {:ok, map()} | {:error, term()}
    def write(projector_name, event, position, opts) do
      handler = Keyword.fetch!(opts, :handler)

      case handler.(projector_name, event, position) do
        {:ok, doc, id} when is_map(doc) and is_binary(id) ->
          {:ok, %{action: :index, id: id, doc: doc}}

        :skip ->
          {:ok, %{action: :skip}}

        {:error, reason} ->
          {:error, reason}
      end
    end

    @doc """
    Deletes all documents in the projection index via `_delete_by_query`.

    Uses a `match_all` query to clear the entire index. This is a destructive
    operation intended for projector rebuild (Phase 9). After `reset/2`, a
    subsequent replay of the event stream will rebuild the read model.

    Idempotent: returns `:ok` even when the index does not exist yet
    (e.g. on first start before `init/1` has run, or after manual index
    deletion). An `index_not_found_exception` from ES/OpenSearch is treated
    as a no-op — the index is already empty.

    Requires opts:
    - `:cluster` — the `Snap.Cluster` module
    - `:index` — the index name string

    Returns `:ok` on success or `{:error, {:reset_failed, reason}}` on failure.
    """
    @impl true
    @spec reset(
            Orkestra.Projection.Storage.projector_name(),
            Orkestra.Projection.Storage.opts()
          ) :: :ok | {:error, term()}
    def reset(_projector_name, opts) do
      cluster = Keyword.fetch!(opts, :cluster)
      index = Keyword.fetch!(opts, :index)

      body = %{"query" => %{"match_all" => %{}}}

      case Snap.post(cluster, "/#{index}/_delete_by_query", body) do
        {:ok, _} ->
          :ok

        {:error, %Snap.ResponseError{type: "index_not_found_exception"}} ->
          # Index does not exist — reset is a no-op (state is already empty).
          :ok

        {:error, reason} ->
          {:error, {:reset_failed, reason}}
      end
    end

    # -------------------------------------------------------------------------
    # Private helpers
    # -------------------------------------------------------------------------

    # Detects the ES/OpenSearch engine by calling GET / on the cluster.
    # Snap.Request.request/7 validates paths and rejects "/" because the URI
    # split produces an empty segment. We bypass path validation by calling
    # auth.sign/5 and Snap.HTTPClient.request/6 directly — this keeps full
    # authentication (API key or Basic Auth) while avoiding the path check.
    # Defaults to :elasticsearch on any connection or auth failure (T-06-05).
    defp detect_engine(cluster) do
      config = cluster.config()
      json_library = cluster.json_library()
      base_url = Keyword.fetch!(config, :url)
      auth = Keyword.get(config, :auth, Snap.Auth.Plain)

      default_headers = [{"content-type", "application/json"}, {"accept", "application/json"}]

      with {:ok, {method, signed_url, signed_headers, signed_body}} <-
             auth.sign(config, :get, base_url, default_headers, nil),
           {:ok, %Snap.HTTPClient.Response{status: 200, body: body}} <-
             Snap.HTTPClient.request(cluster, method, signed_url, signed_headers, signed_body) do
        case json_library.decode(body) do
          {:ok, %{"version" => %{"distribution" => "opensearch"}}} ->
            {:ok, :opensearch}

          {:ok, %{"version" => _}} ->
            {:ok, :elasticsearch}

          _ ->
            {:ok, :elasticsearch}
        end
      else
        {:ok, _response} ->
          {:ok, :elasticsearch}

        {:error, reason} ->
          Logger.warning(
            "ES engine detection failed — defaulting to :elasticsearch",
            reason: inspect(reason),
            orkestra: :projector
          )

          {:ok, :elasticsearch}
      end
    end

    # Creates the projection index with dynamic: strict injected into the
    # mappings block (T-06-03 mitigation — prevents mapping explosion).
    # Returns :ok if index already exists (idempotent on restart).
    defp ensure_index(cluster, index_name, projector_module) do
      user_mapping = projector_module.index_mapping()

      # Injects dynamic: "strict" into the mappings block unconditionally,
      # overriding any user-supplied value — prevents mapping explosion (T-06-03).
      mapping_with_strict =
        Map.update(user_mapping, "mappings", %{"dynamic" => "strict"}, fn m ->
          Map.put(m, "dynamic", "strict")
        end)

      Tracer.with_span "orkestra.es.ensure_index", %{"es.index" => index_name} do
        case Snap.Indexes.create(cluster, index_name, mapping_with_strict) do
          {:ok, _} ->
            :ok

          {:error, %Snap.ResponseError{type: "resource_already_exists_exception"}} ->
            # Idempotent on restart — index already exists is not an error
            :ok

          {:error, reason} ->
            Tracer.set_status(:error, inspect(reason))

            Logger.warning(
              "ES index creation failed",
              index: index_name,
              reason: inspect(reason),
              orkestra: :projector
            )

            {:error, {:index_creation_failed, reason}}
        end
      end
    end
  end
end
