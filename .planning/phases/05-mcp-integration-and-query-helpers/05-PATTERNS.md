# Phase 5: MCP Integration and Query Helpers - Pattern Map

**Mapped:** 2026-06-24
**Files analyzed:** 12 (7 new, 5 modified)
**Analogs found:** 12 / 12

---

## File Classification

| New/Modified File | Role | Data Flow | Closest Analog | Match Quality |
|-------------------|------|-----------|----------------|---------------|
| `orkestra_mcp/lib/orkestra_mcp/tools/gen_projection.ex` | tool | request-response | `orkestra_mcp/lib/orkestra_mcp/tools/gen_aggregate.ex` | exact |
| `orkestra_mcp/lib/orkestra_mcp/tools/gen_read_model.ex` | tool | request-response | `orkestra_mcp/lib/orkestra_mcp/tools/gen_command.ex` | exact |
| `orkestra_mcp/lib/orkestra_mcp/tools/gen_queries.ex` | tool | request-response | `orkestra_mcp/lib/orkestra_mcp/tools/gen_command_handler.ex` | exact |
| `orkestra_mcp/lib/orkestra_mcp/resources/list_projections.ex` | resource | request-response | `orkestra_mcp/lib/orkestra_mcp/resources/list_aggregates.ex` | exact |
| `orkestra_mcp/lib/orkestra_mcp/generator.ex` (extend) | utility | transform | `orkestra_mcp/lib/orkestra_mcp/generator.ex` | self |
| `orkestra_mcp/lib/orkestra_mcp/introspection.ex` (extend) | utility | transform | `orkestra_mcp/lib/orkestra_mcp/introspection.ex` | self |
| `orkestra_mcp/lib/orkestra_mcp/naming.ex` (extend) | utility | transform | `orkestra_mcp/lib/orkestra_mcp/naming.ex` | self |
| `orkestra_mcp/lib/orkestra_mcp/server.ex` (extend) | config | request-response | `orkestra_mcp/lib/orkestra_mcp/server.ex` | self |
| `orkestra_mcp/test/orkestra_mcp/tools/gen_projection_test.exs` | test | request-response | `orkestra_mcp/test/orkestra_mcp/tools/gen_aggregate_test.exs` | exact |
| `orkestra_mcp/test/orkestra_mcp/tools/gen_read_model_test.exs` | test | request-response | `orkestra_mcp/test/orkestra_mcp/tools/gen_command_test.exs` | exact |
| `orkestra_mcp/test/orkestra_mcp/tools/gen_queries_test.exs` | test | request-response | `orkestra_mcp/test/orkestra_mcp/tools/gen_command_test.exs` | exact |
| `orkestra_mcp/test/orkestra_mcp/generator_test.exs` (extend) | test | transform | `orkestra_mcp/test/orkestra_mcp/generator_test.exs` | self |
| `orkestra_mcp/test/orkestra_mcp/introspection_test.exs` (extend) | test | transform | `orkestra_mcp/test/orkestra_mcp/introspection_test.exs` | self |

---

## Pattern Assignments

### `orkestra_mcp/lib/orkestra_mcp/tools/gen_projection.ex` (tool, request-response)

**Analog:** `orkestra_mcp/lib/orkestra_mcp/tools/gen_aggregate.ex`

**Imports / module declaration pattern** (lines 1-4):
```elixir
defmodule OrkestraMcp.Tools.GenProjection do
  @moduledoc "Generate an Orkestra Projector module with project/2 clauses and its isolated migration file"

  use Hermes.Server.Component, type: :tool
```

**Schema pattern** (lines 6-26 of gen_aggregate.ex):
```elixir
  schema do
    field(:module_name, :string,
      required: true,
      description: "Full aggregate module name, e.g. MyApp.Orders.OrderAggregate"
    )

    field(:stream_id_field, :string,
      required: true,
      description: "The command param used as stream ID, e.g. order_id"
    )

    field(:commands, :string,
      required: true,
      description: ~s(JSON array of command module names: ["MyApp.Orders.Commands.PlaceOrder"])
    )

    field(:events, :string,
      required: true,
      description: ~s(JSON array of event module names: ["MyApp.Orders.Events.OrderPlaced"])
    )
  end
```
Apply this pattern with fields: `module_name` (required string), `repo_module` (required string), `events` (required string — JSON array of event module names).

