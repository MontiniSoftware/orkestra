---
phase: 05-mcp-integration-and-query-helpers
plan: "03"
subsystem: orkestra_mcp
tags: [mcp, introspection, projections, resources, server-registration]
dependency_graph:
  requires:
    - OrkestraMcp.Generator.gen_projection/3
    - OrkestraMcp.Generator.gen_read_model/2
    - OrkestraMcp.Generator.gen_queries/2
    - OrkestraMcp.Introspection.discover/1 (extended)
  provides:
    - OrkestraMcp.Introspection.detect_projectors/2
    - OrkestraMcp.Introspection.extract_projected_events/1
    - OrkestraMcp.Resources.ListProjections
    - OrkestraMcp.Tools.GenProjection
    - OrkestraMcp.Tools.GenReadModel
    - OrkestraMcp.Tools.GenQueries
  affects:
    - orkestra_mcp/lib/orkestra_mcp/introspection.ex
    - orkestra_mcp/lib/orkestra_mcp/resources/list_projections.ex
    - orkestra_mcp/lib/orkestra_mcp/server.ex
    - orkestra_mcp/test/fixtures/sample_project/lib/my_app/orders/projectors/order_projector.ex
    - orkestra_mcp/test/orkestra_mcp/introspection_test.exs
tech_stack:
  added: []
  patterns:
    - Regex.run detection pattern for use Orkestra.Projector,repo: match without false positives
    - Regex.scan for extracting project/2 event module names from file content
    - Hermes.Server.Component resource pattern with Application.get_env(:orkestra_mcp, :project_dir)
key_files:
  created:
    - orkestra_mcp/lib/orkestra_mcp/resources/list_projections.ex
    - orkestra_mcp/lib/orkestra_mcp/tools/gen_projection.ex
    - orkestra_mcp/lib/orkestra_mcp/tools/gen_read_model.ex
    - orkestra_mcp/lib/orkestra_mcp/tools/gen_queries.ex
    - orkestra_mcp/test/fixtures/sample_project/lib/my_app/orders/projectors/order_projector.ex
  modified:
    - orkestra_mcp/lib/orkestra_mcp/introspection.ex
    - orkestra_mcp/lib/orkestra_mcp/server.ex
    - orkestra_mcp/test/orkestra_mcp/introspection_test.exs
decisions:
  - "Tool modules (gen_projection, gen_read_model, gen_queries) included in this worktree to allow compile verification; these are exact copies of plan 02 outputs to avoid merge conflicts on identical content"
  - "detect_projectors regex uses use\\s+Orkestra\\.Projector,\\s*repo: prefix to avoid false positives from Orkestra.Projector.GenServer references"
  - "extract_projected_events uses Regex.scan to extract all project/2 event module names"
  - "build_domain_map projectors section uses flat_map with (projector) header and (projected_event) sub-lines following existing command/event pattern"
metrics:
  duration: "7m"
  completed: "2026-06-24T19:05:34Z"
  tasks_completed: 2
  files_modified: 8
---

# Phase 05 Plan 03: Introspection Projector Discovery and Server Registration Summary

Extended `Introspection.discover/1` to detect projectors via regex scanning, added `ListProjections` resource, created three MCP tool modules, and wired all four new components into the Server registration.

## Tasks Completed

| # | Task | Commit | Files |
|---|------|--------|-------|
| 1 | Create fixture file and extend Introspection with detect_projectors | 3c57628 | introspection.ex, order_projector.ex (fixture) |
| 2 | Create ListProjections resource, register all components in Server, add tests | 36cda10 | list_projections.ex, server.ex, introspection_test.exs, gen_projection.ex, gen_read_model.ex, gen_queries.ex |

## What Was Built

### OrkestraMcp.Introspection (extended)

**`detect_projectors/2`** — Private function added to the `parse_file/2` pipeline. Uses `Regex.run(~r/use\s+Orkestra\.Projector,\s*repo:\s*([\w.]+)/, content)` to match projector modules and extract the repo module name. The regex requires the `, repo:` suffix, preventing false positives from `Orkestra.Projector.GenServer` or other submodule references.

**`extract_projected_events/1`** — Private helper that uses `Regex.scan(~r/project\s+([\w.]+),/, content)` to extract all event module names from `project EventModule, fn ... end` clauses.

