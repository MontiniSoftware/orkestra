if Code.ensure_loaded?(Snap.Cluster) do
  defmodule Orkestra.ES.Index do
    @moduledoc """
    Elasticsearch/OpenSearch index lifecycle utilities.

    Provides two layers of functionality:

      * **Low-level primitives** — `detect_engine/1` (distribution detection) and
        `ensure_index/3` (idempotent index creation with automatic
        `dynamic: "strict"` injection).

      * **Schema lifecycle** — `setup/3`, `status/3`, `migrate/3`, and their
        `*_all/2` batch variants, which manage the alias + versioned-index
        topology for an `Orkestra.ES.Schema` (one alias per culture). These use
        the same physical index naming convention as `Snap.Indexes.hotswap/5`
        so that `Snap.Indexes.cleanup/4` and `list_starting_with/3` recognise
        the indexes they create.

    ## Alias + versioning model

    Every schema × culture maps to a stable **alias** (`schema.alias_for/1`)
    that points to a **versioned physical index** named `"\#{alias}-\#{unix_µs}"`.
    The physical mapping carries the schema's mapping hash under
    `mappings._meta.orkestra_schema_hash`, which lets `status/3` detect drift
    between the deployed mapping and the current schema definition.

    Migrations reindex zero-downtime via `Snap.Indexes.hotswap/5`: a fresh
    versioned index is created, every document currently behind the alias is
    streamed (`Snap.Scroll`) into it, then the alias is atomically swapped and
    old indexes are cleaned up.

    ### Consistency window

    `migrate/4` does **not** capture writes that happen concurrently with the
    reindex — documents indexed after the scroll snapshot but before the alias
    swap are not carried over. Coordinating the write path during a migration is
    the caller's responsibility, exactly as it is for a projection rebuild.

    ## Observability

    Each lifecycle operation opens an OpenTelemetry span (`orkestra.es.setup`,
    `orkestra.es.status`, `orkestra.es.migrate`) carrying the `es.index` (alias)
    and, when applicable, `es.culture` attributes. `migrate/4` records a span
    event with the outcome. Structured logs use the `orkestra: :es` tag and
    never include cluster credentials or adapter options.
    """

    require Logger
    require OpenTelemetry.Tracer, as: Tracer

    @meta_key "orkestra_schema_hash"

    @typedoc "A schema module implementing the `Orkestra.ES.Schema` contract."
    @type schema :: module()

    @typedoc "Result map returned by `status/3`."
    @type status_result :: %{
            alias: String.t(),
            exists: boolean(),
            physical_index: String.t() | nil,
            current_hash: String.t() | nil,
            schema_hash: String.t(),
            drift?: boolean()
          }

    # =========================================================================
    # Low-level primitives
    # =========================================================================

    @doc """
    Detects the Elasticsearch or OpenSearch engine version.

    Calls `GET /` on the cluster to inspect the version response:

    - Response contains `version.distribution: "opensearch"` → `:opensearch`
    - Response contains `version` without `distribution` → `:elasticsearch`
    - Connection failure or error → defaults to `:elasticsearch` with a warning

    Returns `{:ok, :elasticsearch | :opensearch}`.

    ## Implementation Notes

    `Snap.Request.request/7` validates paths and rejects "/" because the URI
    split produces an empty segment. We bypass path validation by calling
    `auth.sign/5` and `Snap.HTTPClient.request/6` directly — this keeps full
    authentication (API key or Basic Auth) while avoiding the path check.

    Defaults to `:elasticsearch` on any connection or auth failure (defensive
    fallback for distributed deployments).
    """
    @spec detect_engine(module()) :: {:ok, :elasticsearch | :opensearch}
    def detect_engine(cluster) do
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
            orkestra: :es
          )

          {:ok, :elasticsearch}
      end
    end

    @doc """
    Creates an Elasticsearch index with strict dynamic mapping enforcement.

    Idempotent: returns `:ok` immediately if the index already exists.

    The `mapping` parameter is injected with `"dynamic" => "strict"` in the
    `"mappings"` block unconditionally, preventing mapping explosion attacks
    (T-06-03 mitigation). Any user-supplied `dynamic` value in the input is
    overridden.

    Returns:
    - `:ok` — index created or already exists
    - `{:error, {:index_creation_failed, reason}}` — creation failed

    ## Parameters

    - `cluster` — the `Snap.Cluster` module
    - `index_name` — the index name string (e.g., `"orders"`)
    - `mapping` — the Elasticsearch mapping map with `"mappings"` and optional
      analysis settings (the `dynamic: "strict"` injection happens here)

    ## Observability

    Emits an OpenTelemetry span `orkestra.es.ensure_index` with `{"es.index"}`
    attribute. On creation failure, logs with `orkestra: :es` metadata and sets
    span status to error.
    """
    @spec ensure_index(module(), String.t(), map()) ::
            :ok | {:error, {:index_creation_failed, term()}}
    def ensure_index(cluster, index_name, mapping) do
      mapping_with_strict = inject_strict(mapping)

      Tracer.with_span "orkestra.es.ensure_index", %{attributes: %{"es.index" => index_name}} do
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
              orkestra: :es
            )

            {:error, {:index_creation_failed, reason}}
        end
      end
    end

    # =========================================================================
    # Schema lifecycle: setup
    # =========================================================================

    @doc """
    Ensures the alias + versioned index for `schema` (and `culture`) exists.

    For a mono-culture schema pass `culture` as `nil` (the default). For a
    multi-culture schema pass one of the declared cultures.

    Behaviour:

      * If the alias already exists → `{:ok, :already_exists}` (no changes).
      * Otherwise a versioned physical index (`"\#{alias}-\#{unix_µs}"`) is
        created with the schema mapping — `dynamic: "strict"` and
        `mappings._meta.orkestra_schema_hash` injected — and the alias is
        pointed at it via `Snap.Indexes.alias/4`.

    Returns `{:ok, :created | :already_exists}` or `{:error, reason}`.
    """
    @spec setup(module(), schema(), atom() | nil) ::
            {:ok, :created | :already_exists} | {:error, term()}
    def setup(cluster, schema, culture \\ nil) do
      {alias, mapping, hash} = resolve(schema, culture)
      physical_mapping = build_physical_mapping(mapping, hash)

      Tracer.with_span "orkestra.es.setup", %{attributes: span_attrs(alias, culture)} do
        case alias_exists?(cluster, alias) do
          {:ok, true} ->
            {:ok, :already_exists}

          {:ok, false} ->
            case create_index(cluster, alias, physical_mapping) do
              {:ok, :created} = ok ->
                Logger.info("ES index set up", index: alias, culture: culture, orkestra: :es)
                ok

              {:error, reason} ->
                fail("setup", alias, reason)
            end

          {:error, reason} ->
            fail("setup", alias, reason)
        end
      end
    end

    @doc """
    Runs `setup/3` for every culture of `schema`.

    A mono-culture schema is set up once with `culture` `nil`. Iteration stops
    at the first failure.

    Returns `{:ok, [{culture | nil, :created | :already_exists}]}` or
    `{:error, {culture, reason}}`.
    """
    @spec setup_all(module(), schema()) ::
            {:ok, [{atom() | nil, :created | :already_exists}]} | {:error, {atom() | nil, term()}}
    def setup_all(cluster, schema), do: run_all(cluster, schema, &setup/3)

    @doc """
    Builds the physical index mapping for `schema` (and `culture`).

    This is the exact mapping used behind the alias by `setup/3` and `migrate/4`:
    the schema mapping with `dynamic: "strict"` and the
    `mappings._meta.orkestra_schema_hash` drift marker injected. Pass `culture`
    as `nil` (the default) for a mono-culture schema, or one of the declared
    cultures for a multi-culture schema.

    Exposed so callers that drive their own reindex — notably the
    `mix orkestra.projection.es.rebuild` task via `Snap.Indexes.hotswap/5` — use
    the same physical mapping (hash included) as the lifecycle helpers, keeping
    `status/3` drift detection accurate after a rebuild.
    """
    @spec physical_mapping(schema(), atom() | nil) :: map()
    def physical_mapping(schema, culture \\ nil) do
      {_alias, mapping, hash} = resolve(schema, culture)
      build_physical_mapping(mapping, hash)
    end

    # =========================================================================
    # Schema lifecycle: status
    # =========================================================================

    @doc """
    Reports the deployed state of the alias for `schema` (and `culture`).

    Reads the physical index behind the alias and compares its stored
    `mappings._meta.orkestra_schema_hash` with the current schema hash.

    Returns `{:ok, status}` where `status` is a map with:

      * `:alias` — the alias name
      * `:exists` — whether the alias currently resolves to an index
      * `:physical_index` — the physical index name, or `nil` when absent
      * `:current_hash` — the deployed mapping hash, or `nil` when the index was
        created outside Orkestra (no `_meta`)
      * `:schema_hash` — the current schema's mapping hash
      * `:drift?` — `true` when the deployed mapping differs from the schema
        (including the missing-`_meta` case); `false` when the alias is absent
        or in sync

    Returns `{:error, reason}` on an unexpected cluster error.
    """
    @spec status(module(), schema(), atom() | nil) :: {:ok, status_result()} | {:error, term()}
    def status(cluster, schema, culture \\ nil) do
      {alias, _mapping, hash} = resolve(schema, culture)

      Tracer.with_span "orkestra.es.status", %{attributes: span_attrs(alias, culture)} do
        do_status(cluster, alias, hash)
      end
    end

    # =========================================================================
    # Schema lifecycle: migrate
    # =========================================================================

    @doc """
    Brings the alias for `schema` (and `culture`) in line with the schema.

    Behaviour:

      * Alias absent → delegates to `setup/3`, returning `{:ok, :created}`.
      * No drift → `{:ok, :noop}` (no changes).
      * Drift → zero-downtime reindex: every document behind the alias is
        streamed via `Snap.Scroll` and re-indexed into a fresh versioned index
        through `Snap.Indexes.hotswap/5`, which then swaps the alias and cleans
        up old indexes. Returns `{:ok, :migrated}`.

    ## Options

      * `:batch_size` — scroll page size for the reindex (default `500`).
      * `:page_size`, `:page_wait`, `:max_errors`, `:request_opts` — forwarded
        to `Snap.Indexes.hotswap/5`.
      * `:scroll`, `:params`, `:headers`, `:opts` — forwarded to
        `Snap.Scroll.stream/4`.

    ## Consistency window

    Writes issued during the reindex window are not migrated (see the module
    doc). Coordinate the write path externally, as with a projection rebuild.

    Returns `{:ok, :noop | :created | :migrated}` or `{:error, reason}`.
    """
    @spec migrate(module(), schema(), atom() | nil, keyword()) ::
            {:ok, :noop | :created | :migrated} | {:error, term()}
    def migrate(cluster, schema, culture \\ nil, opts \\ []) do
      {alias, mapping, hash} = resolve(schema, culture)
      physical_mapping = build_physical_mapping(mapping, hash)

      Tracer.with_span "orkestra.es.migrate", %{attributes: span_attrs(alias, culture)} do
        result =
          case do_status(cluster, alias, hash) do
            {:ok, %{exists: false}} ->
              create_index(cluster, alias, physical_mapping)

            {:ok, %{drift?: false}} ->
              {:ok, :noop}

            {:ok, %{drift?: true}} ->
              do_reindex(cluster, alias, physical_mapping, opts)

            {:error, reason} ->
              {:error, reason}
          end

        record_migrate_result(alias, culture, result)
        result
      end
    end

    @doc """
    Runs `migrate/4` for every culture of `schema`.

    A mono-culture schema is migrated once with `culture` `nil`. Iteration stops
    at the first failure.

    Returns `{:ok, [{culture | nil, :noop | :created | :migrated}]}` or
    `{:error, {culture, reason}}`.
    """
    @spec migrate_all(module(), schema()) ::
            {:ok, [{atom() | nil, :noop | :created | :migrated}]}
            | {:error, {atom() | nil, term()}}
    def migrate_all(cluster, schema), do: run_all(cluster, schema, &migrate/3)

    # =========================================================================
    # Internal helpers
    # =========================================================================

    # Resolves the alias, mapping, and mapping hash for the given culture.
    # `nil` targets the mono-culture / default-culture API of the schema.
    defp resolve(schema, nil) do
      {schema.alias_for(), schema.mapping(), schema.mapping_hash()}
    end

    defp resolve(schema, culture) do
      {schema.alias_for(culture), schema.mapping(culture), schema.mapping_hash(culture)}
    end

    # Returns the culture list, normalising a mono-culture schema to `[nil]`.
    defp cultures_of(schema) do
      case schema.__es_schema__(:cultures) do
        [] -> [nil]
        list -> list
      end
    end

    defp run_all(cluster, schema, fun) do
      schema
      |> cultures_of()
      |> Enum.reduce_while({:ok, []}, fn culture, {:ok, acc} ->
        case fun.(cluster, schema, culture) do
          {:ok, result} -> {:cont, {:ok, [{culture, result} | acc]}}
          {:error, reason} -> {:halt, {:error, {culture, reason}}}
        end
      end)
      |> case do
        {:ok, acc} -> {:ok, Enum.reverse(acc)}
        {:error, _} = err -> err
      end
    end

    # Injects `dynamic: "strict"` into the mappings block, overriding any
    # user-supplied value (T-06-03 mitigation). Shared with `ensure_index/3`.
    defp inject_strict(mapping) do
      Map.update(mapping, "mappings", %{"dynamic" => "strict"}, fn m ->
        Map.put(m, "dynamic", "strict")
      end)
    end

    # Injects the schema mapping hash under `mappings._meta.orkestra_schema_hash`
    # so drift detection can compare the deployed mapping to the schema.
    defp put_meta_hash(mapping, hash) do
      update_in(mapping, ["mappings"], fn m ->
        meta = m |> Map.get("_meta", %{}) |> Map.put(@meta_key, hash)
        Map.put(m, "_meta", meta)
      end)
    end

    defp build_physical_mapping(mapping, hash) do
      mapping |> inject_strict() |> put_meta_hash(hash)
    end

    # Mirrors `Snap.Indexes` private `generate_index_name/1`
    # (`"\#{alias}-\#{DateTime.to_unix(now, :microsecond)}"`) so that hotswap,
    # `list_starting_with/3` (regex `^prefix-[0-9]+$`) and `cleanup/4` all
    # recognise the indexes we create outside of hotswap.
    defp generate_physical_name(alias) do
      ts = DateTime.to_unix(DateTime.utc_now(), :microsecond)
      "#{alias}-#{ts}"
    end

    # Creates a fresh versioned physical index and points the alias at it.
    defp create_index(cluster, alias, physical_mapping) do
      physical = generate_physical_name(alias)

      case Snap.Indexes.create(cluster, physical, physical_mapping) do
        {:ok, _} ->
          alias_index(cluster, physical, alias)

        {:error, %Snap.ResponseError{type: "resource_already_exists_exception"}} ->
          alias_index(cluster, physical, alias)

        {:error, reason} ->
          {:error, reason}
      end
    end

    defp alias_index(cluster, physical, alias) do
      case Snap.Indexes.alias(cluster, physical, alias) do
        :ok -> {:ok, :created}
        {:error, reason} -> {:error, reason}
      end
    end

    # `true` when the alias currently resolves to an index. A 404
    # (`index_not_found_exception`) means it does not exist yet.
    defp alias_exists?(cluster, alias) do
      case Snap.Indexes.get_mapping(cluster, alias) do
        {:ok, body} when is_map(body) ->
          {:ok, map_size(body) > 0}

        {:error, %Snap.ResponseError{status: 404}} ->
          {:ok, false}

        {:error, %Snap.ResponseError{type: "index_not_found_exception"}} ->
          {:ok, false}

        {:error, reason} ->
          {:error, reason}
      end
    end

    defp do_status(cluster, alias, schema_hash) do
      case Snap.Indexes.get_mapping(cluster, alias) do
        {:ok, body} when is_map(body) and map_size(body) > 0 ->
          {physical, mappings} = first_index_mapping(body)
          current_hash = get_in(mappings, ["_meta", @meta_key])

          {:ok,
           %{
             alias: alias,
             exists: true,
             physical_index: physical,
             current_hash: current_hash,
             schema_hash: schema_hash,
             drift?: current_hash != schema_hash
           }}

        {:ok, _empty} ->
          {:ok, not_exists(alias, schema_hash)}

        {:error, %Snap.ResponseError{status: 404}} ->
          {:ok, not_exists(alias, schema_hash)}

        {:error, %Snap.ResponseError{type: "index_not_found_exception"}} ->
          {:ok, not_exists(alias, schema_hash)}

        {:error, reason} ->
          {:error, reason}
      end
    end

    defp not_exists(alias, schema_hash) do
      %{
        alias: alias,
        exists: false,
        physical_index: nil,
        current_hash: nil,
        schema_hash: schema_hash,
        drift?: false
      }
    end

    # `GET /{alias}/_mapping` returns `%{physical_index => %{"mappings" => ...}}`.
    # An alias resolves to exactly one index in the Orkestra model; if several
    # are present we take the first deterministically.
    defp first_index_mapping(body) do
      {physical, inner} = body |> Enum.sort_by(fn {k, _v} -> k end) |> hd()
      {physical, Map.get(inner, "mappings", %{})}
    end

    # Streams every document behind the alias and hotswaps into a new index.
    defp do_reindex(cluster, alias, physical_mapping, opts) do
      batch_size = Keyword.get(opts, :batch_size, 500)
      query = %{"query" => %{"match_all" => %{}}, "size" => batch_size}

      stream =
        cluster
        |> Snap.Scroll.stream(alias, query, scroll_opts(opts))
        |> Stream.map(fn %Snap.Hit{id: id, source: source} ->
          %Snap.Bulk.Action.Index{id: id, doc: source}
        end)

      case Snap.Indexes.hotswap(stream, cluster, alias, physical_mapping, hotswap_opts(opts)) do
        :ok -> {:ok, :migrated}
        {:error, reason} -> {:error, reason}
      end
    end

    defp scroll_opts(opts), do: Keyword.take(opts, [:scroll, :params, :headers, :opts])

    defp hotswap_opts(opts),
      do: Keyword.take(opts, [:page_size, :page_wait, :max_errors, :request_opts])

    # Span event + structured log for a migrate outcome (never logs credentials).
    defp record_migrate_result(alias, culture, {:ok, outcome}) do
      Tracer.add_event("orkestra.es.migrate.result", %{
        "es.migrate.outcome" => Atom.to_string(outcome)
      })

      Logger.info("ES migrate #{outcome}", index: alias, culture: culture, orkestra: :es)
    end

    defp record_migrate_result(alias, culture, {:error, reason}) do
      Tracer.set_status(:error, inspect(reason))

      Logger.error("ES migrate failed",
        index: alias,
        culture: culture,
        reason: inspect(reason),
        orkestra: :es
      )
    end

    defp fail(op, alias, reason) do
      Tracer.set_status(:error, inspect(reason))

      Logger.warning("ES #{op} failed",
        index: alias,
        reason: inspect(reason),
        orkestra: :es
      )

      {:error, reason}
    end

    defp span_attrs(alias, nil), do: %{"es.index" => alias}

    defp span_attrs(alias, culture),
      do: %{"es.index" => alias, "es.culture" => to_string(culture)}
  end
end