**Core execute pattern with two write! calls** (lines 28-48 of gen_aggregate.ex, adapted for two-file output):
```elixir
  @impl true
  def execute(
        %{
          module_name: module_name,
          stream_id_field: stream_id_field,
          commands: commands_json,
          events: events_json
        },
        _frame
      ) do
    project_dir = Application.get_env(:orkestra_mcp, :project_dir)
    commands = Jason.decode!(commands_json)
    events = Jason.decode!(events_json)

    {source, file_path} =
      OrkestraMcp.Generator.gen_aggregate(module_name, stream_id_field, commands, events)

    written = OrkestraMcp.Generator.write!(source, project_dir, file_path)
    {:ok, "Created #{written}\n\n```elixir\n#{source}\n```"}
  end
```
For `GenProjection`, call `Generator.gen_projection/3` AND `Generator.gen_projection_migration/2`, call `write!` twice, and concatenate both paths in the `:ok` response string:
```elixir
  {:ok, "Created #{written_projector}\nCreated #{written_migration}\n\n```elixir\n#{projector_source}\n```"}
```

---

### `orkestra_mcp/lib/orkestra_mcp/tools/gen_read_model.ex` (tool, request-response)

**Analog:** `orkestra_mcp/lib/orkestra_mcp/tools/gen_command.ex`

**Full module pattern** (lines 1-27 of gen_command.ex):
```elixir
defmodule OrkestraMcp.Tools.GenCommand do
  @moduledoc "Generate an Orkestra Command module with typed params"

  use Hermes.Server.Component, type: :tool

  schema do
    field(:module_name, :string,
      required: true,
      description: "Full module name, e.g. MyApp.Orders.Commands.PlaceOrder"
    )

    field(:params, :string,
      required: true,
      description:
        ~s(JSON array of params: [{"name":"product_id","type":"string","required":true}])
    )
  end

  @impl true
  def execute(%{module_name: module_name, params: params_json}, _frame) do
    project_dir = Application.get_env(:orkestra_mcp, :project_dir)
    params = Jason.decode!(params_json)
    {source, file_path} = OrkestraMcp.Generator.gen_command(module_name, params)
    written = OrkestraMcp.Generator.write!(source, project_dir, file_path)
    {:ok, "Created #{written}\n\n```elixir\n#{source}\n```"}
  end
end
```
For `GenReadModel`, schema fields are `module_name` (required string) and `fields` (required string — JSON array of field maps). Also produces a migration file: call `Generator.gen_read_model_migration/1` and a second `write!`, reporting both created paths.

---

### `orkestra_mcp/lib/orkestra_mcp/tools/gen_queries.ex` (tool, request-response)

**Analog:** `orkestra_mcp/lib/orkestra_mcp/tools/gen_command.ex` (same two-field schema pattern)

Schema fields: `module_name` (required string) and `schema_module` (required string — the Ecto schema module the Queries helpers will target). Single `write!` call, single path in response — same as `gen_command`.

---

### `orkestra_mcp/lib/orkestra_mcp/resources/list_projections.ex` (resource, request-response)

**Analog:** `orkestra_mcp/lib/orkestra_mcp/resources/list_aggregates.ex`

**Full module pattern** (lines 1-15 of list_aggregates.ex):
```elixir
defmodule OrkestraMcp.Resources.ListAggregates do
  @moduledoc "Lists all Orkestra Aggregate modules in the project"

  use Hermes.Server.Component,
    type: :resource,
    uri: "orkestra://aggregates",
    mime_type: "application/json"

  @impl true
  def read(_params, _frame) do
    project_dir = Application.get_env(:orkestra_mcp, :project_dir)
    %{aggregates: aggregates} = OrkestraMcp.Introspection.discover(project_dir)
    {:ok, Jason.encode!(aggregates, pretty: true)}
  end
