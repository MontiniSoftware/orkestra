if Code.ensure_loaded?(Snap.Cluster) do
  defmodule Orkestra.ES.Repository do
    @moduledoc """
    Generates a CRUD/read repository for an `Orkestra.ES.Schema`.

    A repository binds a schema to a `Snap.Cluster` and exposes an idiomatic,
    tuple-returning API over Elasticsearch/OpenSearch: single-document
    `get/2`, `save/2`, `delete/2`, bulk `save_all/2`, `count/2`, a lazy
    `stream/1`, `refresh/1`, and a raw `search/2` escape hatch. Every function
    accepts a trailing `opts :: keyword()` with an optional `:culture` for
    multi-culture schemas.

    ## Defining a repository

        defmodule MyApp.Search.Products do
          use Orkestra.ES.Repository,
            schema: MyApp.Search.Product,
            cluster: MyApp.ESCluster
        end

    Both `:schema` and `:cluster` are required; omitting either raises an
    `ArgumentError` at compile time.

    ## Generated API

      * `get(id, opts \\\\ [])` — `{:ok, struct}` | `{:error, :not_found}` | `{:error, term}`.
      * `save(struct, opts \\\\ [])` — upsert; `{:ok, struct}` | `{:error, term}`.
      * `save_all(structs, opts \\\\ [])` — bulk upsert; `:ok` | `{:error, %Snap.BulkError{}}` | `{:error, term}`.
      * `delete(id, opts \\\\ [])` — `:ok` | `{:error, :not_found}` | `{:error, term}`.
      * `count(opts \\\\ [])` — `{:ok, non_neg_integer}` | `{:error, term}`.
      * `stream(opts \\\\ [])` — a **lazy** `Enumerable` of schema structs.
      * `refresh(opts \\\\ [])` — `:ok` | `{:error, term}`.
      * `search(query, opts \\\\ [])` — `{:ok, %Snap.SearchResponse{}}` | `{:error, term}`.
      * `get_paged(opts \\\\ [])` — paginated/faceted query; `{:ok, %Orkestra.ES.Page{}}` | `{:error, term}`.
      * `__es_repository__(:schema | :cluster)` — introspection.

    All generated functions are `defoverridable`, so a repository may redefine
    any of them (e.g. to add caching) and delegate with `super/…`.

    ## Culture resolution

    The document `_id` comes from the schema's `primary_key` field. The target
    index alias is resolved from the schema and the optional `:culture` option:

      * no `:culture` — the schema default alias (multi-culture) or the single
        unsuffixed alias (mono-culture).
      * `:culture` on a multi-culture schema — the per-culture alias, or
        `{:error, {:unknown_culture, culture, valid_cultures}}` when the culture
        is not declared.
      * `:culture` on a mono-culture schema — always
        `{:error, {:unknown_culture, culture, []}}`, since mono-culture schemas
        accept no culture argument.

    Culture is validated **before** the schema's `alias_for/1` is called (that
    function raises), so the tuple-returning functions never raise on an unknown
    culture. `stream/1` is the sole exception: because it must return an
    `Enumerable` rather than a tuple, it raises `ArgumentError` on an unknown
    culture.

    ## `count/2`, `stream/1` and `search/2` queries

    `count/2` and `stream/1` accept an optional `:query` in opts:

      * omitted — matches all documents.
      * an `%Orkestra.ES.Query{}` — built via `Orkestra.ES.Query.build/1`; only
        its `"query"` clause is used.
      * a raw map — used as-is when it already carries a `"query"` key,
        otherwise wrapped as `%{"query" => map}`.

    `search/2` takes the query as its first argument: either an
    `%Orkestra.ES.Query{}` (built into a full request body) or a raw request
    map. Hits are **not** decoded — the caller inspects the
    `%Snap.SearchResponse{}` and may rebuild structs with the schema's
    `from_hit/1` on each `hit.source`.

    ## Observability

    Every public function opens an OpenTelemetry span
    (`orkestra.es.get`, `orkestra.es.save`, …) with `"es.index"`, `"es.culture"`
    and `"orkestra.es.schema"` attributes (plus `"es.doc_count"` for
    `save_all/2`) and emits a `[:orkestra, :es, :request]` `:telemetry` event
    with `%{duration_ms: …}` measurements and `%{op:, index:, culture:, schema:,
    result:}` metadata. `stream/1` spans only the opening of the stream — the
    actual scroll requests happen lazily as the consumer pulls elements. Cluster
    credentials and adapter options are never logged (convention T-08-02).
    """

    @doc false
    defmacro __using__(opts) do
      schema =
        Keyword.get(opts, :schema) ||
          raise ArgumentError,
                "use Orkestra.ES.Repository requires a :schema option " <>
                  "(the module that `use Orkestra.ES.Schema`)"

      cluster =
        Keyword.get(opts, :cluster) ||
          raise ArgumentError,
                "use Orkestra.ES.Repository requires a :cluster option " <>
                  "(a Snap.Cluster module)"

      quote do
        @orkestra_es_schema unquote(schema)
        @orkestra_es_cluster unquote(cluster)

        require OpenTelemetry.Tracer, as: Tracer

        alias Orkestra.ES.Query
        alias Orkestra.Telemetry

        @doc """
        Fetches a single document by `id`.

        Returns `{:ok, struct}` when found, `{:error, :not_found}` when the
        document does not exist, or `{:error, term}` on any other failure.
        """
        @spec get(term(), keyword()) :: {:ok, struct()} | {:error, :not_found} | {:error, term()}
        def get(id, opts \\ []) do
          __orkestra_es_with_culture__(opts, :get, %{}, fn index, _culture ->
            case Snap.Document.get(@orkestra_es_cluster, index, id) do
              {:ok, %{"found" => true, "_source" => source}} ->
                {:ok, @orkestra_es_schema.from_hit(source)}

              {:ok, %{"found" => false}} ->
                {:error, :not_found}

              {:error, %Snap.ResponseError{type: "document_not_found"}} ->
                {:error, :not_found}

              {:error, %Snap.ResponseError{status: 404}} ->
                {:error, :not_found}

              {:error, reason} ->
                {:error, reason}
            end
          end)
        end

        @doc """
        Upserts a single document.

        The `_id` is taken from the schema's primary-key field. When that field
        is `nil`, returns `{:error, {:missing_primary_key, field}}` without
        issuing any request.
        """
        @spec save(struct(), keyword()) :: {:ok, struct()} | {:error, term()}
        def save(struct, opts \\ []) do
          __orkestra_es_with_culture__(opts, :save, %{}, fn index, _culture ->
            pk_field = @orkestra_es_schema.__es_schema__(:primary_key)

            case Map.get(struct, pk_field) do
              nil ->
                {:error, {:missing_primary_key, pk_field}}

              id ->
                doc = @orkestra_es_schema.to_doc(struct)

                case Snap.Document.index(@orkestra_es_cluster, index, doc, id) do
                  {:ok, _} -> {:ok, struct}
                  {:error, reason} -> {:error, reason}
                end
            end
          end)
        end

        @doc """
        Bulk-upserts a collection of documents via the ES bulk API.

        Each document's `_id` comes from the schema's primary-key field. If any
        struct's primary key is `nil`, returns
        `{:error, {:missing_primary_key, field}}` **before** any HTTP request.
        The `:page_size` option is passed through to `Snap.Bulk.perform/4`.

        Returns `:ok`, `{:error, %Snap.BulkError{}}` when some items failed, or
        `{:error, term}` on transport failure.
        """
        @spec save_all(Enumerable.t(), keyword()) ::
                :ok | {:error, Snap.BulkError.t()} | {:error, term()}
        def save_all(structs, opts \\ []) do
          structs = Enum.to_list(structs)
          pk_field = @orkestra_es_schema.__es_schema__(:primary_key)
          extra = %{"es.doc_count" => length(structs)}

          __orkestra_es_with_culture__(opts, :save_all, extra, fn index, _culture ->
            case __orkestra_es_build_actions__(structs, pk_field) do
              {:error, _} = err ->
                err

              actions ->
                bulk_opts = Keyword.take(opts, [:page_size])

                case Snap.Bulk.perform(actions, @orkestra_es_cluster, index, bulk_opts) do
                  :ok -> :ok
                  {:error, reason} -> {:error, reason}
                end
            end
          end)
        end

        @doc """
        Deletes a single document by `id`.

        Returns `:ok` on deletion, `{:error, :not_found}` when the document did
        not exist, or `{:error, term}` on any other failure.
        """
        @spec delete(term(), keyword()) :: :ok | {:error, :not_found} | {:error, term()}
        def delete(id, opts \\ []) do
          __orkestra_es_with_culture__(opts, :delete, %{}, fn index, _culture ->
            case Snap.Document.delete(@orkestra_es_cluster, index, id) do
              {:ok, %{"result" => "not_found"}} ->
                {:error, :not_found}

              {:ok, _} ->
                :ok

              {:error, %Snap.ResponseError{type: "not_found"}} ->
                {:error, :not_found}

              {:error, %Snap.ResponseError{status: 404}} ->
                {:error, :not_found}

              {:error, reason} ->
                {:error, reason}
            end
          end)
        end

        @doc """
        Counts documents, optionally constrained by a `:query` in opts.

        Returns `{:ok, count}` or `{:error, term}`. See the module doc for how
        the `:query` option is interpreted.
        """
        @spec count(keyword()) :: {:ok, non_neg_integer()} | {:error, term()}
        def count(opts \\ []) do
          __orkestra_es_with_culture__(opts, :count, %{}, fn index, _culture ->
            body = __orkestra_es_count_query__(opts)

            case Snap.Search.count(@orkestra_es_cluster, index, body) do
              {:ok, count} -> {:ok, count}
              {:error, reason} -> {:error, reason}
            end
          end)
        end

        @doc """
        Returns a **lazy** stream of schema structs matching the optional
        `:query` in opts (via the ES scroll API).

        The stream is opened eagerly (that is where the span is recorded), but
        the underlying scroll requests happen lazily as the consumer pulls
        elements. Raises `ArgumentError` on an unknown culture, since the return
        value is an `Enumerable` rather than a result tuple.
        """
        @spec stream(keyword()) :: Enumerable.t()
        def stream(opts \\ []) do
          {culture, index} = __orkestra_es_resolve_culture_bang__(opts)
          body = __orkestra_es_count_query__(opts)
          attrs = Telemetry.es_repo_span_attrs(@orkestra_es_schema, index, culture)
          started_at = System.monotonic_time()

          raw =
            Telemetry.with_span("orkestra.es.stream", attrs, fn ->
              Snap.Scroll.stream(@orkestra_es_cluster, index, body)
            end)

          __orkestra_es_emit__(:stream, index, culture, started_at, :ok)

          Stream.map(raw, fn %Snap.Hit{source: source} ->
            @orkestra_es_schema.from_hit(source)
          end)
        end

        @doc """
        Refreshes the target index, making recent writes searchable.

        Returns `:ok` or `{:error, term}`.
        """
        @spec refresh(keyword()) :: :ok | {:error, term()}
        def refresh(opts \\ []) do
          __orkestra_es_with_culture__(opts, :refresh, %{}, fn index, _culture ->
            case Snap.Indexes.refresh(@orkestra_es_cluster, index) do
              :ok -> :ok
              {:error, reason} -> {:error, reason}
            end
          end)
        end

        @doc """
        Escape hatch: runs a raw search and returns the `%Snap.SearchResponse{}`.

        `query` is either an `%Orkestra.ES.Query{}` (built into a full request
        body) or a raw request map. Hits are not decoded — inspect the response
        and rebuild structs with the schema's `from_hit/1` if needed.
        """
        @spec search(Query.t() | map(), keyword()) ::
                {:ok, Snap.SearchResponse.t()} | {:error, term()}
        def search(query, opts \\ []) do
          __orkestra_es_with_culture__(opts, :search, %{}, fn index, _culture ->
            body = __orkestra_es_search_body__(query)

            case Snap.Search.search(@orkestra_es_cluster, index, body) do
              {:ok, response} -> {:ok, response}
              {:error, reason} -> {:error, reason}
            end
          end)
        end

        @doc """
        Runs a paginated, faceted query and returns an `Orkestra.ES.Page`.

        Options are compiled by `Orkestra.ES.PagedQuery.build/2` (full-text
        `:search`, typed `:filters`, `:facets`, `:sort`, and offset `:page` /
        `:page_size` **or** `:after` cursor pagination — see that module for the
        full contract) plus the usual `:culture`. The response is decoded into a
        `%Orkestra.ES.Page{}` whose `entries` are schema structs, `facets` are
        `Orkestra.ES.Facet.Attribute` structs with per-value counts, and
        `page_info` carries the pagination cursor.

        Returns `{:ok, %Orkestra.ES.Page{}}`, a `PagedQuery.build/2` error tuple
        (e.g. `{:error, :no_searchable_fields}`,
        `{:error, {:unknown_filter_field, field}}`,
        `{:error, :conflicting_pagination}`), an
        `{:error, {:unknown_culture, culture, valid}}`, or `{:error, term}` on a
        transport failure.
        """
        @spec get_paged(keyword()) :: {:ok, Orkestra.ES.Page.t()} | {:error, term()}
        def get_paged(opts \\ []) do
          __orkestra_es_with_culture__(opts, :get_paged, %{}, fn index, _culture ->
            case Orkestra.ES.PagedQuery.build(@orkestra_es_schema, opts) do
              {:error, _} = err ->
                err

              {:ok, body} ->
                case Snap.Search.search(@orkestra_es_cluster, index, body) do
                  {:ok, response} ->
                    page =
                      Orkestra.ES.PagedQuery.parse_response(@orkestra_es_schema, opts, response)

                    Tracer.set_attribute("es.hit_count", length(page.entries))
                    {:ok, page}

                  {:error, reason} ->
                    {:error, reason}
                end
            end
          end)
        end

        @doc "Introspects the repository. Accepts `:schema` and `:cluster`."
        @spec __es_repository__(:schema | :cluster) :: module()
        def __es_repository__(:schema), do: @orkestra_es_schema
        def __es_repository__(:cluster), do: @orkestra_es_cluster

        defoverridable get: 2,
                       save: 2,
                       save_all: 2,
                       delete: 2,
                       count: 1,
                       stream: 1,
                       refresh: 1,
                       search: 2,
                       get_paged: 1

        # -- private helpers ------------------------------------------------

        # Resolves the culture, instruments the operation, and runs `fun` with
        # the resolved `(index, culture)`. On an unknown culture the error tuple
        # is still instrumented (with the base index as a fallback) and returned
        # without raising.
        defp __orkestra_es_with_culture__(opts, op, extra_attrs, fun) do
          case __orkestra_es_resolve_culture__(opts) do
            {:ok, culture, index} ->
              __orkestra_es_instrument__(op, index, culture, extra_attrs, fn ->
                fun.(index, culture)
              end)

            {:error, _} = err ->
              base = @orkestra_es_schema.__es_schema__(:index)
              bad = Keyword.get(opts, :culture)

              __orkestra_es_instrument__(op, base, bad, extra_attrs, fn -> err end)
          end
        end

        # Wraps `fun` in an OTel span and emits the `[:orkestra, :es, :request]`
        # telemetry event, timing the call with a monotonic clock.
        defp __orkestra_es_instrument__(op, index, culture, extra_attrs, fun) do
          span_name = "orkestra.es." <> Atom.to_string(op)

          attrs =
            @orkestra_es_schema
            |> Telemetry.es_repo_span_attrs(index, culture)
            |> Map.merge(extra_attrs)

          started_at = System.monotonic_time()
          result = Telemetry.with_span(span_name, attrs, fun)
          __orkestra_es_emit__(op, index, culture, started_at, __orkestra_es_status__(result))
          result
        end

        defp __orkestra_es_emit__(op, index, culture, started_at, status) do
          duration_ms =
            System.convert_time_unit(
              System.monotonic_time() - started_at,
              :native,
              :millisecond
            )

          :telemetry.execute(
            [:orkestra, :es, :request],
            %{duration_ms: duration_ms},
            %{
              op: op,
              index: index,
              culture: culture,
              schema: @orkestra_es_schema,
              result: status
            }
          )
        end

        defp __orkestra_es_status__(:ok), do: :ok
        defp __orkestra_es_status__({:ok, _}), do: :ok
        defp __orkestra_es_status__(_), do: :error

        # Resolves `{:ok, culture, index}` from the `:culture` option, or an
        # `{:error, {:unknown_culture, culture, valid}}` tuple.
        defp __orkestra_es_resolve_culture__(opts) do
          cultures = @orkestra_es_schema.__es_schema__(:cultures)
          default = @orkestra_es_schema.__es_schema__(:default_culture)

          case Keyword.get(opts, :culture) do
            nil ->
              {:ok, default, @orkestra_es_schema.alias_for()}

            culture when cultures == [] ->
              {:error, {:unknown_culture, culture, []}}

            culture ->
              if culture in cultures do
                {:ok, culture, @orkestra_es_schema.alias_for(culture)}
              else
                {:error, {:unknown_culture, culture, cultures}}
              end
          end
        end

        # Like `__orkestra_es_resolve_culture__/1` but raises on an unknown
        # culture. Used by `stream/1`, whose return value cannot be a tuple.
        defp __orkestra_es_resolve_culture_bang__(opts) do
          case __orkestra_es_resolve_culture__(opts) do
            {:ok, culture, index} ->
              {culture, index}

            {:error, {:unknown_culture, culture, valid}} ->
              raise ArgumentError,
                    "#{inspect(__MODULE__)}: unknown culture #{inspect(culture)}, " <>
                      "valid cultures: #{inspect(valid)}"
          end
        end

        # Builds the list of bulk index actions, or an error tuple if any
        # struct is missing its primary key.
        defp __orkestra_es_build_actions__(structs, pk_field) do
          Enum.reduce_while(structs, [], fn struct, acc ->
            case Map.get(struct, pk_field) do
              nil ->
                {:halt, {:error, {:missing_primary_key, pk_field}}}

              id ->
                action = %Snap.Bulk.Action.Index{
                  id: id,
                  doc: @orkestra_es_schema.to_doc(struct)
                }

                {:cont, [action | acc]}
            end
          end)
          |> case do
            {:error, _} = err -> err
            actions -> Enum.reverse(actions)
          end
        end

        # Builds a `_count`/scroll request body from the optional `:query`.
        defp __orkestra_es_count_query__(opts) do
          case Keyword.get(opts, :query) do
            nil ->
              %{}

            %Query{} = q ->
              %{"query" => Map.get(Query.build(q), "query")}

            %{"query" => _} = body when is_map(body) ->
              body

            map when is_map(map) ->
              %{"query" => map}
          end
        end

        # Builds a full `_search` request body from an `%Orkestra.ES.Query{}`
        # or a raw map.
        defp __orkestra_es_search_body__(%Query{} = q), do: Query.build(q)
        defp __orkestra_es_search_body__(map) when is_map(map), do: map
      end
    end
  end
end
