---
phase: 05-mcp-integration-and-query-helpers
plan: "02"
subsystem: orkestra_mcp
tags: [mcp, tools, projections, read-models, generators, hermes]
dependency_graph:
  requires:
    - OrkestraMcp.Generator.gen_projection/3
    - OrkestraMcp.Generator.gen_projection_migration/2
    - OrkestraMcp.Generator.gen_read_model/2
    - OrkestraMcp.Generator.gen_read_model_migration/2
    - OrkestraMcp.Generator.gen_queries/2
    - OrkestraMcp.Generator.write!/3
  provides:
    - OrkestraMcp.Tools.GenProjection (MCP tool)
    - OrkestraMcp.Tools.GenReadModel (MCP tool)
    - OrkestraMcp.Tools.GenQueries (MCP tool)
  affects:
    - orkestra_mcp/lib/orkestra_mcp/tools/gen_projection.ex
    - orkestra_mcp/lib/orkestra_mcp/tools/gen_read_model.ex
    - orkestra_mcp/lib/orkestra_mcp/tools/gen_queries.ex
    - orkestra_mcp/test/orkestra_mcp/tools/gen_projection_test.exs
    - orkestra_mcp/test/orkestra_mcp/tools/gen_read_model_test.exs
    - orkestra_mcp/test/orkestra_mcp/tools/gen_queries_test.exs
tech_stack:
  added: []
  patterns:
    - Hermes.Server.Component tool pattern with schema/execute/2 callbacks
    - Two-file generation responses (projector + migration, schema + migration)
    - async: false ExUnit tests using Application.put_env for project_dir isolation
key_files:
  created:
    - orkestra_mcp/lib/orkestra_mcp/tools/gen_projection.ex
    - orkestra_mcp/lib/orkestra_mcp/tools/gen_read_model.ex
    - orkestra_mcp/lib/orkestra_mcp/tools/gen_queries.ex
    - orkestra_mcp/test/orkestra_mcp/tools/gen_projection_test.exs
    - orkestra_mcp/test/orkestra_mcp/tools/gen_read_model_test.exs
    - orkestra_mcp/test/orkestra_mcp/tools/gen_queries_test.exs
  modified: []
decisions:
  - "GenProjection and GenReadModel each call write! twice and include both Created paths in the response to satisfy the plan requirement of reporting all generated files"
  - "Migration path is derived from gen_projection_migration/gen_read_model_migration return value (not hardcoded) so timestamp isolation is preserved"
metrics:
  duration: "2m"
  completed: "2026-06-24T19:03:28Z"
  tasks_completed: 2
  files_modified: 6
---

# Phase 05 Plan 02: MCP Tool Modules for Projection Scaffolding Summary

Three Hermes MCP tool modules wiring the Plan 01 generator functions into callable MCP tools: GenProjection writes a projector + migration, GenReadModel writes a schema + migration, GenQueries writes a queries module.

## Tasks Completed

| # | Task | Commit | Files |
|---|------|--------|-------|
| 1 | Create GenProjection, GenReadModel, and GenQueries tool modules | 5a30419 | gen_projection.ex, gen_read_model.ex, gen_queries.ex |
| 2 | Create tool-level tests for all three tools | 62cfe11 | gen_projection_test.exs, gen_read_model_test.exs, gen_queries_test.exs |

## What Was Built

### OrkestraMcp.Tools.GenProjection

Accepts `module_name`, `repo_module`, and `events` (JSON-encoded list). Calls `Generator.gen_projection/3` and `Generator.gen_projection_migration/2`, writes both files via `Generator.write!/3`, and returns a response containing two `Created <path>` lines followed by the projector source as a fenced code block.

### OrkestraMcp.Tools.GenReadModel

Accepts `module_name` and `fields` (JSON-encoded list of `{"name","type"}` maps). Calls `Generator.gen_read_model/2` and `Generator.gen_read_model_migration/2`, writes both files, and returns a response containing two `Created <path>` lines followed by the schema source.

### OrkestraMcp.Tools.GenQueries

Accepts `module_name` and `schema_module`. Calls `Generator.gen_queries/2`, writes one file, and returns `Created <path>` with the queries source. Shortest of the three — queries module has no paired migration artifact.

### Test Coverage

3 new tests, all `async: false` (required for `Application.put_env` isolation):

- **GenProjectionTest**: verifies projector file created at expected path, migration file present under `priv/projections/`, and result contains `"use Orkestra.Projector"`.
- **GenReadModelTest**: verifies schema file created, migration under `priv/projections/`, result contains `"use Ecto.Schema"`.
- **GenQueriesTest**: verifies queries file created, result contains `"import Ecto.Query"`.

Full suite: 39 tests, 0 failures.

## Deviations from Plan

None — plan executed exactly as written.

## Threat Surface Scan

No new network endpoints, auth paths, file access patterns, or schema changes at trust boundaries. All three tools delegate to pure text-generation functions and write to a user-supplied `project_dir`. Consistent with accepted T-05-03 and T-05-04 dispositions (local stdio MCP only; Jason.decode! + Macro.underscore path sanitization).

## Self-Check: PASSED

- `orkestra_mcp/lib/orkestra_mcp/tools/gen_projection.ex` — exists and compiles
- `orkestra_mcp/lib/orkestra_mcp/tools/gen_read_model.ex` — exists and compiles
- `orkestra_mcp/lib/orkestra_mcp/tools/gen_queries.ex` — exists and compiles
- `orkestra_mcp/test/orkestra_mcp/tools/gen_projection_test.exs` — exists, test passes
- `orkestra_mcp/test/orkestra_mcp/tools/gen_read_model_test.exs` — exists, test passes
- `orkestra_mcp/test/orkestra_mcp/tools/gen_queries_test.exs` — exists, test passes
- Commit 5a30419 — feat(05-02): add GenProjection, GenReadModel, and GenQueries MCP tool modules
- Commit 62cfe11 — test(05-02): add tool-level tests for GenProjection, GenReadModel, and GenQueries
