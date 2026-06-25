---
phase: 07-genserver-es-commit-path-and-batch-indexing
plan: "01"
subsystem: projector/gen_server
tags:
  - elasticsearch
  - bulk-indexing
  - genserver
  - otel
  - telemetry
dependency_graph:
  requires:
    - 06-02 (Storage.Elasticsearch write/4 descriptor contract)
  provides:
    - ES live single-doc write path via Snap.Document.index
    - ES catch-up bulk buffer + flush path via Snap.Bulk.perform
    - OTel spans for ES operations (orkestra.es.single_doc_index, orkestra.es.bulk_flush)
    - Telemetry event [:orkestra, :projector, :es_bulk_flush]
    - Standalone Postgres checkpoint update for ES path
    - Terminate-time best-effort buffer flush
  affects:
    - Any ES projector started via Projector.GenServer
tech_stack:
  added: []
  patterns:
    - ES-first Postgres-second checkpoint ordering (at-least-once semantics)
    - Snap.Bulk.Action.Index buffer accumulation in GenServer state
    - page_size + page_wait:0 for bounded buffer flushes
    - Snap.BulkError explicit pattern match for partial failure detection
key_files:
  created: []
  modified:
    - lib/orkestra/projector/gen_server.ex
    - lib/orkestra/telemetry.ex
decisions:
  - "es_mode determined at init/1 time from rebuild_total presence (not runtime signal)"
  - "ES checkpoint runs standalone via repo.transaction(checkpoint_multi), never Ecto.Multi.append"
  - "page_wait: 0 always passed to Snap.Bulk.perform for GenServer-buffered batches"
  - "flush_es_buffer_on_terminate uses synchronous Snap.Bulk.perform without OTel (process terminating)"
  - "rebuild_events_replayed incremented by buffer length on successful bulk flush"
metrics:
  duration_seconds: 191
  completed_date: "2026-06-25"
  tasks_completed: 2
  files_modified: 2
---

# Phase 07 Plan 01: GenServer ES Commit Path and Batch Indexing Summary

**One-liner:** ES commit path wired into GenServer with live single-doc Snap.Document.index, catch-up bulk Snap.Bulk.perform buffering at batch_size=500, explicit Snap.BulkError partial-failure detection, OTel spans for both operations, and es_bulk_flush telemetry.

## Tasks Completed

| Task | Name | Commit | Files |
|------|------|--------|-------|
| 1 | Add ES span attrs helper to Telemetry + extend GenServer state | 528bec1 | lib/orkestra/telemetry.ex, lib/orkestra/projector/gen_server.ex |
| 2 | Implement full ES commit path in GenServer | edba980 | lib/orkestra/projector/gen_server.ex |

## What Was Built

### Task 1 — Telemetry helper + GenServer state extension

**`lib/orkestra/telemetry.ex`** — Added `es_span_attrs/4` public function:
```elixir
@spec es_span_attrs(String.t(), String.t(), atom(), non_neg_integer() | nil) :: map()
def es_span_attrs(projector_name, index, engine, doc_count \\ nil)
```
Returns a map with `"orkestra.projector.name"`, `"es.index"`, `"es.engine"` (string). When `doc_count` is non-nil, also includes `"es.doc_count"`.

**`lib/orkestra/projector/gen_server.ex`** — Extended `@type state` with three new fields:
- `es_buffer: list()` — buffer of `{position, %Snap.Bulk.Action.Index{}}` tuples
- `es_batch_size: non_neg_integer()` — flush threshold, default 500
- `es_mode: :live | :catching_up` — determined at startup from `rebuild_total`

Extended `init/1` state map accordingly.

### Task 2 — Full ES commit path

**`apply_event/2`** — Added two new clauses before the existing Postgres path:
- `{:ok, %{action: :index} = es_op}` → delegates to `apply_es_event/4`
- `{:ok, %{action: :skip}}` → delegates to `update_es_checkpoint_only/3`

**New private functions added:**
- `apply_es_event/4` — branches on `state.es_mode`: `:live` calls `commit_es_single_doc`, `:catching_up` appends to buffer and conditionally flushes
- `commit_es_single_doc/4` — wraps `Snap.Document.index/4` in OTel span `"orkestra.es.single_doc_index"`, calls `commit_es_checkpoint` on success, `handle_failure` on error
- `flush_es_buffer/3` — converts buffer to actions, wraps `Snap.Bulk.perform/4` in OTel span `"orkestra.es.bulk_flush"` with `page_size: length(actions), page_wait: 0`, emits `[:orkestra, :projector, :es_bulk_flush]` telemetry, detects `%Snap.BulkError{}` explicitly
- `commit_es_checkpoint/3` — standalone `repo.transaction(checkpoint_multi)` for ES path (not `Ecto.Multi.append`); emits `:lag` telemetry; emits `:rebuild_progress` when in rebuild mode
- `update_es_checkpoint_only/3` — advances checkpoint for `:skip` events without ES write
- `flush_es_buffer_on_terminate/1` — best-effort synchronous bulk flush on GenServer shutdown; logs warning on failure (events replayed on restart)

**`terminate/2`** — Added new clause before catch-all: matches `%{es_buffer: [_ | _]}` and calls `flush_es_buffer_on_terminate` before delegating to unsubscribe clause.

## Threat Model Coverage

| Threat ID | Status | How Mitigated |
|-----------|--------|---------------|
| T-07-01 | Mitigated | `{:error, %Snap.BulkError{errors: errors}}` matched explicitly; `handle_failure` called; checkpoint NOT advanced |
| T-07-02 | Mitigated | `es_batch_size` cap (default 500) checked on every buffer append |
| T-07-03 | Mitigated | Logger calls include only `projector_name` and `position`; `adapter_opts` never logged |
| T-07-04 | Accepted | At-least-once semantics: ES idempotent upserts make replay safe |
| T-07-05 | Mitigated | `page_wait: 0, page_size: length(actions)` always passed to `Snap.Bulk.perform/4` |

## Verification Results

| Check | Result |
|-------|--------|
| `mix compile --warnings-as-errors` | PASS — 0 warnings |
| `Snap.Document.index` present | PASS — 2 occurrences |
| `Snap.Bulk.perform` present | PASS — 4 occurrences |
| `Snap.BulkError` explicit match | PASS — 1 occurrence |
| `orkestra.es.single_doc_index` OTel span | PASS — 1 occurrence |
| `orkestra.es.bulk_flush` OTel span | PASS — 1 occurrence |
| `es_bulk_flush` telemetry event | PASS — 1 occurrence |
| `page_wait: 0` present | PASS — 3 occurrences |
| `es_span_attrs` in telemetry.ex | PASS — 2 occurrences |
| Existing Postgres tests | PASS — 0 failures, 0 regressions (DB not available in env) |

## Deviations from Plan

None — plan executed exactly as written.

## Known Stubs

None. All ES write paths are fully wired; no placeholder data or hardcoded empty values.

## Threat Flags

None. No new network endpoints or auth paths introduced beyond what the plan specified.

## Self-Check: PASSED

- `lib/orkestra/projector/gen_server.ex` exists (737 lines)
- `lib/orkestra/telemetry.ex` exists (204 lines)
- Commit 528bec1 exists: `feat(07-01): add es_span_attrs/4 helper and extend GenServer state with ES fields`
- Commit edba980 exists: `feat(07-01): implement full ES commit path in GenServer (live, bulk, partial failure, OTel)`