**`discover/1` (updated)** — Initial accumulator now includes `:projectors: []`. Returns a map with six keys: `:commands`, `:events`, `:command_handlers`, `:event_handlers`, `:aggregates`, `:projectors`. Each projector entry has `:module`, `:repo`, and `:events` keys.

**`build_domain_map/1` (updated)** — Destructuring pattern match includes `:projectors`. Appends projector lines after aggregates: `"ModuleName (projector)"` header with `"  -> EventModule (projected_event)"` sub-lines, following the same flat_map pattern used for commands and events.

### OrkestraMcp.Resources.ListProjections

New resource at `orkestra://projections` with `mime_type: "application/json"`. Calls `Introspection.discover/1` with the configured project directory and returns JSON-encoded projector list via `Jason.encode!(projectors, pretty: true)`.

### Server Registration

Four new `component/1` lines added to `server.ex`:
- `OrkestraMcp.Tools.GenProjection` — scaffolds projector module + migration
- `OrkestraMcp.Tools.GenReadModel` — scaffolds Ecto schema + migration
- `OrkestraMcp.Tools.GenQueries` — scaffolds query helper module
- `OrkestraMcp.Resources.ListProjections` — lists all detected projectors

### MCP Tool Modules

Three tool modules created with `use Hermes.Server.Component, type: :tool`:
- **GenProjection** — accepts `module_name`, `repo_module`, `events` (JSON array); generates projector + migration via Generator
- **GenReadModel** — accepts `module_name`, `fields` (JSON array); generates schema + migration via Generator
- **GenQueries** — accepts `module_name`, `schema_module`; generates query module via Generator

### Test Fixture

`order_projector.ex` fixture added to `sample_project/lib/my_app/orders/projectors/` with two `project/2` clauses for `OrderPlaced` and `OrderCancelled` events.

## Test Coverage

38 total tests, 0 failures across full suite.

New tests added to `introspection_test.exs`:
- `discovers projectors` — verifies module name, repo, and both event names extracted correctly
- `includes projectors in domain map` — verifies `(projector)` label and `(projected_event)` sub-lines appear
- Updated `returns empty lists` — now also asserts `result.projectors == []`

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 3 - Blocking] Tool modules missing from worktree caused compile failure**
- **Found during:** Task 2 — adding `component(OrkestraMcp.Tools.GenProjection)` etc. to server.ex
- **Issue:** Plan 02 (parallel wave 2 worktree `agent-ad6b7136`) creates the tool modules, but they are absent from this worktree, causing `UndefinedFunctionError` at compile time
- **Fix:** Created `gen_projection.ex`, `gen_read_model.ex`, `gen_queries.ex` in this worktree with exact content matching plan 02's implementations (read from the parallel worktree)
- **Files modified:** `orkestra_mcp/lib/orkestra_mcp/tools/gen_projection.ex`, `gen_read_model.ex`, `gen_queries.ex`
- **Commit:** 36cda10

## Known Stubs

None — all data flows from `Introspection.discover/1` which reads live project files.

## Threat Surface Scan

No new network endpoints or auth paths introduced. `ListProjections` resource has the same local stdio trust profile as existing `ListAggregates` (T-05-05 accepted disposition). The `detect_projectors` regex uses the `use Orkestra.Projector, repo:` prefix guard per T-05-06 accepted disposition.

## Self-Check: PASSED

- `orkestra_mcp/lib/orkestra_mcp/introspection.ex` — exists, compiles, detect_projectors/2 and extract_projected_events/1 added
- `orkestra_mcp/lib/orkestra_mcp/resources/list_projections.ex` — exists, compiles
- `orkestra_mcp/lib/orkestra_mcp/server.ex` — exists, registers 4 new components
- `orkestra_mcp/lib/orkestra_mcp/tools/gen_projection.ex` — exists, compiles
- `orkestra_mcp/lib/orkestra_mcp/tools/gen_read_model.ex` — exists, compiles
- `orkestra_mcp/lib/orkestra_mcp/tools/gen_queries.ex` — exists, compiles
- `orkestra_mcp/test/fixtures/sample_project/lib/my_app/orders/projectors/order_projector.ex` — exists
- `orkestra_mcp/test/orkestra_mcp/introspection_test.exs` — 11 tests, all passing
- Commit 3c57628 — feat(05-03): extend Introspection with detect_projectors and fixture file
- Commit 36cda10 — feat(05-03): add ListProjections resource, tool modules, and introspection tests
- Full suite: 38 tests, 0 failures
