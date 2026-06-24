---
gsd_state_version: 1.0
milestone: v1.0
milestone_name: milestone
current_phase: 2
current_phase_name: Projector GenServer + Ecto Adapter
status: verifying
stopped_at: Completed 01-03-PLAN.md — Checkpoint, DeadLetter schemas and Migration module created
last_updated: "2026-06-24T12:45:27.782Z"
last_activity: 2026-06-24
last_activity_desc: Phase 1 complete, transitioned to Phase 2
progress:
  total_phases: 5
  completed_phases: 1
  total_plans: 3
  completed_plans: 3
  percent: 20
---

# Project State

## Project Reference

See: .planning/PROJECT.md (updated 2026-06-24)

**Core value:** A developer can define a projection that consumes domain events and maintains a queryable read model — with safe rebuilds, in-order error handling, and per-projection migrations — without writing the plumbing themselves.
**Current focus:** Phase 01 — Foundations

## Current Position

Phase: 2 — Projector GenServer + Ecto Adapter
Plan: Not started
Status: Phase complete — ready for verification
Last activity: 2026-06-24 — Phase 1 complete, transitioned to Phase 2

Progress: [░░░░░░░░░░] 0%

## Performance Metrics

**Velocity:**

- Total plans completed: 3
- Average duration: —
- Total execution time: 0 hours

**By Phase:**

| Phase | Plans | Total | Avg/Plan |
|-------|-------|-------|----------|
| 1 | 3 | - | - |

**Recent Trend:**

- Last 5 plans: —
- Trend: —

*Updated after each plan completion*
| Phase 01 P01 | 9 | 2 tasks | 4 files |
| Phase 01-foundations P02 | 13 | 3 tasks | 7 files |
| Phase 01 P03 | 6 | 2 tasks | 4 files |

## Accumulated Context

### Decisions

Decisions are logged in PROJECT.md Key Decisions table.
Recent decisions affecting current work:

- Roadmap: EventStore catch-up subscription (not MessageBus) is the consumption model — Phase 1 extends the EventStore behaviour before Phase 2 builds the GenServer against it
- Roadmap: Checkpoint + read-model write must be in one Ecto.Multi transaction — non-negotiable correctness constraint established in Phase 2
- Roadmap: Per-projection isolated Ecto.Repo with separate `migration_source` — independent migrate/rollback/drop/rebuild cycles
- [Phase ?]: No transient/permanent classification in v1
- [Phase ?]: Fully unit-testable with async: true
- [Phase ?]: Storage.write/4 returns ops :: term() — adapter-agnostic write descriptor
- [Phase ?]: subscribe_from_position/3 uses exclusive > from_position semantics matching Spear from: parameter (Pitfall 1)
- [Phase ?]: InMemory Agent.get_and_update atomically registers subscriber + snapshots history to prevent race/gap (Pitfall 3)
- [Phase ?]: Checkpoint and DeadLetter full-module defmodule wrapped in Code.ensure_loaded? guard (RESEARCH Pattern 3/4) — not just use directive — so library compiles without ecto
- [Phase ?]: Oban migration pattern: Orkestra.Projection.Migration.up/0 and down/0 delegated to by consumer wrapper migration — Orkestra owns DDL, consumer controls timing and Repo
- [Phase ?]: T-01-05 mitigated: event_data field type :map (JSON/jsonb) avoids unsafe atom deserialization unlike :erlang.binary_to_term

### Pending Todos

None yet.

### Blockers/Concerns

- Phase 1: `subscribe_from_position` API shape for InMemory adapter (polling vs process-local delivery) — decision needed during Phase 1 planning
- Phase 1: Checkpoint table ownership (Orkestra-owned migrations vs consumer-app migrations) — resolve in Phase 1 planning (research recommends Orkestra-owned)

## Deferred Items

| Category | Item | Status | Deferred At |
|----------|------|--------|-------------|
| MongoDB adapter | MONGO-01, MONGO-02 | v2 | Roadmap |
| Elasticsearch adapter | ES-01 through ES-05 | v2 | Roadmap |
| Dead-letter drain/resume tooling | ERR-05 | v2 | Roadmap |

## Session Continuity

Last session: 2026-06-24T12:38:09.938Z
Stopped at: Completed 01-03-PLAN.md — Checkpoint, DeadLetter schemas and Migration module created
Resume file: None
