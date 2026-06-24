defmodule Orkestra.Projector do
  @moduledoc """
  DSL macro for defining Orkestra projectors.

  A projector consumes domain events and maintains a queryable read model,
  backed by a per-projection Ecto.Repo. Define event handlers with the
  `project/2` macro; the module generates the dispatch, config, and OTP
  child_spec boilerplate automatically.

  ## Defining a projector

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

  ## Options for `use Orkestra.Projector`

  - `:repo` (required) — the `Ecto.Repo` module for this projection.
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

  ## The `project/2` macro

  Declares a handler for a specific event type:

      project EventModule, fn event, multi -> multi end

  The handler receives the event struct and an empty `Ecto.Multi.new()`.
  It must return an `Ecto.Multi.t()` — the multi is then wrapped in
  `{:ok, multi}` by the generated `__handle__/3` bridge function.

  ## Generated functions

  - `__dispatch__/3` — routes by event type string; returns
    `{:ok, Ecto.Multi.t()}` for registered events or `:skip` for unknown ones.
  - `__handle__/3` — adapter-facing bridge: calls `__dispatch__/3` and
    translates `:skip` into `{:ok, Ecto.Multi.new()}`.
  - `__projection_config__/0` — returns a map with `:repo`, `:projector_name`,
    `:migrations_path`, and `:migration_source`; used by mix tasks for discovery.
  - `child_spec/1` — returns a supervisor child spec targeting
    `Orkestra.Projector.GenServer`.

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

  Used by mix tasks (e.g. `mix projector.migrate`) to discover per-projection
  repos and migration paths:

      %{
        repo: MyApp.OrderProjection.Repo,
        projector_name: "MyApp.OrderProjector",
        migrations_path: "priv/projections/myapp_order_projector/migrations",
        migration_source: "projection_myapp_order_projector_schema_migrations"
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

  defmacro __using__(opts) do
    repo = Keyword.fetch!(opts, :repo)
    event_store = Keyword.get(opts, :event_store, Orkestra.EventStore)
    name_override = Keyword.get(opts, :name, nil)
    max_retries = Keyword.get(opts, :max_retries, 5)
    backoff_base_ms = Keyword.get(opts, :backoff_base_ms, 500)
    backoff_cap_ms = Keyword.get(opts, :backoff_cap_ms, 30_000)

    lifecycle_cfg = %{
      max_retries: max_retries,
      backoff_base_ms: backoff_base_ms,
      backoff_cap_ms: backoff_cap_ms
    }

    quote do
      Module.register_attribute(__MODULE__, :projection_handlers, accumulate: true)
      Module.put_attribute(__MODULE__, :_projector_repo, unquote(repo))
      Module.put_attribute(__MODULE__, :_projector_event_store, unquote(event_store))
      Module.put_attribute(__MODULE__, :_projector_name_override, unquote(name_override))

      Module.put_attribute(
        __MODULE__,
        :_projector_lifecycle,
        unquote(Macro.escape(lifecycle_cfg))
      )

      import Orkestra.Projector, only: [project: 2]

      @before_compile Orkestra.Projector
    end
  end

  defmacro __before_compile__(env) do
    handlers = Module.get_attribute(env.module, :projection_handlers) |> Enum.reverse()
    repo = Module.get_attribute(env.module, :_projector_repo)
    event_store = Module.get_attribute(env.module, :_projector_event_store)
    name_override = Module.get_attribute(env.module, :_projector_name_override)
    lifecycle = Module.get_attribute(env.module, :_projector_lifecycle)

    # Derive projector_name: use override if provided, else inspect(__MODULE__)
    projector_name =
      if name_override do
        name_override
      else
        inspect(env.module)
      end

    # Derive filesystem slug: "MyApp.OrderProjector" -> "myapp_order_projector"
    slug =
      projector_name
      |> String.downcase()
      |> String.replace(".", "_")

    migrations_path = Path.join(["priv", "projections", slug, "migrations"])
    migration_source = "projection_#{slug}_schema_migrations"

    # Build dispatch clauses — one per registered event type
    dispatch_clauses =
      Enum.map(handlers, fn {event_module, handler_fn} ->
        type_string = inspect(event_module)

        quote do
          def __dispatch__(unquote(type_string), event, _position) do
            {:ok, unquote(handler_fn).(event, Ecto.Multi.new())}
          end
        end
      end)

    # Catch-all dispatch clause for unregistered types
    dispatch_fallback =
      quote do
        def __dispatch__(_type, _event, _position), do: :skip
      end

    quote do
      # Dispatch clauses — generated for each registered event type
      unquote_splicing(dispatch_clauses)
      unquote(dispatch_fallback)

      @doc false
      @spec __handle__(String.t(), map(), non_neg_integer()) ::
              {:ok, Ecto.Multi.t()} | {:error, term()}
      def __handle__(projector_name, event, position) do
        case __dispatch__(event.type, event, position) do
          {:ok, multi} -> {:ok, multi}
          {:error, reason} -> {:error, reason}
          :skip -> {:ok, Ecto.Multi.new()}
        end
      end

      @doc """
      Returns the compile-time projection configuration map.

      Used by mix tasks to discover per-projection repos, migrations paths,
      and migration source table names.
      """
      @spec __projection_config__() :: %{
              repo: module(),
              projector_name: String.t(),
              migrations_path: String.t(),
              migration_source: String.t()
            }
      def __projection_config__ do
        %{
          repo: unquote(repo),
          projector_name: unquote(projector_name),
          migrations_path: unquote(migrations_path),
          migration_source: unquote(migration_source)
        }
      end

      @doc """
      Returns an OTP child spec for starting this projector under a supervisor.

      The optional `opts` keyword list allows runtime overrides of the
      compile-time defaults (e.g., `repo:` for test isolation).
      """
      @spec child_spec(keyword()) :: Supervisor.child_spec()
      def child_spec(opts \\ []) do
        config = %{
          repo: unquote(repo),
          projector_name: unquote(projector_name),
          storage_adapter: Orkestra.Projection.Storage.Postgres,
          event_store: unquote(event_store),
          lifecycle_config: unquote(Macro.escape(lifecycle)),
          adapter_opts: [handler: &__MODULE__.__handle__/3]
        }

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
