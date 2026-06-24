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
end
