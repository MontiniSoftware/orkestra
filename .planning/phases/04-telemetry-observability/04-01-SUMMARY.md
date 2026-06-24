---
phase: 04-telemetry-observability
plan: "01"
subsystem: projector-observability
tags:
  - opentelemetry
  - telemetry
  - projector
  - gen-server
  - instrumentation
dependency_graph:
  requires:
    - "03-01: Projector GenServer (gen_server.ex)"
    - "01-01: Orkestra.Telemetry module (telemetry.ex)"
  provides:
    - "OTel span wrapping on apply_event (TEL-01)"
    - "Lag metric [:orkestra, :projector, :lag] (TEL-02)"
    - "Rebuild progress metric [:orkestra, :projector, :rebuild_progress] (TEL-03)"
    - "Retry + halt metrics [:orkestra, :projector, :retry/:halted] (TEL-04)"
  affects:
    - "lib/orkestra/telemetry.ex"
    - "lib/orkestra/projector/gen_server.ex"
tech_stack:
  added: []
  patterns:
    - "Tracer.with_span wrapping in GenServer private function (same pattern as aggregate/root.ex)"
    - ":telemetry.execute/3 at four lifecycle sites"
    - "Tracer.add_event for structured halt event in OTel span"
    - "State field tracking (last_seen_position, rebuild_total, rebuild_events_replayed)"
key_files:
  created: []
  modified:
    - "lib/orkestra/telemetry.ex"
    - "lib/orkestra/projector/gen_server.ex"
decisions:
  - "projector_span_attrs/3 takes plain values (not EventEnvelope structs) because GenServer handles raw event maps from EventStore"
  - "event[:id] uses bracket access instead of dot access because :id may not be present on all raw event maps"
  - "Lag metric uses (state.last_seen_position || position) - position so a projector processing its first event has lag=0 rather than a nil error"
  - "Halted-discard handle_info tracks last_seen_position so lag metrics remain honest even when the projector is stuck"
  - ":telemetry.execute in park_and_halt fires after the DB transaction result (regardless of success/failure) because the GenServer halts either way"
metrics:
  duration: "~15 minutes"
  completed: "2026-06-24"
  tasks_completed: 2
  files_modified: 2
---

# Phase 04 Plan 01: Projector Telemetry Instrumentation Summary

OTel span wrapping + four :telemetry metric sites added to Projector GenServer with projector_span_attrs/3 helper in Orkestra.Telemetry.

## Tasks Completed

| Task | Name | Commit | Files |
|------|------|--------|-------|
| 1 | Add projector_span_attrs/3 to Orkestra.Telemetry | 1929ca5 | lib/orkestra/telemetry.ex |
| 2 | Instrument Projector GenServer with OTel spans and :telemetry metrics | 00f429f | lib/orkestra/projector/gen_server.ex |

## What Was Built

### Task 1: projector_span_attrs/3 helper

Added `projector_span_attrs/3` to `Orkestra.Telemetry` after `event_attrs/1`, following the exact pattern of existing attribute helpers. Takes plain values (not structs) because the projector GenServer works with raw event maps.

Attributes emitted:
- `orkestra.projector.name` — projector module name string
- `orkestra.projector.position` — global event position
- `orkestra.event.type` — event type atom/string
- `orkestra.event.id` — event ID (bracket access with fallback to `""`)

### Task 2: GenServer instrumentation

**Imports added:**
- `require OpenTelemetry.Tracer, as: Tracer`
- `alias Orkestra.Telemetry, as: OTel`

**State extensions:**
- `last_seen_position: non_neg_integer() | nil` — tracks the last event position delivered to this GenServer (updated in both halted-discard and normal-delivery clauses)
- `rebuild_total: non_neg_integer() | nil` — total events for rebuild mode, read from config `:rebuild_total`
- `rebuild_events_replayed: non_neg_integer()` — counter incremented on each successful commit during rebuild

**TEL-01 — Span wrapping:**
`apply_event/2` body is wrapped in `Tracer.with_span "orkestra.projector.apply_event"` with `OTel.projector_span_attrs/3` attributes. Both error paths (storage adapter failure and transaction failure) call `Tracer.set_status(:error, inspect(reason))`.

**TEL-02 — Lag metric:**
After each successful `repo.transaction/1`, emits:
```elixir
:telemetry.execute([:orkestra, :projector, :lag], %{lag: lag}, %{projector_name: projector_name})
```
where `lag = (state.last_seen_position || position) - position`.

**TEL-03 — Rebuild progress:**
When `state.rebuild_total` is set and > 0, after each successful commit emits:
```elixir
:telemetry.execute(
  [:orkestra, :projector, :rebuild_progress],
  %{events_replayed: replayed, total_events: state.rebuild_total},
  %{projector_name: projector_name, percent: Float.round(...)}
)
```
and increments `state.rebuild_events_replayed`.

**TEL-04 retry — Retry metric:**
In `handle_failure/3` retry branch, after `Process.send_after`, emits:
```elixir
:telemetry.execute([:orkestra, :projector, :retry], %{attempts: new_attempts, delay_ms: delay}, ...)
```

**TEL-04 halt — Halt metric + OTel event:**
In `park_and_halt/4`, after the DB transaction block, emits:
```elixir
:telemetry.execute([:orkestra, :projector, :halted], %{attempts: attempts}, ...)
Tracer.add_event("projector.halted", %{"orkestra.projector.name" => ..., ...})
```

## Verification Results

- `mix compile --warnings-as-errors` passes with zero warnings
- `mix test --exclude postgres` passes: 187 tests, 0 failures, 25 excluded

## Deviations from Plan

None — plan executed exactly as written.

## Threat Model Compliance

| Threat ID | Mitigation | Status |
|-----------|------------|--------|
| T-04-01 | Span attributes include only event.type, event.id, projector.name, position — no event.data payload | Applied: projector_span_attrs/3 contains no event.data reference |
| T-04-02 | projector_name is compile-time constant from DSL macro | Accepted as designed |
| T-04-03 | One :telemetry.execute per event processed | Accepted: proportional to workload |

## Known Stubs

None.

## Self-Check: PASSED

- `lib/orkestra/telemetry.ex` — FOUND, contains `projector_span_attrs`
- `lib/orkestra/projector/gen_server.ex` — FOUND, contains `Tracer.with_span`, four `:telemetry.execute` call sites, `last_seen_position`, `rebuild_total`, `rebuild_events_replayed`
- Commit `1929ca5` — FOUND
- Commit `00f429f` — FOUND