end
```
For `ListProjections`, substitute:
- `uri: "orkestra://projections"`
- `%{projectors: projectors} = OrkestraMcp.Introspection.discover(project_dir)`
- `{:ok, Jason.encode!(projectors, pretty: true)}`

---

### `orkestra_mcp/lib/orkestra_mcp/generator.ex` (extend — utility, transform)

**Analog:** self — the existing file is the direct template.

**Function shape contract** (lines 12-26 of generator.ex):
```elixir
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
```
Every new generator function must:
1. Build the source string with a heredoc
2. Return `{String.trim(source), Naming.module_to_file_path(module_name)}`
3. Never perform I/O — `write!` is the caller's responsibility.

**Multi-clause helper pattern** (lines 100-162 of generator.ex — gen_aggregate):
```elixir
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
```
Use `Enum.map_join/3` with empty-list guard for `gen_projection` event clauses.

**write! helper** (lines 168-173 of generator.ex):
```elixir
  def write!(source_code, project_dir, file_path) do
    full_path = Path.join(project_dir, file_path)
    full_path |> Path.dirname() |> File.mkdir_p!()
    File.write!(full_path, source_code <> "\n")
    full_path
  end
```
All tool modules call this unchanged. New generator functions never call it directly.

**New functions to add to generator.ex:**
- `gen_projection/3` — `(module_name, repo_module, events)` → `{source, file_path}`
- `gen_projection_migration/2` — `(projector_module_name, timestamp \\ nil)` → `{source, file_path}` with path `priv/projections/<slug>/migrations/<ts>_create_<slug>_read_model.exs`
- `gen_read_model/2` — `(module_name, fields)` → `{source, file_path}`, calls `Naming.module_to_table_name/1`
- `gen_read_model_migration/2` — `(schema_module_name, timestamp \\ nil)` → `{source, file_path}`
- `gen_queries/2` — `(module_name, schema_module)` → `{source, file_path}`

---

### `orkestra_mcp/lib/orkestra_mcp/introspection.ex` (extend — utility, transform)

**Analog:** self.

**detect_* function shape** (lines 112-121 of introspection.ex — detect_aggregates):
```elixir
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
```

**detect_command_handlers with Regex.run/2** (lines 77-92 of introspection.ex):
```elixir
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
```
`detect_projectors/2` must follow this `Regex.run` + `extract_module_name` two-level case pattern. Use regex `~r/use\s+Orkestra\.Projector,\s*repo:\s*([\w.]+)/` (matches `use Orkestra.Projector, repo: MyApp.Repo`). Also extract projected events via `Regex.scan(~r/project\s+([\w.]+),/, content)`.

**discover/1 accumulator init** (lines 20-26 of introspection.ex):
```elixir
    results = %{
      commands: [],
      events: [],
      command_handlers: [],
      event_handlers: [],
      aggregates: []
    }
```
Add `:projectors: []` to this map. Update `parse_file/2` to pipe through `detect_projectors/2`.

**build_domain_map/1 line format** (lines 178-227 of introspection.ex):
```elixir
    lines =
      lines ++
        Enum.map(aggregates, fn agg ->
          "#{agg.module} (aggregate)"
        end)
```
Add a projectors block after aggregates using the same `(projector)` label convention:
```elixir
    lines =
      lines ++
        Enum.flat_map(projectors, fn proj ->
          ["#{proj.module} (projector)"]
        end)
```

---

### `orkestra_mcp/lib/orkestra_mcp/naming.ex` (extend — utility, transform)

**Analog:** self.

**Existing module_to_file_path/1 pattern** (lines 10-16 of naming.ex):
```elixir
  def module_to_file_path(module_name) do
    parts =
      module_name
      |> String.split(".")
      |> Enum.map(&Macro.underscore/1)

    Path.join(["lib" | parts]) <> ".ex"
  end
```
New function `module_to_table_name/1` follows the same `String.split(".") |> List.last() |> Macro.underscore/1` pattern, then appends `"s"` for pluralisation:
```elixir
  def module_to_table_name(module_name) do
    module_name
    |> String.split(".")
    |> List.last()
    |> Macro.underscore()
    |> Kernel.<>("s")
  end
```

---

### `orkestra_mcp/lib/orkestra_mcp/server.ex` (extend — config)

**Analog:** self.

**Existing component registration pattern** (lines 9-25 of server.ex):
```elixir
  # Tools
  component(OrkestraMcp.Tools.GenCommand)
  component(OrkestraMcp.Tools.GenEvent)
  component(OrkestraMcp.Tools.GenCommandHandler)
  component(OrkestraMcp.Tools.GenEventHandler)
  component(OrkestraMcp.Tools.GenAggregate)

  # Resources
  component(OrkestraMcp.Resources.ListCommands)
  component(OrkestraMcp.Resources.ListEvents)
  component(OrkestraMcp.Resources.ListHandlers)
  component(OrkestraMcp.Resources.ListAggregates)
  component(OrkestraMcp.Resources.DomainMap)
