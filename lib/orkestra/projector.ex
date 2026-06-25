defmodule Orkestra.Projector do
  @moduledoc """
  DSL macro for defining Orkestra projectors.

  A projector consumes domain events and maintains a queryable read model.
  Supports two backends: `:postgres` (default) and `:elasticsearch`.

  ## Postgres projector (default)

  A Postgres-backed projector uses an `Ecto.Repo` for both the read model
  and the projection checkpoint. Define event handlers with the `project/2`
  macro; the module generates the dispatch, config, and OTP child_spec
  boilerplate automatically.

      defmodule MyApp.OrderProjector do
        use Orkestra.Projector,
          repo: MyApp.OrderProjection.Repo,
          event_store: Orkestra.EventStore.InMemory

        project MyApp.Events.OrderPlaced, fn event, multi ->
          order = %{id: event.data.order_id, status: "placed"}
          Ecto.Multi.insert(multi, :read_model_insert, order)
        end

        project MyApp.Events.OrderCancelled, fn event, multi ->
          Ecto.Multi.update_all(multi, :read_model_update, ...)
        end
      end

  The `multi` parameter is a pre-built empty `Ecto.Multi.new()` that the
  handler chains operations onto. Step names **must** use the `:read_model_`
  prefix to avoid name collisions with the GenServer's reserved steps
  (`:checkpoint`, `:halted_checkpoint`, `:dead_letter`).

  ## Elasticsearch projector

  An Elasticsearch-backed projector writes documents to an ES/OpenSearch
  index. The checkpoint is still stored in Postgres (`:repo` is always
  required). Use `project_es/2` to declare event handlers; the handler must
  return `{:ok, doc, id}`, `:skip`, or `{:error, reason}`.

      defmodule MyApp.OrderESProjector do
        use Orkestra.Projector,
          backend: :elasticsearch,
          repo: MyApp.OrderProjection.Repo,
          cluster: MyApp.ESCluster,
          index: "orders",
          event_store: Orkestra.EventStore.InMemory

        @impl true
        def index_mapping do
          %{
            "mappings" => %{
              "properties" => %{
                "order_id" => %{"type" => "keyword"},
                "status"   => %{"type" => "keyword"}
              }
            }
          }
        end

        project_es MyApp.Events.OrderPlaced, fn event, _position ->
          {:ok, %{"order_id" => event.data.order_id, "status" => "placed"},
           event.data.order_id}
        end
      end

  The GenServer calls `Storage.Elasticsearch.init/1` at startup (via the
  `:init_adapter` message) to detect the engine and create the index before
  processing any events.

  ## Options for `use Orkestra.Projector`

  - `:repo` (required) — the `Ecto.Repo` module for the projection checkpoint.
    For ES projectors this is the checkpoint Postgres repo; it does not store
    the read-model data.
  - `:backend` (optional) — `:postgres` (default) or `:elasticsearch`.
  - `:cluster` (required for ES) — the `Snap.Cluster` module.
  - `:index` (required for ES) — the Elasticsearch index name string.
  - `:event_store` (optional) — event store module; defaults to
    `Orkestra.EventStore`.
  - `:name` (optional) — override the projector name string; defaults to
    `inspect(__MODULE__)`.
  - `:max_retries` (optional) — maximum retry attempts before halting;
    defaults to `5`.
  - `:backoff_base_ms` (optional) — base delay for exponential backoff in
    milliseconds; defaults to `500`.
  - `:backoff_cap_ms` (optional) — maximum backoff delay in milliseconds;
    defaults to `30_000`.

  ## The `project/2` macro (Postgres backend)

  Declares a handler for a specific event type:

      project EventModule, fn event, multi -> multi end

  The handler receives the event struct and an empty `Ecto.Multi.new()`.
  It must return an `Ecto.Multi.t()` — the multi is then wrapped in
  `{:ok, multi}` by the generated `__handle__/3` bridge function.

  ## The `project_es/2` macro (Elasticsearch backend)

  Declares a handler for a specific event type in an ES projector:

      project_es EventModule, fn event, position ->
        {:ok, %{"field" => value}, document_id}
      end

  The handler receives `(event, position)` and must return one of:
  - `{:ok, doc, id}` — index the document with deterministic `_id`
  - `:skip` — skip this event (no ES write)
  - `{:error, reason}` — signal failure

  ## Generated functions

  **Postgres backend:**

  - `__dispatch__/3` — routes by event type string; returns
    `{:ok, Ecto.Multi.t()}` for registered events or `:skip` for unknown ones.
  - `__handle__/3` — adapter-facing bridge: calls `__dispatch__/3` and
    translates `:skip` into `{:ok, Ecto.Multi.new()}`.

  **Elasticsearch backend:**

  - `__dispatch_es__/3` — routes by event type string; returns
    `{:ok, doc, id}` for registered events or `:skip` for unknown ones.
  - `__handle_es__/3` — adapter-facing bridge: calls `__dispatch_es__/3`
    and passes through `{:ok, doc, id}`, `:skip`, or `{:error, reason}`.

  **Both backends:**

  - `__projection_config__/0` — returns a map with `:repo`, `:projector_name`,
    `:migrations_path`, and `:migration_source`; used by mix tasks for discovery.
  - `child_spec/1` — returns a supervisor child spec targeting
    `Orkestra.Projector.GenServer`. For ES projectors the spec injects
    `Storage.Elasticsearch` and the necessary `adapter_opts`.

  ## child_spec/1 and runtime overrides

  `child_spec/1` accepts a keyword list of overrides for runtime config:

      # In your supervision tree
      children = [
        {Orkestra.Projection.Supervisor, projectors: [
          MyApp.OrderProjector,
          {MyApp.CustomerProjector, repo: MyApp.CustomerProjection.TestRepo}
        ]}
      ]

  ## __projection_config__/0 return shape

  Used by mix tasks (e.g. `mix projector.migrate`, `mix orkestra.projection.es.rebuild`)
  to discover per-projection repos, migration paths, and backend-specific configuration:

      %{
        repo: MyApp.OrderProjection.Repo,
        projector_name: "MyApp.OrderProjector",
        migrations_path: "priv/projections/myapp_order_projector/migrations",
        migration_source: "projection_myapp_order_projector_schema_migrations",
        backend: :postgres,
        cluster: nil,
        index: nil,
        projector_module: MyApp.OrderProjector
      }

  For Elasticsearch projectors the map additionally contains:

      %{
        ...
        backend: :elasticsearch,
        cluster: MyApp.ESCluster,
        index: "orders",
        projector_module: MyApp.OrderESProjector
      }

  ## Per-Projection Repo Configuration

  Each projector uses its own isolated `Ecto.Repo`. This keeps migrations,
  tables, and migration history fully independent across projections.

  ### Example `config.exs`

      config :my_app, MyApp.OrderProjection.Repo,
        database: "my_app_dev",
        hostname: "localhost",
        migration_source: "projection_myapp_order_projector_schema_migrations",
        priv: "priv/projections/myapp_order_projector"

  The `:migration_source` key sets the migrations tracking table name so
  each projection's migration history is isolated from the app's main
  `schema_migrations` table. The `:priv` key points Mix to the correct
  migrations directory.

  ### Defining the Repo

      defmodule MyApp.OrderProjection.Repo do
        use Ecto.Repo,
          otp_app: :my_app,
          adapter: Ecto.Adapters.Postgres
      end

  Add the Repo to your supervision tree:

      children = [
        MyApp.OrderProjection.Repo,
        {Orkestra.Projection.Supervisor, projectors: [MyApp.OrderProjector]}
      ]
  """

  @doc """
  Declares a handler for a specific event type.

  The `handler_fn` receives `(event, multi)` where `multi` is a fresh
  `Ecto.Multi.new()`. It should return an `Ecto.Multi.t()` with all read-model
  operations chained using `:read_model_`-prefixed step names.
  """
  defmacro project(event_module, handler_fn) do
    # Store the handler as a quoted AST (not evaluated) so __before_compile__
    # can inject it back into the generated __dispatch__ function body.
    escaped = Macro.escape(handler_fn)

    quote do
      @projection_handlers {unquote(event_module), unquote(escaped)}
    end
  end

  @doc """
  Declares a handler for a specific event type in an Elasticsearch-backed projector.

  The `handler_fn` receives `(event, position)` and must return one of:
  - `{:ok, doc, id}` — index the document with deterministic `_id`
  - `:skip` — skip this event (no ES write)
  - `{:error, reason}` — signal failure
  """
  defmacro project_es(event_module, handler_fn) do
    # Same Macro.escape/1 pattern as project/2 — prevents AST injection (T-08-01)
    escaped = Macro.escape(handler_fn)

    quote do
      @es_projection_handlers {unquote(event_module), unquote(escaped)}
    end
  end

  defmacro __using__(opts) do
    repo = Keyword.fetch!(opts, :repo)
    event_store = Keyword.get(opts, :event_store, Orkestra.EventStore.InMemory)
    name_override = Keyword.get(opts, :name, nil)
    max_retries = Keyword.get(opts, :max_retries, 5)
    backoff_base_ms = Keyword.get(opts, :backoff_base_ms, 500)
    backoff_cap_ms = Keyword.get(opts, :backoff_cap_ms, 30_000)

    # ES-specific options — use get (not fetch!) so Postgres projectors are unaffected
    backend = Keyword.get(opts, :backend, :postgres)
    es_cluster = Keyword.get(opts, :cluster, nil)
    es_index = Keyword.get(opts, :index, nil)

    lifecycle_cfg = %{
      max_retries: max_retries,
      backoff_base_ms: backoff_base_ms,
      backoff_cap_ms: backoff_cap_ms
    }

    quote do
      Module.register_attribute(__MODULE__, :projection_handlers, accumulate: true)
      Module.register_attribute(__MODULE__, :es_projection_handlers, accumulate: true)
      Module.put_attribute(__MODULE__, :_projector_repo, unquote(repo))
      Module.put_attribute(__MODULE__, :_projector_event_store, unquote(event_store))
      Module.put_attribute(__MODULE__, :_projector_name_override, unquote(name_override))
      Module.put_attribute(__MODULE__, :_projector_backend, unquote(backend))
      Module.put_attribute(__MODULE__, :_projector_es_cluster, unquote(es_cluster))
      Module.put_attribute(__MODULE__, :_projector_es_index, unquote(es_index))

      Module.put_attribute(
        __MODULE__,
        :_projector_lifecycle,
        unquote(Macro.escape(lifecycle_cfg))
      )

      import Orkestra.Projector, only: [project: 2, project_es: 2]

      @before_compile Orkestra.Projector
    end
  end

  defmacro __before_compile__(env) do
    handlers = Module.get_attribute(env.module, :projection_handlers) |> Enum.reverse()
    es_handlers = Module.get_attribute(env.module, :es_projection_handlers) |> Enum.reverse()
    repo = Module.get_attribute(env.module, :_projector_repo)
    event_store = Module.get_attribute(env.module, :_projector_event_store)
    name_override = Module.get_attribute(env.module, :_projector_name_override)
    lifecycle = Module.get_attribute(env.module, :_projector_lifecycle)
    backend = Module.get_attribute(env.module, :_projector_backend) || :postgres
    es_cluster = Module.get_attribute(env.module, :_projector_es_cluster)
    es_index = Module.get_attribute(env.module, :_projector_es_index)

    # Compile-time validation (T-08-05)
    if backend == :elasticsearch and (is_nil(es_cluster) or is_nil(es_index)) do
      raise CompileError,
        file: env.file,
        line: env.line,
        description:
          "use Orkestra.Projector with backend: :elasticsearch requires both :cluster and :index options"
    end

    if length(handlers) > 0 and length(es_handlers) > 0 do
      raise CompileError,
        file: env.file,
        line: env.line,
        description:
          "A projector module cannot mix project/2 (Postgres) and project_es/2 (Elasticsearch) handlers. " <>
            "Use a single backend per projector module."
    end

    # Derive projector_name: use override if provided, else inspect(__MODULE__)
    projector_name =
      if name_override do
        name_override
      else
        inspect(env.module)
      end

    # Derive filesystem slug: "MyApp.OrderProjector" -> "my_app_order_projector"
    # Uses Macro.underscore per-segment to match MCP generator convention
    slug =
      projector_name
      |> String.split(".")
      |> Enum.map(&Macro.underscore/1)
      |> Enum.join("_")

    migrations_path = Path.join(["priv", "projections", slug, "migrations"])
    migration_source = "projection_#{slug}_schema_migrations"

    # Build Postgres dispatch clauses — one per registered event type
    dispatch_clauses =
      Enum.map(handlers, fn {event_module, handler_fn} ->
        type_string = inspect(event_module)

        quote do
          def __dispatch__(unquote(type_string), event, _position) do
            {:ok, unquote(handler_fn).(event, Ecto.Multi.new())}
          end
        end
      end)

    # Catch-all dispatch clause for unregistered types (Postgres)
    dispatch_fallback =
      quote do
        def __dispatch__(_type, _event, _position), do: :skip
      end

    # Build ES dispatch clauses — one per registered ES event type
    es_dispatch_clauses =
      Enum.map(es_handlers, fn {event_module, handler_fn} ->
        type_string = inspect(event_module)

        quote do
          def __dispatch_es__(unquote(type_string), event, position) do
            unquote(handler_fn).(event, position)
          end
        end
      end)

    # Catch-all ES dispatch clause for unregistered types
    es_dispatch_fallback =
      quote do
        def __dispatch_es__(_type, _event, _position), do: :skip
      end

    # Elixir 1.18+ type checker emits dead-code warnings when a case clause
    # can never be reached (e.g. when all __dispatch__ clauses return :skip
    # because no handlers are registered for that backend). To avoid these
    # warnings, generate lean bridge functions that match only what
    # __dispatch__ actually returns for the given backend.

    # __handle__/3 (Postgres path):
    # - ES backend with no Postgres handlers → always :skip → return {:ok, Multi.new()} directly
    # - Postgres backend → may return {:ok, multi} | :skip → delegate to __dispatch__/3
    #   Note: {:error, reason} clause is kept for forward-compatibility even though
    #   the type checker considers it unreachable given current handler signatures.
    postgres_handle_fn =
      if backend == :elasticsearch do
        quote do
          @doc false
          @spec __handle__(String.t(), map(), non_neg_integer()) ::
                  {:ok, Ecto.Multi.t()} | {:error, term()}
          def __handle__(_projector_name, _event, _position) do
            {:ok, Ecto.Multi.new()}
          end
        end
      else
        quote do
          @doc false
          @spec __handle__(String.t(), map(), non_neg_integer()) ::
                  {:ok, Ecto.Multi.t()} | {:error, term()}
          def __handle__(projector_name, event, position) do
            case __dispatch__(event.type, event, position) do
              {:ok, multi} -> {:ok, multi}
              :skip -> {:ok, Ecto.Multi.new()}
            end
          end
        end
      end

    # __handle_es__/3 (ES path):
    # - Postgres backend with no ES handlers → always :skip → return :skip directly
    # - ES backend → may return {:ok, doc, id} | :skip | {:error, reason}
    es_handle_fn =
      if backend == :elasticsearch do
        quote do
          @doc false
          @spec __handle_es__(String.t(), map(), non_neg_integer()) ::
                  {:ok, map(), String.t()} | :skip | {:error, term()}
          def __handle_es__(projector_name, event, position) do
            case __dispatch_es__(event.type, event, position) do
              {:ok, doc, id} -> {:ok, doc, id}
              :skip -> :skip
              {:error, reason} -> {:error, reason}
            end
          end
        end
      else
        quote do
          @doc false
          @spec __handle_es__(String.t(), map(), non_neg_integer()) ::
                  {:ok, map(), String.t()} | :skip | {:error, term()}
          def __handle_es__(_projector_name, _event, _position) do
            :skip
          end
        end
      end

    quote do
      # Postgres dispatch clauses — generated for each registered event type
      unquote_splicing(dispatch_clauses)
      unquote(dispatch_fallback)

      unquote(postgres_handle_fn)

      # ES dispatch clauses — generated for each registered ES event type
      unquote_splicing(es_dispatch_clauses)
      unquote(es_dispatch_fallback)

      unquote(es_handle_fn)

      @doc """
      Returns the compile-time projection configuration map.

      Used by mix tasks to discover per-projection repos, migrations paths,
      migration source table names, and backend-specific configuration
      (`:backend`, `:cluster`, `:index`, `:projector_module`) for the
      `mix orkestra.projection.es.rebuild` task (RBLD-02).

      Postgres projectors return `backend: :postgres`, `cluster: nil`, `index: nil`.
      Elasticsearch projectors return `backend: :elasticsearch`, `cluster: MyCluster`,
      `index: "my_index"`.
      """
      @spec __projection_config__() :: %{
              repo: module(),
              projector_name: String.t(),
              migrations_path: String.t(),
              migration_source: String.t(),
              backend: :postgres | :elasticsearch,
              cluster: module() | nil,
              index: String.t() | nil,
              projector_module: module()
            }
      def __projection_config__ do
        %{
          repo: unquote(repo),
          projector_name: unquote(projector_name),
          migrations_path: unquote(migrations_path),
          migration_source: unquote(migration_source),
          backend: unquote(backend),
          cluster: unquote(es_cluster),
          index: unquote(es_index),
          projector_module: __MODULE__
        }
      end

      @doc """
      Returns an OTP child spec for starting this projector under a supervisor.

      The optional `opts` keyword list allows runtime overrides of the
      compile-time defaults (e.g., `repo:` for test isolation).

      For Elasticsearch projectors (`backend: :elasticsearch`), the spec
      automatically injects `storage_adapter: Storage.Elasticsearch` and
      the required `adapter_opts` (`:cluster`, `:index`, `:handler`,
      `:projector_module`).
      """
      @spec child_spec(keyword()) :: Supervisor.child_spec()
      def child_spec(opts \\ []) do
        config =
          if unquote(backend) == :elasticsearch do
            %{
              repo: unquote(repo),
              projector_name: unquote(projector_name),
              storage_adapter: Orkestra.Projection.Storage.Elasticsearch,
              event_store: unquote(event_store),
              lifecycle_config: unquote(Macro.escape(lifecycle)),
              adapter_opts: [
                cluster: unquote(es_cluster),
                index: unquote(es_index),
                handler: &__MODULE__.__handle_es__/3,
                projector_module: __MODULE__
              ]
            }
          else
            %{
              repo: unquote(repo),
              projector_name: unquote(projector_name),
              storage_adapter: Orkestra.Projection.Storage.Postgres,
              event_store: unquote(event_store),
              lifecycle_config: unquote(Macro.escape(lifecycle)),
              adapter_opts: [handler: &__MODULE__.__handle__/3]
            }
          end

        # Register the GenServer under the module name so GenServer.whereis/1 works
        # (needed by mix orkestra.projection.es.rebuild for pause/resume)
        config = Map.put_new(config, :name, __MODULE__)

        # Merge runtime overrides from opts (allows test Repo injection etc.)
        config = Map.merge(config, Map.new(opts))

        %{
          id: __MODULE__,
          start: {Orkestra.Projector.GenServer, :start_link, [config]}
        }
      end
    end
  end
end
