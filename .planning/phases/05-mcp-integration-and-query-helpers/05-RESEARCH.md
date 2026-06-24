# Phase 5: MCP Integration and Query Helpers - Research

**Researched:** 2026-06-24
**Domain:** orkestra_mcp subproject — Hermes.Server.Component (tools/resources), OrkestraMcp.Generator, OrkestraMcp.Introspection
**Confidence:** HIGH

---

<user_constraints>
## User Constraints (from CONTEXT.md)

### Locked Decisions

None — all implementation choices at Claude's discretion.

### Claude's Discretion

All implementation choices are at Claude's discretion — infrastructure phase with well-established
patterns in the existing codebase. Follow the existing `gen_*` tool and `list_*` resource patterns
in `orkestra_mcp/` exactly. Use ROADMAP phase goal, success criteria, and codebase conventions to
guide decisions.

### Deferred Ideas (OUT OF SCOPE)

None — discuss phase skipped.
</user_constraints>

<phase_requirements>
## Phase Requirements

| ID | Description | Research Support |
|----|-------------|------------------|
| READ-02 | Optional generated `Queries` module exposes `list/1` (paged) and `get_by/2` per read model | Generator.gen_queries/2 function + GenQueries tool following gen_aggregate pattern |
| MCP-01 | MCP server provides `gen_projection` generator that scaffolds a projector plus its migration | New tool module + Generator.gen_projection/3 function |
| MCP-02 | MCP server provides `gen_read_model` generator (schema + migration scaffolding) | New tool module + Generator.gen_read_model/2 function |
| MCP-03 | Projections and read models surfaced in MCP introspection resources (`list_projections`, `domain_map`) | Extend Introspection.discover/1 + new ListProjections resource + update DomainMap |
</phase_requirements>

---

## Summary

Phase 5 is purely additive to the `orkestra_mcp/` subproject: it extends the existing generator, introspection, and server modules with projection-aware counterparts following established patterns. No new MCP framework knowledge is needed — the existing five tools (`gen_command`, `gen_event`, `gen_command_handler`, `gen_event_handler`, `gen_aggregate`) and five resources (`list_commands`, `list_events`, `list_handlers`, `list_aggregates`, `domain_map`) define the exact templates to follow for the new additions.

The four deliverables are: (1) `gen_projection` tool — scaffolds a `use Orkestra.Projector` module plus its per-projection migration; (2) `gen_read_model` tool — scaffolds an Ecto schema module plus its migration file; (3) `gen_queries` tool — scaffolds an optional Queries module with `list/1` and `get_by/2` helpers; (4) `list_projections` resource and an updated `domain_map` resource that include projector/read-model entries.

All generator functions live in `OrkestraMcp.Generator` (already the sole code-gen module), all discovery logic lives in `OrkestraMcp.Introspection` (already the sole file-scanning module), and all MCP wiring lives in `OrkestraMcp.Server` component registrations. The `Code.string_to_quoted/1` validity check used in generator unit tests must be maintained for new generators.

**Primary recommendation:** Add four new generator functions to `OrkestraMcp.Generator`, one new detection function to `OrkestraMcp.Introspection`, three new tool modules and one new resource module, then wire them into `OrkestraMcp.Server`. Test each with the same tmp-dir + `Application.put_env` pattern used by existing tool tests.

---

## Architectural Responsibility Map

| Capability | Primary Tier | Secondary Tier | Rationale |
|------------|-------------|----------------|-----------|
| Code generation (scaffold text + file path) | `OrkestraMcp.Generator` | — | Single source of truth for all scaffold functions; keeps tool modules thin |
| MCP tool wiring / schema declaration | `OrkestraMcp.Tools.*` | — | Each tool module owns its Hermes schema and calls Generator |
| Project file scanning / detection | `OrkestraMcp.Introspection` | — | All static-analysis discovery centralised here |
| MCP resource wiring | `OrkestraMcp.Resources.*` | — | Each resource module reads Introspection and encodes JSON/text |
| Server registration | `OrkestraMcp.Server` | — | Single `component(...)` list; no behaviour logic here |

