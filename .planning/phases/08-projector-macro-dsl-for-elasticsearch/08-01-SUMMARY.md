---
phase: 08-projector-macro-dsl-for-elasticsearch
plan: "01"
subsystem: projector-dsl
tags:
  - projector
  - macro-dsl
  - elasticsearch
  - backward-compatibility
dependency_graph:
  requires:
    - 07-01 (GenServer ES commit path — apply_es_event, flush_es_buffer, commit_es_checkpoint)
    - 06-01 (Storage.Elasticsearch.init/1 contract — engine detection, index creation)
  provides:
    - project_es/2 macro for ES-backed projectors
    - __dispatch_es__/3, __handle_es__/3 generated bridge functions
    - child_spec/1 ES branch wiring Storage.Elasticsearch
    - handle_info(:init_adapter) in GenServer for adapter startup
  affects:
    - lib/orkestra/projector.ex
    - lib/orkestra/projector/gen_server.ex
tech_stack:
  added: []
  patterns:
    - Module.register_attribute accumulate: true for @es_projection_handlers
    - Macro.escape/1 for handler_fn AST injection (T-08-01 tamper mitigation)
    - Conditional bridge-function generation to avoid Elixir 1.18 dead-code type warnings
    - Deferred init via send(self(), :init_adapter) preserving Sandbox.allow window
key_files:
  created:
    - test/orkestra/projector/projector_dsl_es_test.exs
  modified:
    - lib/orkestra/projector.ex
    - lib/orkestra/projector/gen_server.ex
decisions:
  - Lean bridge functions: __handle__/3 and __handle_es__/3 generated conditionally by backend to avoid Elixir 1.18+ dead-code type checker warnings on unreachable case clauses
  - :init_adapter message sent before :load_checkpoint when storage_adapter exports init/1; Postgres adapter (no init/1) continues unchanged
  - engine atom from Storage.Elasticsearch.init/1 written back into adapter_opts so OTel spans in commit_es_single_doc and flush_es_buffer use the detected engine
  - CompileError raised if backend :elasticsearch missing :cluster/:index, or if both project/2 and project_es/2 used in same module (T-08-05)
metrics:
  duration_seconds: 350
  completed: 2026-06-25
  tasks_completed: 2
  tasks_total: 2
  files_created: 1
  files_modified: 2
---

# Phase 08 Plan 01: Projector Macro DSL for Elasticsearch Summary

**One-liner:** ES projector DSL via `project_es/2` macro with `backend: :elasticsearch` option, lean bridge functions to avoid Elixir 1.18 type warnings, and deferred `storage_adapter.init/1` via `:init_adapter` GenServer message.

## What Was Built

Extended `Orkestra.Projector` with first-class Elasticsearch backend support. A developer can now define an ES projector using the same macro DSL pattern as Postgres projectors:

```elixir
defmodule MyApp.OrderESProjector do
  use Orkestra.Projector,
    backend: :elasticsearch,
    repo: MyApp.CheckpointRepo,
    cluster: MyApp.ESCluster,
    index: "orders",
    event_store: Orkestra.EventStore.InMemory

  def index_mapping do
    %{"mappings" => %{"properties" => %{"order_id" => %{"type" => "keyword"}}}}
  end

  project_es MyApp.Events.OrderPlaced, fn event, _position ->
    {:ok, %{"order_id" => event.data.order_id}, event.data.order_id}
  end
end
```

The generated `child_spec/1` automatically wires `storage_adapter: Storage.Elasticsearch` and `adapter_opts` with `:cluster`, `:index`, `:handler`, and `:projector_module`. The GenServer sends `:init_adapter` at startup to trigger engine detection and index creation before processing events.

## Tasks Completed

| Task | Name | Commit | Files |
|------|------|--------|-------|
| 1 | Extend Projector macro with ES backend and add GenServer :init_adapter | 5863b39 | lib/orkestra/projector.ex, lib/orkestra/projector/gen_server.ex |
| 2 | Create ES DSL tests and verify backward compatibility | 8620baa | test/orkestra/projector/projector_dsl_es_test.exs, lib/orkestra/projector.ex |

## Verification Results

1. `mix compile --warnings-as-errors` — PASS (0 warnings)
2. `mix test test/orkestra/projector/projector_dsl_es_test.exs --include elasticsearch` — 16 tests, 0 failures
3. `mix test test/orkestra/projector/projector_dsl_test.exs` — 15 tests, 0 failures (no regressions)
4. `grep -c "project_es" lib/orkestra/projector.ex` — 7 (defmacro + doc + import + uses)
5. `grep -c "init_adapter" lib/orkestra/projector/gen_server.ex` — 3 (send + handle_info header)
6. `grep -c "Storage.Elasticsearch" lib/orkestra/projector.ex` — 4 (child_spec branch + doc)
7. `grep -c "projector_module" lib/orkestra/projector.ex` — 2 (adapter_opts + doc)

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 1 - Bug / Elixir 1.18 type warnings] Lean bridge function generation**

