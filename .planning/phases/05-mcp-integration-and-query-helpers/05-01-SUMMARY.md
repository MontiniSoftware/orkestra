---
phase: 05-mcp-integration-and-query-helpers
plan: "01"
subsystem: orkestra_mcp
tags: [mcp, generators, projections, read-models, ecto, naming]
dependency_graph:
  requires: []
  provides:
    - OrkestraMcp.Generator.gen_projection/3
    - OrkestraMcp.Generator.gen_projection_migration/2
    - OrkestraMcp.Generator.gen_read_model/2
    - OrkestraMcp.Generator.gen_read_model_migration/2
    - OrkestraMcp.Generator.gen_queries/2
    - OrkestraMcp.Naming.module_to_table_name/1
  affects:
    - orkestra_mcp/lib/orkestra_mcp/generator.ex
    - orkestra_mcp/lib/orkestra_mcp/naming.ex
    - orkestra_mcp/test/orkestra_mcp/generator_test.exs
tech_stack:
  added: []
  patterns:
    - Pure text-generation functions returning {source_string, file_path} tuples
    - priv/projections/<slug>/migrations/ path isolation per projector/schema
    - Ecto.Query import pattern for generated query modules
key_files:
  created: []
  modified:
    - orkestra_mcp/lib/orkestra_mcp/generator.ex
    - orkestra_mcp/lib/orkestra_mcp/naming.ex
    - orkestra_mcp/test/orkestra_mcp/generator_test.exs
decisions:
  - "Migration paths under priv/projections/<slug>/migrations/ to isolate per-projection migrations from the host app"
  - "gen_projection uses fn _event, multi -> multi end skeleton (consistent with Projector DSL)"
  - "gen_read_model_migration uses change/0 (idempotent via create); gen_projection_migration uses up/down (explicit) since it is more of a scaffold stub"
  - "Empty events list in gen_projection generates a TODO placeholder clause rather than an empty module body"
metrics:
  duration: "2m"
  completed: "2026-06-24T18:58:48Z"
  tasks_completed: 2
  files_modified: 3
---

# Phase 05 Plan 01: MCP Projection Generator Functions Summary

Five new pure generator functions and one naming helper added to `orkestra_mcp`, providing all scaffold text generation for projectors, read models, migrations, and query modules.

## Tasks Completed

| # | Task | Commit | Files |
|---|------|--------|-------|
| 1 | Add module_to_table_name/1 and five generator functions | 1359537 | naming.ex, generator.ex |
| 2 | Add unit tests for all new functions | 419a6e2 | generator_test.exs |

## What Was Built

### OrkestraMcp.Naming

**`module_to_table_name/1`** — Converts a fully-qualified module name to a pluralised snake_case table name by taking the last segment, underscoring it, and appending `"s"`. Example: `"MyApp.Orders.OrderReadModel"` → `"order_read_models"`.

### OrkestraMcp.Generator

**`gen_projection/3`** `(module_name, repo_module, events)` — Generates a projector module using `use Orkestra.Projector` with `project EventModule, fn _event, multi -> ... end` clauses for each event. Falls back to a TODO placeholder clause when the events list is empty. Returns `{String.trim(source), Naming.module_to_file_path(module_name)}`.

**`gen_projection_migration/2`** `(projector_module_name, timestamp \\ nil)` — Generates a migration stub with `up/down` functions. File path: `priv/projections/<slug>/migrations/<ts>_create_<slug>_read_model.exs` — fully isolated from the host application's own migrations directory. The slug is derived by underscoring each module name segment and joining with `_`.

**`gen_read_model/2`** `(module_name, fields)` — Generates an Ecto schema module with `@primary_key {:id, :binary_id, autogenerate: true}`, `@timestamps_opts [type: :utc_datetime_usec]`, a `schema` block using `Naming.module_to_table_name/1`, and `field :name, :type` lines. Returns the `{source, file_path}` tuple.

**`gen_read_model_migration/2`** `(schema_module_name, timestamp \\ nil)` — Generates a `change/0`-based migration with `create table(:table_name, primary_key: false)`, `:binary_id` primary key, and a `timestamps(type: :utc_datetime_usec)` call. File path isolated under `priv/projections/<slug>/migrations/`.

**`gen_queries/2`** `(module_name, schema_module)` — Generates a query helper module with `import Ecto.Query`, aliased schema, paged `list/2` (`:page`, `:page_size` options, offset arithmetic), and filter-based `get_by/2`. Includes `@moduledoc` and `@doc` annotations per CLAUDE.md documentation requirement.

### Private helper

**`format_schema_field/1`** — Formats a `%{"name" => _, "type" => _}` map as `"    field :name, :type"` (4-space indent matching Ecto schema convention).

## Test Coverage

17 total tests, 0 failures (10 new + 7 pre-existing).

New describe blocks:
- `gen_projection/3` — 2 tests (with events, empty events)
- `gen_projection_migration/2` — 1 test (path prefix, slug, migration content)
- `gen_read_model/2` — 1 test (schema, table name, fields, timestamps)
- `gen_read_model_migration/2` — 1 test (migration structure, binary_id)
- `gen_queries/2` — 1 test (imports, list, get_by, pagination vars)
- `module_to_table_name/1` — 2 tests (multi-segment, single-segment)

Every test includes a `Code.string_to_quoted/1` parsability assertion.

## Deviations from Plan

None — plan executed exactly as written.

## Threat Surface Scan

No new network endpoints, auth paths, or trust boundary changes. Generator functions are pure text transformations; the MCP server remains local stdio only. Consistent with accepted T-05-01 and T-05-02 dispositions in the plan's threat model.

## Self-Check: PASSED

- `orkestra_mcp/lib/orkestra_mcp/generator.ex` — exists and compiles
- `orkestra_mcp/lib/orkestra_mcp/naming.ex` — exists and compiles
- `orkestra_mcp/test/orkestra_mcp/generator_test.exs` — exists and all 17 tests pass
- Commit 1359537 — feat(05-01): add five projection generator functions and module_to_table_name helper
- Commit 419a6e2 — test(05-01): add unit tests for projection generator functions and naming helper