---

## Standard Stack

### Core (already in use — no new deps required)
| Library | Version | Purpose | Why Standard |
|---------|---------|---------|--------------|
| hermes_mcp | 0.14.1 | MCP server framework — `Hermes.Server.Component` macro | Already the project's MCP stack [VERIFIED: mix.lock] |
| jason | 1.4.4 | JSON encode/decode for tool params and resource responses | Already used by every tool and resource [VERIFIED: codebase] |

### No new dependencies
Phase 5 scaffolds Ecto code into the *consumer* project but the orkestra_mcp subproject itself never calls Ecto. Generated migration files contain plain Elixir source (strings); they do not compile inside orkestra_mcp. [VERIFIED: existing gen_aggregate pattern]

---

## Architecture Patterns

### System Architecture Diagram

```
MCP Client Request
        |
        v
OrkestraMcp.Server (component registration)
        |
   tool call ─────────────────────────────── resource read
        |                                         |
OrkestraMcp.Tools.GenProjection            OrkestraMcp.Resources.ListProjections
OrkestraMcp.Tools.GenReadModel             OrkestraMcp.Resources.DomainMap (extended)
OrkestraMcp.Tools.GenQueries
        |
        v
OrkestraMcp.Generator
  gen_projection/3 ─────────► {source, file_path} pair
  gen_read_model/2 ─────────► {source, file_path} pair
  gen_projection_migration/3 ► {source, file_path} pair
  gen_read_model_migration/2 ► {source, file_path} pair
  gen_queries/2 ────────────► {source, file_path} pair
        |
        v
Generator.write!(source, project_dir, file_path)
        |
        v
{:ok, "Created <path>\n\n```elixir\n<source>\n```"}

resource read ──────────────────────────────────────────────
        |
        v
OrkestraMcp.Introspection.discover/1 (extended)
  detect_projectors/2 ─────► scans for `use Orkestra.Projector`
        |
        v
Jason.encode!(projectors, pretty: true)   (ListProjections)
build_domain_map/1 extended               (DomainMap)
```

### Recommended Project Structure (additions only)
```
orkestra_mcp/lib/orkestra_mcp/
├── tools/
│   ├── gen_projection.ex      # NEW — MCP-01
│   ├── gen_read_model.ex      # NEW — MCP-02
│   └── gen_queries.ex         # NEW — READ-02
└── resources/
    └── list_projections.ex    # NEW — MCP-03

orkestra_mcp/test/orkestra_mcp/
├── tools/
│   ├── gen_projection_test.exs    # NEW
│   ├── gen_read_model_test.exs    # NEW
│   └── gen_queries_test.exs       # NEW
└── resources/
    └── list_projections_test.exs  # NEW (if testing at resource level)

# Generator unit tests extend existing file:
orkestra_mcp/test/orkestra_mcp/generator_test.exs  (extended)
# Introspection unit tests extend existing file:
orkestra_mcp/test/orkestra_mcp/introspection_test.exs (extended)
```

### Pattern 1: Tool Module Structure (from existing code)
**What:** Every generator tool is a thin shim — schema declaration + `execute/2` that calls `Generator.<fn>` and `Generator.write!`.
**When to use:** All three new tools follow this exactly.
**Example (from existing source):**
```elixir
# Source: orkestra_mcp/lib/orkestra_mcp/tools/gen_aggregate.ex [VERIFIED: codebase]
defmodule OrkestraMcp.Tools.GenAggregate do
  @moduledoc "Generate an Orkestra Aggregate module with decide/evolve clauses"

  use Hermes.Server.Component, type: :tool

  schema do
    field(:module_name, :string, required: true, description: "...")
    field(:stream_id_field, :string, required: true, description: "...")
    field(:commands, :string, required: true, description: "...")
    field(:events, :string, required: true, description: "...")
  end

  @impl true
  def execute(%{module_name: mn, ...}, _frame) do
    project_dir = Application.get_env(:orkestra_mcp, :project_dir)
    {source, file_path} = OrkestraMcp.Generator.gen_aggregate(mn, ...)
    written = OrkestraMcp.Generator.write!(source, project_dir, file_path)
    {:ok, "Created #{written}\n\n```elixir\n#{source}\n```"}
  end
