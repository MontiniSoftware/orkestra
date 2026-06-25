defmodule OrkestraMcp.Generator do
  @moduledoc false

  alias OrkestraMcp.Naming

  @doc """
  Generates a Command module. Returns `{source_code, file_path}`.

  `params` is a list of maps with keys: `"name"`, `"type"`, and optionally
  `"required"` (boolean), `"default"`.
  """
  def gen_command(module_name, params) do
    params_code =
      params
      |> Enum.map_join("\n", &format_param/1)

    source = """
    defmodule #{module_name} do
      use Orkestra.Command

    #{params_code}
    end
    """

    {String.trim(source), Naming.module_to_file_path(module_name)}
  end

  @doc """
  Generates an Event module. Returns `{source_code, file_path}`.

  `fields` is a list of maps with keys: `"name"`, `"type"`, and optionally
  `"required"` (boolean), `"default"`.
  """
  def gen_event(module_name, fields) do
    fields_code =
      fields
      |> Enum.map_join("\n", &format_field/1)

    source = """
    defmodule #{module_name} do
      use Orkestra.Event

    #{fields_code}
    end
    """

    {String.trim(source), Naming.module_to_file_path(module_name)}
  end

  @doc """
  Generates a CommandHandler module. Returns `{source_code, file_path}`.
  """
  def gen_command_handler(module_name, command_module) do
    source = """
    defmodule #{module_name} do
      use Orkestra.CommandHandler, command: #{command_module}

      @impl true
      def execute(command, _metadata) do
        # TODO: implement command handling logic
        :ok
      end
    end
    """

    {String.trim(source), Naming.module_to_file_path(module_name)}
  end

  @doc """
  Generates an EventHandler module. Returns `{source_code, file_path}`.

  `opts` is a map with `"mode"` (`"single"`, `"multi"`, or `"topic"`) and
  the corresponding detail key (`"event"`, `"events"`, or `"topic"`).
  """
  def gen_event_handler(module_name, opts) do
    use_line = build_event_handler_use(opts)

    source = """
    defmodule #{module_name} do
      #{use_line}

      @impl true
      def handle_event(event, _metadata) do
        # TODO: implement event handling logic
        :ok
      end
    end
    """

    {String.trim(source), Naming.module_to_file_path(module_name)}
  end

  @doc """
  Generates an Aggregate module. Returns `{source_code, file_path}`.

  `commands` and `events` are lists of module name strings used to generate
  pattern-match clauses.
  """
  def gen_aggregate(module_name, stream_id_field, commands, events) do
    decide_clauses =
      if commands == [] do
        """
            def decide(_state, command) do
              # TODO: implement decision logic
              {:ok, []}
            end
        """
      else
        commands
        |> Enum.map_join("\n\n", fn cmd ->
          """
              def decide(state, %#{cmd}{} = command) do
                # TODO: implement decision logic for #{cmd}
                {:ok, []}
              end
          """
        end)
      end

    evolve_clauses =
      if events == [] do
        """
            def evolve(state, event) do
              # TODO: implement state evolution
              state
            end
        """
      else
        events
        |> Enum.map_join("\n\n", fn evt ->
          """
              def evolve(state, %#{evt}{} = event) do
                # TODO: implement state evolution for #{evt}
                state
              end
          """
        end)
      end

    source = """
    defmodule #{module_name} do
      @behaviour Orkestra.Aggregate

      defstruct []

      @impl true
      def init_state, do: %__MODULE__{}

      @impl true
      def stream_id(command) do
        command.params.#{stream_id_field}
      end

      @impl true
    #{String.trim(decide_clauses)}

      @impl true
    #{String.trim(evolve_clauses)}
    end
    """

    {String.trim(source), Naming.module_to_file_path(module_name)}
  end

  @doc """
  Writes source code to `project_dir/file_path`, creating directories as needed.
  """
  def write!(source_code, project_dir, file_path) do
    full_path = Path.join(project_dir, file_path)
    full_path |> Path.dirname() |> File.mkdir_p!()
    File.write!(full_path, source_code <> "\n")
    full_path
  end

  @doc """
  Generates a Projector module. Returns `{source_code, file_path}`.

  `events` is a list of event module name strings. If empty, generates a
  placeholder `project` clause with a TODO comment.
  """
  def gen_projection(module_name, repo_module, events) do
    project_clauses =
      if events == [] do
        """
          project EventModule, fn _event, multi ->
            # TODO: implement projection logic
            multi
          end
        """
        |> String.trim_trailing()
      else
        events
        |> Enum.map_join("\n\n", fn event ->
          """
            project #{event}, fn _event, multi ->
              # TODO: implement projection logic for #{event}
              multi
            end
          """
          |> String.trim_trailing()
        end)
      end

    source = """
    defmodule #{module_name} do
      use Orkestra.Projector,
        repo: #{repo_module},
        event_store: Orkestra.EventStore.InMemory

    #{project_clauses}
    end
    """

    {String.trim(source), Naming.module_to_file_path(module_name)}
  end

  @doc """
  Generates a projection migration file. Returns `{source_code, file_path}`.

  The file path uses `priv/projections/<slug>/migrations/` so it stays isolated
  from the host application's own Ecto migrations.

  `timestamp` defaults to the current UTC datetime in `YYYYMMDDHHmmss` format when
  not supplied (useful for deterministic tests).
  """
  def gen_projection_migration(projector_module_name, timestamp \\ nil) do
    ts = timestamp || Calendar.strftime(DateTime.utc_now(), "%Y%m%d%H%M%S")

    slug =
      projector_module_name
      |> String.split(".")
      |> Enum.map(&Macro.underscore/1)
      |> Enum.join("_")

    migration_module = "Orkestra.Projection.Migrations.Create#{Macro.camelize(slug)}ReadModel"

    file_path =
      Path.join([
        "priv",
        "projections",
        slug,
        "migrations",
        "#{ts}_create_#{slug}_read_model.exs"
      ])

    source = """
    defmodule #{migration_module} do
      use Ecto.Migration

      def up do
        # TODO: create the read model table, e.g.:
        # create table(:#{slug}_read_model, primary_key: false) do
        #   add :id, :binary_id, primary_key: true
        #   timestamps(type: :utc_datetime_usec)
        # end
      end

      def down do
        # TODO: drop the read model table, e.g.:
        # drop table(:#{slug}_read_model)
      end
    end
    """

    {String.trim(source), file_path}
  end

  @doc """
  Generates an Ecto schema module for a read model. Returns `{source_code, file_path}`.

  `fields` is a list of maps with keys `"name"` and `"type"`.
  """
  def gen_read_model(module_name, fields) do
    fields_code =
      fields
      |> Enum.map_join("\n", &format_schema_field/1)

    table_name = Naming.module_to_table_name(module_name)

    source = """
    defmodule #{module_name} do
      use Ecto.Schema

      @primary_key {:id, :binary_id, autogenerate: true}
      @timestamps_opts [type: :utc_datetime_usec]

      schema "#{table_name}" do
    #{fields_code}

        timestamps()
      end
    end
    """

    {String.trim(source), Naming.module_to_file_path(module_name)}
  end

  @doc """
  Generates a migration for a read model schema. Returns `{source_code, file_path}`.

  `timestamp` defaults to the current UTC datetime in `YYYYMMDDHHmmss` format when
  not supplied (useful for deterministic tests).
  """
  def gen_read_model_migration(schema_module_name, timestamp \\ nil) do
    ts = timestamp || Calendar.strftime(DateTime.utc_now(), "%Y%m%d%H%M%S")
    table_name = Naming.module_to_table_name(schema_module_name)

    slug =
      schema_module_name
      |> String.split(".")
      |> Enum.map(&Macro.underscore/1)
      |> Enum.join("_")

    file_path =
      Path.join(["priv", "projections", slug, "migrations", "#{ts}_create_#{table_name}.exs"])

    source = """
    defmodule Orkestra.Projection.Migrations.Create#{Macro.camelize(table_name)} do
      use Ecto.Migration

      def change do
        create table(:#{table_name}, primary_key: false) do
          add :id, :binary_id, primary_key: true
          # TODO: add your read model fields here, e.g.:
          # add :name, :string, null: false
          timestamps(type: :utc_datetime_usec)
        end
      end
    end
    """

    {String.trim(source), file_path}
  end

  @doc """
  Generates a Queries module with paged `list/2` and `get_by/2` helpers.
  Returns `{source_code, file_path}`.

  `schema_module` is the fully-qualified schema module name string, e.g.
  `"MyApp.Orders.OrderReadModel"`.
  """
  def gen_queries(module_name, schema_module) do
    schema_alias = schema_module |> String.split(".") |> List.last()

    source = """
    defmodule #{module_name} do
      @moduledoc \"\"\"
      Query helpers for `#{schema_module}`.

      Provides paged `list/2` and filter-based `get_by/2` functions built on top
      of Ecto.Query so callers do not need to write boilerplate query code.
      \"\"\"

      import Ecto.Query

      alias #{schema_module}

      @doc \"\"\"
      Returns a paginated list of `#{schema_alias}` records.

      Options:
        * `:page` - 1-based page number (default: 1)
        * `:page_size` - number of records per page (default: 20)
      \"\"\"
      def list(repo, opts \\\\ []) do
        page = Keyword.get(opts, :page, 1)
        page_size = Keyword.get(opts, :page_size, 20)
        offset = (page - 1) * page_size

        repo.all(from(q in #{schema_alias}, limit: ^page_size, offset: ^offset))
      end

      @doc \"\"\"
      Returns all `#{schema_alias}` records matching the given `filters`.

      `filters` is a keyword list of field-value pairs passed directly to Ecto's
      `where` clause.
      \"\"\"
      def get_by(repo, filters) do
        repo.all(from(q in #{schema_alias}, where: ^filters))
      end
    end
    """

    {String.trim(source), Naming.module_to_file_path(module_name)}
  end

  @doc """
  Generates an ES Projector module. Returns `{source_code, file_path}`.

  `events` is a list of event module name strings. If empty, generates a
  placeholder `project_es` clause with a TODO comment.

  The generated module uses `use Orkestra.Projector, backend: :elasticsearch`
  with `project_es/2` handler clauses and an `index_mapping/0` scaffold.
  """
  def gen_es_projection(module_name, repo_module, cluster_module, index, events) do
    project_es_clauses =
      if events == [] do
        """
          project_es EventModule, fn _event, _position ->
            # TODO: return {:ok, doc_map, document_id}, :skip, or {:error, reason}
            {:ok, %{}, nil}
          end
        """
        |> String.trim_trailing()
      else
        events
        |> Enum.map_join("\n\n", fn event ->
          """
            project_es #{event}, fn _event, _position ->
              # TODO: implement projection logic for #{event}
              {:ok, %{}, nil}
            end
          """
          |> String.trim_trailing()
        end)
      end

    source = """
    defmodule #{module_name} do
      use Orkestra.Projector,
        backend: :elasticsearch,
        repo: #{repo_module},
        cluster: #{cluster_module},
        index: "#{index}",
        event_store: Orkestra.EventStore.InMemory

      @impl true
      def index_mapping do
        %{
          "mappings" => %{
            "properties" => %{
              # TODO: define your index field mappings here, e.g.:
              # "field_name" => %{"type" => "keyword"}
            }
          }
        }
      end

      @doc "Derives a deterministic document ID from the event for idempotent writes."
      def document_id(event) do
        # TODO: return a deterministic string ID for the ES document, e.g.:
        # event.data["order_id"] or "\#{event.type}-\#{event.data["id"]}"
        "\#{event.type}-\#{event.id}"
      end

    #{project_es_clauses}
    end
    """

    {String.trim(source), Naming.module_to_file_path(module_name)}
  end

  @doc """
  Generates an ES Queries module with search/3, list/3, and get_by_id/3 helpers.
  Returns `{source_code, file_path}`.

  `projector_module` is the ES projector module string, e.g.
  `"MyApp.Orders.OrderESProjector"`.
  """
  def gen_es_queries(module_name, projector_module) do
    source = """
    defmodule #{module_name} do
      @moduledoc \"\"\"
      Elasticsearch query helpers for `#{projector_module}`.

      Provides `search/3`, `list/3`, and `get_by_id/3` built on top of the
      `Orkestra.Projection.ES.Query` DSL so callers do not need to write
      boilerplate ES query code.
      \"\"\"

      alias Orkestra.Projection.ES.Query

      @doc \"\"\"
      Executes a custom ES query built with the Query DSL.

      `build_fn` is a 1-arity function that receives a fresh `Query.new()`
      accumulator and must return the result of `Query.build/1`.

      ## Example

          search(MyCluster, "orders", fn q ->
            q
            |> Query.must(term: %{"status" => "placed"})
            |> Query.size(20)
            |> Query.build()
          end)
      \"\"\"
      def search(cluster, index, build_fn) when is_function(build_fn, 1) do
        query = build_fn.(Query.new())
        Snap.Search.search(cluster, index, query)
      end

      @doc \"\"\"
      Returns a paginated list of documents from the given index.

      Options:
        * `:size` - number of results to return (default: 20)
        * `:from` - starting offset for pagination (default: 0)
      \"\"\"
      def list(cluster, index, opts \\\\ []) do
        size = Keyword.get(opts, :size, 20)
        from = Keyword.get(opts, :from, 0)

        query =
          Query.new()
          |> Query.size(size)
          |> Query.from(from)
          |> Query.build()

        Snap.Search.search(cluster, index, query)
      end

      @doc \"\"\"
      Retrieves a single document by its ID.

      Returns `{:ok, map()}` on success or an error tuple.
      \"\"\"
      def get_by_id(cluster, index, id) do
        Snap.Document.get(cluster, index, id)
      end
    end
    """

    {String.trim(source), Naming.module_to_file_path(module_name)}
  end

  # --- Private helpers ---

  defp format_param(param) do
    name = param["name"]
    type = param["type"]
    opts = build_opts(param)
    "  param :#{name}, :#{type}#{opts}"
  end

  defp format_field(field) do
    name = field["name"]
    type = field["type"]
    opts = build_opts(field)
    "  field :#{name}, :#{type}#{opts}"
  end

  defp build_opts(map) do
    opts = []
    opts = if map["required"] == true, do: opts ++ ["required: true"], else: opts

    opts =
      if Map.has_key?(map, "default") && map["default"] != nil,
        do: opts ++ ["default: #{inspect(map["default"])}"],
        else: opts

    case opts do
      [] -> ""
      _ -> ", " <> Enum.join(opts, ", ")
    end
  end

  defp build_event_handler_use(opts) do
    case opts["mode"] do
      "single" ->
        "use Orkestra.EventHandler, event: #{opts["event"]}"

      "multi" ->
        events = opts["events"] |> Enum.join(", ")
        "use Orkestra.EventHandler, events: [#{events}]"

      "topic" ->
        "use Orkestra.EventHandler, topic: \"#{opts["topic"]}\""

      _ ->
        "use Orkestra.EventHandler, event: #{opts["event"]}"
    end
  end

  defp format_schema_field(field) do
    name = field["name"]
    type = field["type"]
    "    field :#{name}, :#{type}"
  end
end