- **Found during:** Task 2 (first test run)
- **Issue:** The generated `__handle__/3` and `__handle_es__/3` bridge functions contained case clauses that Elixir 1.18+ type checker correctly identified as unreachable dead-code. For an ES projector with zero Postgres handlers, `__dispatch__/3` always returns `:skip`, making `{:ok, multi}` and `{:error, reason}` clauses unreachable. Symmetrically, for a Postgres projector with zero ES handlers, `__dispatch_es__/3` always returns `:skip`, making `{:ok, doc, id}` and `{:error, reason}` unreachable.
- **Fix:** Generated bridge functions conditionally by backend:
  - ES backend: `__handle__/3` returns `{:ok, Ecto.Multi.new()}` directly (no dispatch delegation)
  - Postgres backend: `__handle_es__/3` returns `:skip` directly (no ES dispatch delegation)
  - The full dispatch-delegating versions are generated only for the active backend
- **Files modified:** lib/orkestra/projector.ex
- **Commit:** 8620baa

**2. [Rule 1 - Bug] Test backward-compat used cross-file module reference**

- **Found during:** Task 2 (test failure)
- **Issue:** The "backward compatibility" describe block referenced `Orkestra.Projector.ProjectorDslTest.TestProjector` which is defined in a different test file and not available when running `projector_dsl_es_test.exs` in isolation.
- **Fix:** Defined an inline `TestPostgresProjectorInES` module in the ES test file to serve as the Postgres backward-compat projector. Tests now self-contained.
- **Files modified:** test/orkestra/projector/projector_dsl_es_test.exs
- **Commit:** 8620baa

**3. [Rule 2 - Missing critical functionality] Removed @impl true from test inline module**

- **Found during:** Task 2 (compiler warning)
- **Issue:** `@impl true` on `index_mapping/0` in the inline `TestESProjector` triggered a warning because no `@behaviour` was declared in that module. (The behaviour is an optional callback pattern, not declared with `@behaviour`.)
- **Fix:** Removed `@impl true` from the test inline module definition. The function works identically without the annotation.
- **Files modified:** test/orkestra/projector/projector_dsl_es_test.exs
- **Commit:** 8620baa

## Decisions Made

| Decision | Rationale |
|----------|-----------|
| Lean bridge functions generated by backend | Avoids Elixir 1.18 dead-code type warnings without suppressing type checking globally |
| `function_exported?/3` check in GenServer.init/1 | Postgres adapter does not export `init/1` (@optional_callbacks); check at runtime guards against init overhead for non-ES adapters |
| engine written back to adapter_opts | commit_es_single_doc and flush_es_buffer read `Keyword.get(adapter_opts, :engine, :elasticsearch)` — writing the detected engine ensures OTel spans use the real engine atom |
| CompileError for mixed backends | Detecting `project/2` + `project_es/2` in same module at compile-time gives a clear error instead of silent runtime confusion |

## Threat Model Verification

| Threat ID | Status |
|-----------|--------|
| T-08-01 (Tampering — project_es/2 macro) | MITIGATED — Macro.escape/1 applied to handler_fn before accumulation |
| T-08-02 (Info Disclosure — init_adapter logging) | MITIGATED — Logger.error logs only projector_name + inspect(reason), never adapter_opts |
| T-08-03 (Tampering — index_mapping/0) | ACCEPTED — already mitigated in Storage.Elasticsearch.ensure_index (Phase 6) |
| T-08-04 (DoS — storage_adapter.init/1 failure) | MITIGATED — {:stop, {:adapter_init_failed, reason}, state} returned on init failure |
| T-08-05 (Tampering — compile-time bypass) | MITIGATED — CompileError raised if backend :elasticsearch missing :cluster/:index, or if both backends mixed |

## Known Stubs

None. All functionality is fully implemented and wired.

## Threat Flags

None. No new network endpoints, auth paths, or schema changes introduced beyond what was planned.

## Self-Check: PASSED

Files created/modified:
- FOUND: /data/progetti/orkestra/lib/orkestra/projector.ex
- FOUND: /data/progetti/orkestra/lib/orkestra/projector/gen_server.ex
- FOUND: /data/progetti/orkestra/test/orkestra/projector/projector_dsl_es_test.exs

Commits verified:
- FOUND: 5863b39 (feat(08-01): extend Projector macro with ES backend and add :init_adapter handler)
- FOUND: 8620baa (feat(08-01): add ES DSL test file and fix lean bridge functions for 1.18 type checker)