end
```

### Pattern 2: Resource Module Structure
**What:** Resource modules declare a URI + mime_type and call `Introspection.discover/1` or `build_domain_map/1`.
**When to use:** `ListProjections` follows `ListAggregates` exactly.
**Example:**
```elixir
# Source: orkestra_mcp/lib/orkestra_mcp/resources/list_aggregates.ex [VERIFIED: codebase]
defmodule OrkestraMcp.Resources.ListAggregates do
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

### Pattern 3: Generator Function Shape
**What:** Generator functions return `{source_string, relative_file_path}` — pure text transformation, no I/O.
**When to use:** All new `gen_*` functions must follow this contract.

```elixir
# Source: orkestra_mcp/lib/orkestra_mcp/generator.ex [VERIFIED: codebase]
def gen_aggregate(module_name, stream_id_field, commands, events) do
  source = """..."""
  {String.trim(source), Naming.module_to_file_path(module_name)}
end
```

### Pattern 4: Introspection Detection Function
**What:** Each `detect_*` function takes `(acc, content)`, pattern-matches on file content, and returns an updated accumulator.
**When to use:** New `detect_projectors/2` follows this shape exactly.

```elixir
# Source: orkestra_mcp/lib/orkestra_mcp/introspection.ex [VERIFIED: codebase]
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

### Anti-Patterns to Avoid

- **Inline Ecto calls in orkestra_mcp:** The MCP subproject never loads Ecto — generated migration text is a plain string, not a compiled module. Do not add `ecto` or `ecto_sql` as deps to `orkestra_mcp/mix.exs`.
- **Multi-file writes per tool invocation (without separate returns):** Existing tools return one `{source, file_path}` pair. For `gen_projection`, two files are needed (projector module + migration). Return both paths concatenated in the `:ok` string, or make two `write!` calls and list both in the response. The cleanest approach is: two calls to `write!`, and a response listing both created paths.
- **Skipping `Code.string_to_quoted/1` in generator tests:** Every existing generator test validates parsability. New generators must do the same.

---

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| MCP tool schema validation | Custom param validation | `field/3` in `schema do` block (Hermes.Server.Component) | Peri validation is injected automatically; duplicate validation leads to inconsistency [VERIFIED: hermes_mcp source] |
| File path derivation from module name | Custom path logic | `OrkestraMcp.Naming.module_to_file_path/1` | Already handles `.` → `/` + `Macro.underscore` + `.ex` suffix [VERIFIED: naming.ex] |
| Migration timestamp generation | `System.os_time(:second)` | Same pattern — no library needed, but use consistent timestamp prefix | Mix ecto.gen.migration uses timestamp prefix; generators should follow the same `YYYYMMDDHHMMSS_` convention |
| Projector detection regex | Custom scanner | Extend `detect_*` pattern in `Introspection` | Consistent with all other detection; reuses `extract_module_name/1` helper |

**Key insight:** The Generator + Introspection + Naming modules form a complete, tested toolkit for adding new scaffold types. New capabilities are added by extending these three modules — not by creating parallel utilities.

---

## Common Pitfalls

### Pitfall 1: gen_projection produces two files
**What goes wrong:** A projector scaffold needs (a) the projector module file and (b) an isolated migration file. If only one file is generated, the developer must hand-write the other.
**Why it happens:** Every existing generator produces exactly one `{source, file_path}` pair. The migration is often overlooked.
**How to avoid:** `Generator.gen_projection/3` produces the projector module. `Generator.gen_projection_migration/2` produces the migration (separate function). The `GenProjection` tool calls both and reports both created paths.
**Warning signs:** MCP-01 success criterion says "scaffolds a projector module plus its isolated migration file" — both are required.

### Pitfall 2: Migration file path must follow the per-projection isolated path convention
**What goes wrong:** Generating a migration at `priv/repo/migrations/` would put it in the app's main migration history, violating MIG-01 (isolated per-projection migrations).
**Why it happens:** Default Ecto migration path is `priv/repo/migrations/`.
**How to avoid:** Use the same slug derivation as `Orkestra.Projector.__before_compile__/1`: `"priv/projections/<slug>/migrations/<timestamp>_create_<slug>_read_model.exs"`. The slug is `module_name |> String.downcase() |> String.replace(".", "_")`.
**Warning signs:** If the generated path starts with `priv/repo/migrations`, it is wrong.

### Pitfall 3: Projector detection regex must match the exact `use Orkestra.Projector` pattern
**What goes wrong:** The macro `use Orkestra.Projector, repo: ...` has options after the module name. A naive `content =~ "Orkestra.Projector"` also matches `Orkestra.Projector.GenServer` in config files or comments.
**Why it happens:** String matching without word boundaries.
**How to avoid:** Use `~r/use\s+Orkestra\.Projector[\s,]/ ` (matches the use macro followed by whitespace or comma for options). Extract the repo option: `~r/use\s+Orkestra\.Projector,\s*repo:\s*([\w.]+)/` for the repo module name.
**Warning signs:** Tests discover false positives when running against fixtures containing Projector.GenServer references.

### Pitfall 4: Queries module needs the schema module reference, not just the module name
**What goes wrong:** `Ecto.Query.from(p in SchemaModule, ...)` requires the actual schema module atom. If gen_queries doesn't take a `schema_module` parameter, the developer must edit the generated `from/2` clause.
**Why it happens:** Analogous to how `gen_command_handler` takes a `command_module` string to produce the `use Orkestra.CommandHandler, command: ...` line.
**How to avoid:** `Generator.gen_queries/2` takes `(module_name, schema_module)` and uses `schema_module` in the `from(q in #{schema_module})` clause. The `GenQueries` tool schema has `schema_module` as a required field.
**Warning signs:** Generated `list/1` has `from(q in nil, ...)` or a TODO comment.

### Pitfall 5: domain_map text output format must include projections in the same style
**What goes wrong:** Adding projections to `build_domain_map/1` with a different line format breaks Claude's ability to parse the text resource consistently.
**Why it happens:** The domain map is free-form text; no strict schema enforces consistency.
**How to avoid:** Follow the exact pattern: `"#{projector_module} (projector)"` on one line, `"  -> #{read_model_module} (read_model)"` as an optional sub-line. The parenthesised type label is the key convention.
**Warning signs:** `domain_map` resource output has projectors rendered differently from commands/events/aggregates.

### Pitfall 6: Tool tests must use `async: false` (global Application env)
**What goes wrong:** Tool tests set `Application.put_env(:orkestra_mcp, :project_dir, tmp_dir)` which is global process state. Running with `async: true` causes race conditions.
**Why it happens:** All five existing tool tests use `async: false` for this reason. Forgetting it when adding new tests causes intermittent failures.
**How to avoid:** Always declare `use ExUnit.Case, async: false` in tool test files. Generator-pure unit tests (no Application env) can use `async: true`.

---

## Code Examples

Verified patterns from existing source:

### gen_projection (new — follows gen_aggregate pattern)
```elixir
# Source: derived from Orkestra.Projector documentation [VERIFIED: lib/orkestra/projector.ex]
def gen_projection(module_name, repo_module, events) do
  event_clauses =
    events
    |> Enum.map_join("\n\n", fn evt ->
      """
          project #{evt}, fn event, multi ->
            # TODO: implement read-model update for #{evt}
            multi
          end
      """
    end)

  source = """
  defmodule #{module_name} do
    use Orkestra.Projector,
      repo: #{repo_module},
      event_store: Orkestra.EventStore

  #{String.trim(event_clauses)}
  end
  """

  {String.trim(source), Naming.module_to_file_path(module_name)}
end
```

### gen_projection_migration (new)
```elixir
# Source: derived from per-projection isolation design [VERIFIED: lib/orkestra/projector.ex]
def gen_projection_migration(projector_module_name, timestamp \\ nil) do
  ts = timestamp || Calendar.strftime(DateTime.utc_now(), "%Y%m%d%H%M%S")
  slug =
    projector_module_name
    |> String.downcase()
    |> String.replace(".", "_")

  migration_module = Macro.camelize("create_#{slug}_migration_#{ts}")
  file_name = "#{ts}_create_#{slug}_read_model.exs"
  file_path = Path.join(["priv", "projections", slug, "migrations", file_name])

  source = """
  defmodule #{migration_module} do
    use Ecto.Migration

    def up do
      # TODO: create read-model table(s) for #{projector_module_name}
      # Example:
      # create table(:#{slug}_read_models, primary_key: false) do
      #   add :id, :binary_id, primary_key: true
      #   # add your fields here
      #   timestamps()
      # end
    end

    def down do
      # TODO: drop read-model table(s)
    end
  end
  """

  {String.trim(source), file_path}
end
```

### gen_read_model (new — Ecto schema scaffold)
```elixir
# Source: derived from Ecto schema conventions [VERIFIED: lib/orkestra/projection/checkpoint.ex]
def gen_read_model(module_name, fields) do
  fields_code = fields |> Enum.map_join("\n", &format_schema_field/1)

  source = """
  defmodule #{module_name} do
    use Ecto.Schema

    @primary_key {:id, :binary_id, autogenerate: true}
    @timestamps_opts [type: :utc_datetime_usec]

    schema "#{Naming.module_to_table_name(module_name)}" do
  #{fields_code}
      timestamps()
    end
  end
  """

  {String.trim(source), Naming.module_to_file_path(module_name)}
end
```

### gen_queries (new — Queries module scaffold)
```elixir
# Source: derived from READ-02 requirement [VERIFIED: REQUIREMENTS.md]
def gen_queries(module_name, schema_module) do
  source = """
  defmodule #{module_name} do
    @moduledoc \"\"\"
    Query helpers for the #{schema_module} read model.
    \"\"\"

    import Ecto.Query

    alias #{schema_module}

    @doc \"\"\"
    Returns a paginated list of read-model entries.
    Options: `:page` (1-based, default 1), `:page_size` (default 20).
    \"\"\"
    def list(repo, opts \\\\ []) do
      page = Keyword.get(opts, :page, 1)
      page_size = Keyword.get(opts, :page_size, 20)
      offset = (page - 1) * page_size

      repo.all(
        from(q in #{schema_module},
          limit: ^page_size,
          offset: ^offset
        )
      )
    end

    @doc \"\"\"
    Returns entries matching all key-value pairs in `filters`.
    Example: get_by(repo, [status: "active"])
    \"\"\"
    def get_by(repo, filters) when is_list(filters) do
      repo.all(
        from(q in #{schema_module},
          where: ^filters
        )
      )
    end
  end
  """

  {String.trim(source), Naming.module_to_file_path(module_name)}
end
```

### detect_projectors in Introspection (new)
```elixir
# Source: derived from detect_aggregates pattern [VERIFIED: introspection.ex]
defp detect_projectors(acc, content) do
  case Regex.run(~r/use\s+Orkestra\.Projector,\s*repo:\s*([\w.]+)/, content) do
    [_, repo_module] ->
      case extract_module_name(content) do
        nil ->
          acc
        module_name ->
          events = extract_projected_events(content)
          entry = %{module: module_name, repo: repo_module, events: events}
          %{acc | projectors: acc.projectors ++ [entry]}
      end
    nil ->
      acc
  end
end

defp extract_projected_events(content) do
  Regex.scan(~r/project\s+([\w.]+),/, content)
  |> Enum.map(fn [_, event_module] -> event_module end)
end
```

### Naming.module_to_table_name (new helper)
```elixir
# Source: standard Ecto/Phoenix naming convention [ASSUMED]
def module_to_table_name(module_name) do
  module_name
  |> String.split(".")
  |> List.last()
  |> Macro.underscore()
  |> Kernel.<>("s")  # pluralise: "OrderReadModel" -> "order_read_models"
end
```

### Server registration additions
```elixir
# Source: orkestra_mcp/lib/orkestra_mcp/server.ex [VERIFIED: codebase]
# Add to existing component list:
component(OrkestraMcp.Tools.GenProjection)
component(OrkestraMcp.Tools.GenReadModel)
component(OrkestraMcp.Tools.GenQueries)
component(OrkestraMcp.Resources.ListProjections)
```

---

## State of the Art

| Old Approach | Current Approach | When Changed | Impact |
|--------------|------------------|--------------|--------|
| Single gen_aggregate returns one file | gen_projection returns two files (module + migration) | Phase 5 design | Tool execute/2 must call write! twice and concatenate both paths in response |
| Introspection.discover returns 5 keys | Returns 6 keys (adds :projectors) | Phase 5 | All callers of discover/1 that pattern-match the full map must be updated; ListProjections is the only new caller |
| domain_map shows commands/events/aggregates | domain_map also shows projectors | Phase 5 | build_domain_map/1 must be extended |

**Nothing deprecated in this phase.** [VERIFIED: codebase inspection]

---

## Assumptions Log

| # | Claim | Section | Risk if Wrong |
|---|-------|---------|---------------|
| A1 | `Naming.module_to_table_name/1` does not yet exist in `naming.ex` — it needs to be added | Code Examples | Low — if it exists, skip adding it; if pattern differs, adjust gen_read_model |
| A2 | Migration timestamp should use `Calendar.strftime(DateTime.utc_now(), "%Y%m%d%H%M%S")` — standard Mix ecto format | Code Examples | Low — only affects file name cosmetics; functionality unaffected |
| A3 | `gen_queries` injects `repo` as a parameter to `list/1` and `get_by/2` rather than embedding it at generation time | Code Examples — Queries scaffold | Medium — if the team prefers a compile-time repo reference, the generated code uses `alias @repo` instead; READ-02 is silent on this |
| A4 | The `domain_map` text resource should include projectors as `"module (projector)"` lines, not as separate JSON section | Code Examples | Low — text format is internal; DomainMap resource returns `text/plain` which already mixes types |

**Four assumptions** — all low/medium risk and all confined to code shape, not architecture decisions.

---

## Open Questions

1. **Queries module repo injection style (A3)**
   - What we know: READ-02 says `list/1` (paged) and `get_by/2`; it does not specify whether `repo` is a parameter or a compile-time capture.
   - What's unclear: Injecting `repo` at call time (`list(repo, opts)`) is more flexible for testing; capturing at generation time (`@repo MyApp.OrderProjection.Repo`) is closer to how Ecto.Repo works natively.
   - Recommendation: Use runtime injection (`list(repo, opts \\ [])`) — matches how GenServer passes repo at runtime; consistent with existing storage adapter pattern.

2. **Read model migration: generate only stub or include Orkestra.Projection.Migration.up/0 delegation?**
   - What we know: `gen_projection_migration` scaffolds the per-projection migration; `Orkestra.Projection.Migration` only creates the internal checkpoint/dead-letter tables, not user read-model tables.
   - What's unclear: Should the read model migration also call `Orkestra.Projection.Migration.up()` as a dependency, or leave that to the developer?
   - Recommendation: Keep them separate. The per-projection read-model migration creates the developer's tables. The Orkestra internal migration (`projection_checkpoints`, `projection_dead_letters`) is a separate one-time setup — the `Conventions` prompt already guides developers to create it.

---

## Environment Availability

| Dependency | Required By | Available | Version | Fallback |
|------------|------------|-----------|---------|----------|
| Elixir / Mix | All compilation and tests | Yes | 1.18.2 | — |
| Erlang/OTP | Runtime | Yes | OTP 27 | — |
| hermes_mcp 0.14.1 | Tool/Resource components | Yes | 0.14.1 | — |
| PostgreSQL | Tests of generated migrations | No | — | None needed — generators produce text files; no DB needed for MCP tests |

**Missing dependencies with no fallback:** None. All phase 5 work is code-generation; no database is needed to test it.

---

## Validation Architecture

### Test Framework
| Property | Value |
|----------|-------|
| Framework | ExUnit (built-in Elixir, version 1.18) |
| Config file | `orkestra_mcp/test/test_helper.exs` (`ExUnit.start()`) |
| Quick run command | `cd orkestra_mcp && mix test` |
| Full suite command | `cd orkestra_mcp && mix test` |

### Phase Requirements → Test Map
| Req ID | Behavior | Test Type | Automated Command | File Exists? |
|--------|----------|-----------|-------------------|-------------|
| MCP-01 | `gen_projection` tool creates projector file + migration file | unit | `cd orkestra_mcp && mix test test/orkestra_mcp/tools/gen_projection_test.exs` | ❌ Wave 0 |
| MCP-01 | `Generator.gen_projection/3` returns valid Elixir source | unit | `cd orkestra_mcp && mix test test/orkestra_mcp/generator_test.exs` | ✅ (extend) |
| MCP-01 | `Generator.gen_projection_migration/2` returns correct path (priv/projections/...) | unit | `cd orkestra_mcp && mix test test/orkestra_mcp/generator_test.exs` | ✅ (extend) |
| MCP-02 | `gen_read_model` tool creates schema file + migration file | unit | `cd orkestra_mcp && mix test test/orkestra_mcp/tools/gen_read_model_test.exs` | ❌ Wave 0 |
| MCP-02 | `Generator.gen_read_model/2` returns valid Elixir source | unit | `cd orkestra_mcp && mix test test/orkestra_mcp/generator_test.exs` | ✅ (extend) |
| MCP-03 | `Introspection.discover/1` returns `:projectors` key | unit | `cd orkestra_mcp && mix test test/orkestra_mcp/introspection_test.exs` | ✅ (extend) |
| MCP-03 | `ListProjections` resource returns JSON with projector entries | unit | `cd orkestra_mcp && mix test test/orkestra_mcp/introspection_test.exs` | ✅ (extend) |
| MCP-03 | `build_domain_map/1` includes projector lines | unit | `cd orkestra_mcp && mix test test/orkestra_mcp/introspection_test.exs` | ✅ (extend) |
| READ-02 | `gen_queries` tool creates Queries module file | unit | `cd orkestra_mcp && mix test test/orkestra_mcp/tools/gen_queries_test.exs` | ❌ Wave 0 |
| READ-02 | `Generator.gen_queries/2` returns valid Elixir source with `list/1` and `get_by/2` | unit | `cd orkestra_mcp && mix test test/orkestra_mcp/generator_test.exs` | ✅ (extend) |

### Sampling Rate
- **Per task commit:** `cd orkestra_mcp && mix test`
- **Per wave merge:** `cd orkestra_mcp && mix test`
- **Phase gate:** Full suite green (currently 28 tests; Phase 5 adds ~15-20 tests)

### Wave 0 Gaps
- [ ] `test/orkestra_mcp/tools/gen_projection_test.exs` — covers MCP-01 tool execution
- [ ] `test/orkestra_mcp/tools/gen_read_model_test.exs` — covers MCP-02 tool execution
- [ ] `test/orkestra_mcp/tools/gen_queries_test.exs` — covers READ-02 tool execution
- [ ] Fixture file: `test/fixtures/sample_project/lib/my_app/orders/projectors/order_projector.ex` — needed for introspection tests of `detect_projectors`

---

## Security Domain

### Applicable ASVS Categories (Level 1)

| ASVS Category | Applies | Standard Control |
|---------------|---------|-----------------|
| V2 Authentication | No | MCP is local stdio — no auth surface |
| V3 Session Management | No | Stateless tool/resource invocations |
| V4 Access Control | No | Project dir is configured by the operator at startup |
| V5 Input Validation | Yes | Hermes.Server.Component schema macro + Peri validates all tool inputs before `execute/2` is called |
| V6 Cryptography | No | No credentials or secrets generated |

### Known Threat Patterns

| Pattern | STRIDE | Standard Mitigation |
|---------|--------|---------------------|
| Path traversal via `module_name` parameter (e.g., `"../../etc/passwd"`) | Tampering | `Naming.module_to_file_path/1` passes input through `Macro.underscore/1` which collapses non-alphanumeric chars; `Generator.write!` calls `File.mkdir_p!` + `File.write!` inside `project_dir` join — stays within the configured root [VERIFIED: generator.ex] |
| Arbitrary Elixir injection via scaffold templates | Tampering | Generated code contains user-supplied module names as strings; `Code.string_to_quoted/1` test validation detects syntactically malformed output; MCP server only runs locally, not exposed over network |

---

## Sources

### Primary (HIGH confidence)
- `/data/progetti/orkestra/orkestra_mcp/lib/orkestra_mcp/generator.ex` — all five existing generator function signatures and patterns
- `/data/progetti/orkestra/orkestra_mcp/lib/orkestra_mcp/introspection.ex` — all five existing detect_* function patterns
- `/data/progetti/orkestra/orkestra_mcp/lib/orkestra_mcp/server.ex` — component registration pattern
- `/data/progetti/orkestra/orkestra_mcp/lib/orkestra_mcp/tools/gen_aggregate.ex` — canonical tool module template
- `/data/progetti/orkestra/orkestra_mcp/lib/orkestra_mcp/resources/list_aggregates.ex` — canonical resource module template
- `/data/progetti/orkestra/orkestra_mcp/deps/hermes_mcp/lib/hermes/server/component.ex` — Hermes.Server.Component macro API (field/3, schema/1, execute/2 signature)
- `/data/progetti/orkestra/orkestra_mcp/deps/hermes_mcp/lib/hermes/server/component/schema.ex` — supported field types (:string, :integer, :float, :boolean, :any, :list, :enum, {:required, type})
- `/data/progetti/orkestra/lib/orkestra/projector.ex` — `use Orkestra.Projector` DSL, slug derivation, migrations_path formula

### Secondary (MEDIUM confidence)
- `orkestra_mcp/test/` — all existing test files, establishing `async: false` + tmp_dir pattern; `Code.string_to_quoted` validation pattern

### Tertiary (LOW confidence)
- `Naming.module_to_table_name/1` — does not currently exist; proposed shape [ASSUMED]

---

## Metadata

**Confidence breakdown:**
- Standard stack: HIGH — all deps already in mix.lock; no new additions
- Architecture: HIGH — all patterns directly observed in existing codebase, no speculation
- Pitfalls: HIGH — derived from explicit codebase evidence (existing code, requirements text)
- Generated code shapes: MEDIUM — code examples are derived from existing patterns; exact signatures may be adjusted during planning

**Research date:** 2026-06-24
**Valid until:** Stable — orkestra_mcp codebase is under active development but patterns are established; valid for 90 days or until hermes_mcp major version bump