```
Add three tool lines after `GenAggregate` and one resource line after `ListAggregates`, preserving the section comments and alphabetical-ish ordering.

---

### Tool test files (gen_projection_test.exs, gen_read_model_test.exs, gen_queries_test.exs)

**Analog:** `orkestra_mcp/test/orkestra_mcp/tools/gen_aggregate_test.exs` (for gen_projection) and `orkestra_mcp/test/orkestra_mcp/tools/gen_command_test.exs` (for gen_read_model / gen_queries)

**Full test file pattern** (lines 1-41 of gen_aggregate_test.exs):
```elixir
defmodule OrkestraMcp.Tools.GenAggregateTest do
  use ExUnit.Case, async: false   # MUST be async: false — global Application env

  alias OrkestraMcp.Tools.GenAggregate

  setup do
    tmp_dir = Path.join(System.tmp_dir!(), "orkestra_mcp_agg_test_#{:rand.uniform(100_000)}")
    File.mkdir_p!(tmp_dir)
    Application.put_env(:orkestra_mcp, :project_dir, tmp_dir)

    on_exit(fn ->
      File.rm_rf!(tmp_dir)
      Application.delete_env(:orkestra_mcp, :project_dir)
    end)

    %{tmp_dir: tmp_dir}
  end

  test "creates aggregate file", %{tmp_dir: tmp_dir} do
    commands_json = Jason.encode!(["MyApp.Commands.PlaceOrder"])
    events_json = Jason.encode!(["MyApp.Events.OrderPlaced"])

    {:ok, result} =
      GenAggregate.execute(
        %{
          module_name: "MyApp.OrderAggregate",
          stream_id_field: "order_id",
          commands: commands_json,
          events: events_json
        },
        nil
      )

    assert result =~ "Created"
    assert result =~ "@behaviour Orkestra.Aggregate"
    assert result =~ "command.params.order_id"

    file = Path.join(tmp_dir, "lib/my_app/order_aggregate.ex")
    assert File.exists?(file)
  end
end
```
Key assertions for `gen_projection_test.exs`:
- `assert result =~ "Created"` (twice — two files)
- `assert result =~ "use Orkestra.Projector"`
- `assert File.exists?(projector_file)`
- `assert File.exists?(migration_file)` — path must start with `priv/projections/`

---

### Generator unit tests (extend generator_test.exs)

**Analog:** self — extend with new `describe` blocks.

**Full describe block pattern** (lines 6-21 of generator_test.exs):
```elixir
  describe "gen_command/2" do
    test "generates valid Elixir command module" do
      params = [
        %{"name" => "product_id", "type" => "string", "required" => true},
        %{"name" => "quantity", "type" => "integer", "default" => 1}
      ]

      {source, file_path} = Generator.gen_command("MyApp.Orders.Commands.PlaceOrder", params)

      assert file_path == "lib/my_app/orders/commands/place_order.ex"
      assert source =~ "defmodule MyApp.Orders.Commands.PlaceOrder"
      assert source =~ "use Orkestra.Command"
      assert source =~ "param :product_id, :string, required: true"
      assert source =~ "param :quantity, :integer, default: 1"
      assert {:ok, _} = Code.string_to_quoted(source)  # MANDATORY parsability check
    end
  end
```
Every new generator `describe` block MUST end with `assert {:ok, _} = Code.string_to_quoted(source)`. This is the primary quality gate. `async: true` is fine for generator pure-unit tests (no Application env).

For `gen_projection_migration`, additionally assert:
- `file_path =~ "priv/projections/"` — never `priv/repo/migrations/`
- `source =~ "use Ecto.Migration"`

---

### Introspection tests (extend introspection_test.exs)

**Analog:** self — extend with new `describe` / `test` blocks.

**Fixture directory reference pattern** (line 6 of introspection_test.exs):
```elixir
  @fixture_dir Path.join([__DIR__, "..", "fixtures", "sample_project"]) |> Path.expand()
```

**discover/1 test pattern** (lines 8-91 of introspection_test.exs):
```elixir
  describe "discover/1" do
    test "discovers aggregates" do
      %{aggregates: aggregates} = Introspection.discover(@fixture_dir)

      aggregate = Enum.find(aggregates, &(&1.module == "MyApp.Orders.OrderAggregate"))
      assert aggregate
    end

    test "returns empty lists for project with no Orkestra modules" do
      result = Introspection.discover("/tmp/empty_project_#{:rand.uniform(100_000)}")

      assert result.commands == []
      assert result.aggregates == []
    end
  end
