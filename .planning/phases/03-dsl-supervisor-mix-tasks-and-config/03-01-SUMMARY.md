---
phase: 03-dsl-supervisor-mix-tasks-and-config
plan: "01"
subsystem: projector-dsl
tags:
  - dsl
  - macro
  - supervisor
  - otp
  - projector
dependency_graph:
  requires:
    - "02-03: Orkestra.Projector.GenServer (start_link/1 contract)"
    - "02-02: Orkestra.Projection.Storage.Postgres (write/4 contract)"
    - "02-01: Orkestra.Projection.Checkpoint, DeadLetter schemas"
  provides:
    - "Orkestra.Projector DSL macro (use Orkestra.Projector)"
    - "Orkestra.Projection.Supervisor (one_for_one OTP supervisor)"
    - "project/2 macro for event handler registration"
    - "__projection_config__/0 for mix task discovery"
    - "child_spec/1 for supervision tree integration"
  affects:
    - "03-02: mix tasks use __projection_config__/0 for Repo/path discovery"
    - "03-03: config cleanup — per-projection Repo story documented"
tech_stack:
  added: []
  patterns:
    - "Elixir macro DSL with Module.register_attribute + @before_compile"
    - "Macro.escape to store handler_fn AST in module attributes"
    - "Multi-clause __dispatch__/3 routing by event type string"
    - "__handle__/3 bridge translates :skip to {:ok, Ecto.Multi.new()}"
    - "one_for_one Supervisor wrapping projector modules"
key_files:
  created:
    - path: lib/orkestra/projector.ex
      role: "DSL macro — use Orkestra.Projector, project/2, __before_compile__"
    - path: lib/orkestra/projection/supervisor.ex
      role: "OTP Supervisor — one_for_one, bare module + {module, opts} tuple forms"
    - path: test/orkestra/projector/projector_dsl_test.exs
      role: "Unit tests for DSL macro expansion (async: true, no DB)"
    - path: test/orkestra/projection/supervisor_test.exs
      role: "OTP supervisor isolation tests (async: false)"
  modified: []
decisions:
  - "Macro.escape(handler_fn) in project/2 stores handler AST in module attribute rather than evaluated anonymous function — required because module attributes evaluate expressions at compile time"
  - "__handle__/3 bridges the adapter (projector_name, event, position) signature to __dispatch__(event.type, event, position), translating :skip to {:ok, Ecto.Multi.new()}"
  - "Supervisor name defaults to __MODULE__ but is configurable via :name opt to enable multiple supervisors in test"
  - "Fake projectors in supervisor tests use Agent child specs — avoids DB dependency while testing OTP lifecycle"
metrics:
  duration_seconds: 384
  completed_date: "2026-06-24"
  tasks_completed: 3
  files_created: 4
  files_modified: 0
---

# Phase 03 Plan 01: Projector DSL Macro and Projection Supervisor Summary

**One-liner:** DSL macro `use Orkestra.Projector` with `project/2` and `@before_compile` generating `__dispatch__/3`, `__handle__/3`, `__projection_config__/0`, and `child_spec/1`; plus a one_for_one `Orkestra.Projection.Supervisor`.

## Tasks Completed

| Task | Name | Commit | Files |
|------|------|--------|-------|
| 1 | Implement Orkestra.Projector DSL macro | c101fa7 | lib/orkestra/projector.ex |
| 2 | Implement Orkestra.Projection.Supervisor | ca6a5ad | lib/orkestra/projection/supervisor.ex |
| 3 | Unit tests for DSL macro and Supervisor | fa08d0c, 19ddbdf | test/orkestra/projector/projector_dsl_test.exs, test/orkestra/projection/supervisor_test.exs |

## What Was Built

### `lib/orkestra/projector.ex`

The `Orkestra.Projector` DSL module provides:

- `defmacro __using__(opts)` — extracts `repo` (required), `event_store`, `name`, `max_retries`, `backoff_base_ms`, `backoff_cap_ms`; registers `@projection_handlers` accumulating attribute; sets lifecycle config; imports `project/2`; sets `@before_compile`.
- `defmacro project(event_module, handler_fn)` — accumulates `{event_module_atom, escaped_handler_ast}` pairs in `@projection_handlers`.
- `defmacro __before_compile__(env)` — generates:
  - `__dispatch__/3` with one multi-clause per registered event type (matches on `event.type` string) plus a catch-all returning `:skip`
  - `__handle__/3` bridging adapter signature to `__dispatch__`, translating `:skip` to `{:ok, Ecto.Multi.new()}`
  - `__projection_config__/0` returning `%{repo, projector_name, migrations_path, migration_source}`
  - `child_spec/1` targeting `Orkestra.Projector.GenServer.start_link/1` with runtime override support

### `lib/orkestra/projection/supervisor.ex`

`Orkestra.Projection.Supervisor` is a standard `use Supervisor` module:
- `start_link/1` requires `:projectors` key; accepts optional `:name`
- `init/1` maps bare modules via `module.child_spec([])` and `{module, opts}` tuples via `module.child_spec(opts)` to a one_for_one children list

### Tests

19 tests all pass (`--exclude postgres`, no DB required):
- `projector_dsl_test.exs` (15 tests, `async: true`): covers `__projection_config__/0`, `__dispatch__/3`, `__handle__/3`, `child_spec/1`
- `supervisor_test.exs` (4 tests, `async: false`): covers startup, one_for_one isolation, tuple override form, missing `:projectors` key error

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 1 - Bug] Fixed handler_fn Macro.escape in project/2 macro**
- **Found during:** Task 3 (test run)
- **Issue:** `project/2` macro stored `handler_fn` as evaluated anonymous function in module attribute (because Elixir evaluates module attribute expressions). When `__before_compile__` tried to inject the fn into a `quote` block, it got `#Function<...>` which is not a valid AST node, causing "invalid quoted expression" compilation error.
- **Fix:** Added `escaped = Macro.escape(handler_fn)` in `project/2` before storing in attribute. This stores the original AST tuple (not the evaluated fn) in the attribute, which `__before_compile__` can then safely inject into generated `def __dispatch__` bodies.
- **Files modified:** `lib/orkestra/projector.ex`
- **Commit:** fa08d0c

**2. [Rule 1 - Style] Fixed formatter — parentheses around project/2 calls in tests**
- **Found during:** Task 3 post-commit format check
- **Issue:** Elixir formatter requires parentheses when a multi-line anonymous function is passed as last argument to a macro call.
- **Fix:** Changed `project EventModule, fn ... end` to `project(EventModule, fn ... end)` in test file.
- **Files modified:** `test/orkestra/projector/projector_dsl_test.exs`
- **Commit:** 19ddbdf

## Known Stubs

None — all generated functions are fully wired. `__projection_config__/0` returns real compile-time values; `child_spec/1` builds a real config map; `__dispatch__/3` routes to real handler fns.

## Threat Flags

No new security-relevant surface introduced beyond the plan's threat model (T-03-01, T-03-02, T-03-03). The `one_for_one` strategy satisfying T-03-03 is implemented in `Orkestra.Projection.Supervisor`.

## Self-Check: PASSED
