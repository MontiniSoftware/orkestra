defmodule OrkestraMcp.Introspection do
  @moduledoc false

  @doc """
  Discovers all Orkestra components in the given project directory.

  Returns a map with keys: `:commands`, `:events`, `:command_handlers`,
  `:event_handlers`, `:aggregates`, `:projectors`.
  """
  def discover(project_dir) do
    lib_dir = Path.join(project_dir, "lib")

    files =
      if File.dir?(lib_dir) do
        Path.wildcard(Path.join(lib_dir, "**/*.ex"))
      else
        []
      end

    results = %{
      commands: [],
      events: [],
      command_handlers: [],
      event_handlers: [],
      aggregates: [],
      projectors: []
    }

    Enum.reduce(files, results, fn file, acc ->
      case File.read(file) do
        {:ok, content} -> parse_file(content, acc)
        _ -> acc
      end
    end)
  end

  defp parse_file(content, acc) do
    acc
    |> detect_commands(content)
    |> detect_events(content)
    |> detect_command_handlers(content)
    |> detect_event_handlers(content)
    |> detect_aggregates(content)
    |> detect_projectors(content)
  end

  defp detect_commands(acc, content) do
    if content =~ ~r/use\s+Orkestra\.Command/ do
      case extract_module_name(content) do
        nil ->
          acc

        module_name ->
          params = extract_params(content)
          entry = %{module: module_name, params: params}
          %{acc | commands: acc.commands ++ [entry]}
      end
    else
      acc
    end
  end

  defp detect_events(acc, content) do
    if content =~ ~r/use\s+Orkestra\.Event/ do
      case extract_module_name(content) do
        nil ->
          acc

        module_name ->
          fields = extract_fields(content)
          entry = %{module: module_name, fields: fields}
          %{acc | events: acc.events ++ [entry]}
      end
    else
      acc
    end
  end

  defp detect_command_handlers(acc, content) do
    case Regex.run(~r/use\s+Orkestra\.CommandHandler,\s*command:\s*([\w.]+)/, content) do
      [_, command_module] ->
        case extract_module_name(content) do
          nil ->
            acc

          module_name ->
            entry = %{module: module_name, command: command_module}
            %{acc | command_handlers: acc.command_handlers ++ [entry]}
        end

      nil ->
        acc
    end
  end

  defp detect_event_handlers(acc, content) do
    cond do
      content =~ ~r/use\s+Orkestra\.EventHandler/ ->
        case extract_module_name(content) do
          nil ->
            acc

          module_name ->
            subscription = extract_event_handler_subscription(content)
            entry = Map.merge(%{module: module_name}, subscription)
            %{acc | event_handlers: acc.event_handlers ++ [entry]}
        end

      true ->
        acc
    end
  end

  defp detect_aggregates(acc, content) do
    if content =~ ~r/@behaviour\s+Orkestra\.Aggregate/ do
      case extract_module_name(content) do
        nil -> acc
        module_name -> %{acc | aggregates: acc.aggregates ++ [%{module: module_name}]}
      end
    else
      acc
    end
  end

  defp detect_projectors(acc, content) do
    if content =~ ~r/use\s+Orkestra\.Projector/ do
      case extract_module_name(content) do
        nil ->
          acc

        module_name ->
          repo = extract_option(content, "repo")
          backend = extract_backend(content)
          cluster = extract_option(content, "cluster")
          index_name = extract_string_option(content, "index")
          events = extract_projected_events_all(content)

          entry = %{
            module: module_name,
            repo: repo,
            backend: backend,
            cluster: cluster,
            index: index_name,
            events: events
          }

          %{acc | projectors: acc.projectors ++ [entry]}
      end
    else
      acc
    end
  end

  defp extract_option(content, key) do
    case Regex.run(~r/#{key}:\s*([\w.]+)/, content) do
      [_, value] -> value
      nil -> nil
    end
  end

  defp extract_backend(content) do
    case Regex.run(~r/backend:\s*:(\w+)/, content) do
      [_, "elasticsearch"] -> :elasticsearch
      _ -> :postgres
    end
  end

  defp extract_string_option(content, key) do
    case Regex.run(~r/#{key}:\s*"([^"]+)"/, content) do
      [_, value] -> value
      nil -> nil
    end
  end

  defp extract_projected_events_all(content) do
    # Match both `project EventModule,` and `project(EventModule,` formats
    postgres_events =
      Regex.scan(~r/project[\s(]+([\w.]+),/, content)
      |> Enum.map(fn [_, e] -> e end)

    # Match both `project_es EventModule,` and `project_es(EventModule,` formats
    # Use negative lookbehind via a separate scan to avoid matching `project` inside `project_es`
    es_events =
      Regex.scan(~r/project_es[\s(]+([\w.]+),/, content)
      |> Enum.map(fn [_, e] -> e end)

    Enum.uniq(postgres_events ++ es_events)
  end

  defp extract_module_name(content) do
    case Regex.run(~r/defmodule\s+([\w.]+)/, content) do
      [_, name] -> name
      nil -> nil
    end
  end

  defp extract_params(content) do
    Regex.scan(~r/param[\s(]+:(\w+),\s*:(\w+)(?:,\s*(.+?))?(?:\)|\s*$)/m, content)
    |> Enum.map(fn
      [_, name, type] -> %{name: name, type: type}
      [_, name, type, opts] -> %{name: name, type: type, opts: String.trim(opts)}
    end)
  end

  defp extract_fields(content) do
    Regex.scan(~r/field[\s(]+:(\w+),\s*:(\w+)(?:,\s*(.+?))?(?:\)|\s*$)/m, content)
    |> Enum.map(fn
      [_, name, type] -> %{name: name, type: type}
      [_, name, type, opts] -> %{name: name, type: type, opts: String.trim(opts)}
    end)
  end

  defp extract_event_handler_subscription(content) do
    cond do
      match = Regex.run(~r/use\s+Orkestra\.EventHandler,\s*event:\s*([\w.]+)/, content) ->
        [_, event] = match
        %{event: event}

      match =
          Regex.run(
            ~r/use\s+Orkestra\.EventHandler,\s*events:\s*\[([^\]]+)\]/,
            content
          ) ->
        [_, events_str] = match

        events =
          events_str
          |> String.split(",")
          |> Enum.map(&String.trim/1)

        %{events: events}

      match = Regex.run(~r/use\s+Orkestra\.EventHandler,\s*topic:\s*"([^"]+)"/, content) ->
        [_, topic] = match
        %{topic: topic}

      true ->
        %{}
    end
  end

  @doc """
  Builds a domain map cross-referencing handlers with commands/events.
  """
  def build_domain_map(project_dir) do
    %{
      commands: commands,
      events: events,
      command_handlers: command_handlers,
      event_handlers: event_handlers,
      aggregates: aggregates,
      projectors: projectors
    } = discover(project_dir)

    lines = []

    lines =
      lines ++
        Enum.flat_map(commands, fn cmd ->
          handlers =
            Enum.filter(command_handlers, fn h -> h.command == cmd.module end)

          header = "#{cmd.module} (command)"

          handler_lines =
            Enum.map(handlers, fn h -> "  -> #{h.module} (command_handler)" end)

          [header | handler_lines] ++ [""]
        end)

    lines =
      lines ++
        Enum.flat_map(events, fn evt ->
          handlers =
            Enum.filter(event_handlers, fn h ->
              Map.get(h, :event) == evt.module ||
                evt.module in (Map.get(h, :events) || [])
            end)

          header = "#{evt.module} (event)"

          handler_lines =
            Enum.map(handlers, fn h -> "  -> #{h.module} (event_handler)" end)

          [header | handler_lines] ++ [""]
        end)

    lines =
      lines ++
        Enum.map(aggregates, fn agg ->
          "#{agg.module} (aggregate)"
        end)

    lines =
      lines ++
        Enum.flat_map(projectors, fn proj ->
          header =
            case Map.get(proj, :backend, :postgres) do
              :elasticsearch ->
                "#{proj.module} (projector, backend: elasticsearch, index: #{proj.index})"

              _ ->
                "#{proj.module} (projector, backend: postgres)"
            end

          event_lines = Enum.map(proj.events, fn evt -> "  -> #{evt} (projected_event)" end)
          [header | event_lines] ++ [""]
        end)

    Enum.join(lines, "\n")
  end
end