```
New `discover/1` test for projectors:
- Requires a fixture file `test/fixtures/sample_project/lib/my_app/orders/projectors/order_projector.ex` containing `use Orkestra.Projector, repo: MyApp.Repo`
- Assert `result.projectors != []` and entry has `:module`, `:repo`, `:events` keys

**build_domain_map/1 test pattern** (lines 93-103 of introspection_test.exs):
```elixir
  describe "build_domain_map/1" do
    test "produces a readable domain map" do
      map = Introspection.build_domain_map(@fixture_dir)

      assert map =~ "MyApp.Orders.Commands.PlaceOrder (command)"
      assert map =~ "-> MyApp.Orders.Handlers.PlaceOrderHandler (command_handler)"
      assert map =~ "MyApp.Orders.OrderAggregate (aggregate)"
    end
  end
```
New assertion: `assert map =~ "(projector)"` once fixture is added.

---

## Shared Patterns

### Application.get_env project_dir
**Source:** `orkestra_mcp/lib/orkestra_mcp/tools/gen_command.ex` line 21
**Apply to:** All three new tool `execute/2` functions
```elixir
project_dir = Application.get_env(:orkestra_mcp, :project_dir)
```

### Generator.write! call and response format
**Source:** `orkestra_mcp/lib/orkestra_mcp/tools/gen_command.ex` lines 23-25
**Apply to:** All three new tool `execute/2` functions
```elixir
    written = OrkestraMcp.Generator.write!(source, project_dir, file_path)
    {:ok, "Created #{written}\n\n```elixir\n#{source}\n```"}
```
For `GenProjection` and `GenReadModel` (two files each), call `write!` twice and list both paths before the code block.

### Jason.decode! for JSON array params
**Source:** `orkestra_mcp/lib/orkestra_mcp/tools/gen_aggregate.ex` lines 39-40
**Apply to:** `GenProjection.execute/2` for the `events` field
```elixir
    events = Jason.decode!(events_json)
```

### Jason.encode! for resource responses
**Source:** `orkestra_mcp/lib/orkestra_mcp/resources/list_aggregates.ex` line 13
**Apply to:** `ListProjections.read/2`
```elixir
    {:ok, Jason.encode!(projectors, pretty: true)}
```

### async: false in tool tests
**Source:** `orkestra_mcp/test/orkestra_mcp/tools/gen_aggregate_test.exs` line 2
**Apply to:** All three new tool test files
```elixir
use ExUnit.Case, async: false
```
Generator pure-unit tests (`generator_test.exs` describe blocks) use `async: true`.

### Code.string_to_quoted/1 parsability check
**Source:** `orkestra_mcp/test/orkestra_mcp/generator_test.exs` line 20
**Apply to:** Every new describe block in generator_test.exs
```elixir
      assert {:ok, _} = Code.string_to_quoted(source)
```

### Naming.module_to_file_path/1 return value
**Source:** `orkestra_mcp/lib/orkestra_mcp/generator.ex` lines 25, 47, 66, 90, 162
**Apply to:** All new generator functions — always the second element of the returned tuple
```elixir
    {String.trim(source), Naming.module_to_file_path(module_name)}
```

---

## No Analog Found

All new files have close analogs. No novel patterns are required.

---

## Fixture File Needed

The introspection tests for `detect_projectors` require a new fixture file (not a source file):

| Fixture File | Purpose |
|--------------|---------|
| `orkestra_mcp/test/fixtures/sample_project/lib/my_app/orders/projectors/order_projector.ex` | Provides a `use Orkestra.Projector, repo:` example for `discover/1` tests |

This fixture must contain `use Orkestra.Projector, repo: MyApp.Repo` and at least one `project EventModule,` clause, so `detect_projectors/2` and `extract_projected_events/1` can be exercised.

---

## Metadata

**Analog search scope:** `orkestra_mcp/lib/orkestra_mcp/tools/`, `orkestra_mcp/lib/orkestra_mcp/resources/`, `orkestra_mcp/lib/orkestra_mcp/`, `orkestra_mcp/test/`
**Files scanned:** 13 source files, 6 test files
**Pattern extraction date:** 2026-06-24
