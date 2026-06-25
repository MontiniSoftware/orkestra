---
phase: 11
plan: 01
subsystem: orkestra_mcp
tags: [mcp, generator, elasticsearch, projector, code-generation]
dependency_graph:
  requires: []
  provides: [gen_es_projection/5, GenEsProjection-tool]
  affects: [orkestra_mcp/generator.ex, orkestra_mcp/server.ex]
tech_stack:
  added: []
  patterns: [TDD-red-green, hermes-server-component, gen-function-pattern]
key_files:
  created:
    - orkestra_mcp/lib/orkestra_mcp/tools/gen_es_projection.ex
    - orkestra_mcp/test/orkestra_mcp/tools/gen_es_projection_test.exs
  modified:
    - orkestra_mcp/lib/orkestra_mcp/generator.ex
    - orkestra_mcp/lib/orkestra_mcp/server.ex
    - orkestra_mcp/test/orkestra_mcp/generator_test.exs
decisions:
  - "gen_es_projection/5 follows the identical pattern of gen_projection/3: pure function returning {source, file_path}"
  - "Empty events list produces a placeholder project_es clause with TODO comment for discoverability"
  - "index_mapping/0 scaffold always includes @impl true and TODO comments for field definitions"
metrics:
  duration: "~15 minutes"
  completed: "2026-06-25"
  tasks: 2
  files: 5
---

# Phase 11 Plan 01: MCP Generator - gen_es_projection Tool Summary

**One-liner:** ES projector scaffolding via MCP — `gen_es_projection/5` generates complete `use Orkestra.Projector, backend: :elasticsearch` modules with `project_es/2` clauses and `index_mapping/0` callback via TDD cycle.

## What Was Built

This plan added the `gen_es_projection` MCP tool that enables an AI client to scaffold a complete Elasticsearch projector module from the Orkestra MCP server. The tool follows the same pattern as the existing `gen_projection` (Postgres) tool.

### Generator Function (`Generator.gen_es_projection/5`)

Added to `orkestra_mcp/lib/orkestra_mcp/generator.ex`:

- Signature: `gen_es_projection(module_name, repo_module, cluster_module, index, events)`
- Generates a complete module with `use Orkestra.Projector, backend: :elasticsearch`
- One `project_es EventModule, fn _event, _position -> ... end` clause per event
- Placeholder clause with TODO when events list is empty
- Always includes `@impl true` before `def index_mapping do` with a scaffold and TODO
- Returns `{String.trim(source), Naming.module_to_file_path(module_name)}`

### MCP Tool (`OrkestraMcp.Tools.GenEsProjection`)

Created `orkestra_mcp/lib/orkestra_mcp/tools/gen_es_projection.ex`:

- `use Hermes.Server.Component, type: :tool`
- Schema with 5 required fields: `module_name`, `repo_module`, `cluster_module`, `index`, `events` (JSON array string)
- `execute/2` decodes events JSON via `Jason.decode!/1`, calls generator, writes file, returns `{:ok, content}`

### Server Registration

Added `component(OrkestraMcp.Tools.GenEsProjection)` to `server.ex` after `GenProjection`.

## Task Execution

| Task | Name | Commit | Files |
|------|------|--------|-------|
| 1 | Add gen_es_projection/5 to Generator with TDD tests | d79e749 | generator.ex, generator_test.exs |
| 2 | Create GenEsProjection tool and register in Server | dda6fba | gen_es_projection.ex, server.ex, gen_es_projection_test.exs |

**Note:** Task 2 was committed as part of commit `dda6fba` (test-11-02) which also included Phase 11-02 introspection work. All files for Task 2 were committed and verified.

## Test Results

- 4 new tests added to `generator_test.exs` (describe "gen_es_projection/5")
- 3 new tests added to `gen_es_projection_test.exs`
- Full suite: **53 tests, 0 failures** (baseline was 44; net addition is 9 new tests for both plans 11-01 and 11-02)
- TDD cycle respected: RED (4 failures) → GREEN (23/23 generator tests pass) → commit

## Deviations from Plan

### None for Task 1

Plan executed exactly as written for the TDD generator task.

### Task 2 Pre-committed

**Context:** Task 2 files (`gen_es_projection.ex`, server registration, `gen_es_projection_test.exs`) were found already committed in `dda6fba` as part of Phase 11-02 work that ran concurrently. No rework needed — all must-haves verified present and functional.

## Known Stubs

The generated template includes intentional TODO stubs — these are features of the generated code, not implementation stubs in the tool itself:

- `project_es EventModule, fn _event, _position -> ... end` — placeholder projection logic (developer fills in)
- `index_mapping/0` scaffold with commented field examples — developer adds real mappings

These are by design: the tool generates scaffolding, not final implementation.

## Threat Flags

None. The tool follows the same trust model as all existing generators (T-11-01 and T-11-02 accepted in threat model — local AI client, same trust domain as developer).

## Self-Check: PASSED

Files exist:
- `/data/progetti/orkestra/orkestra_mcp/lib/orkestra_mcp/tools/gen_es_projection.ex` - FOUND
- `/data/progetti/orkestra/orkestra_mcp/test/orkestra_mcp/tools/gen_es_projection_test.exs` - FOUND

Commits exist:
- `d79e749` (feat 11-01 generator) - FOUND in git log
- `dda6fba` (task 2 - gen_es_projection.ex + server.ex + tests) - FOUND in git log

All 53 tests pass, 0 failures.
