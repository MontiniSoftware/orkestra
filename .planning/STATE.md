---
gsd_state_version: 1.0
milestone: v1.1
milestone_name: Elasticsearch / OpenSearch Projection Adapter
status: verifying
stopped_at: "Completed 09-01: __projection_config__/0 extended + GenServer pause/resume"
last_updated: "2026-06-25T09:31:52.183Z"
last_activity: 2026-06-25
progress:
  total_phases: 6
  completed_phases: 4
  total_plans: 7
  completed_plans: 7
  percent: 67
---

# Project State

## Project Reference

See: .planning/PROJECT.md (updated 2026-06-25)

**Core value:** A developer can define a projection that consumes domain events and maintains a queryable read model — with safe rebuilds, in-order error handling, and per-projection migrations — without writing the plumbing themselves.
**Current focus:** Phase 09 — zero-downtime-rebuild-and-mix-task

## Current Position

Phase: 09 (zero-downtime-rebuild-and-mix-task) — EXECUTING
Plan: 2 of 2
Status: Phase complete — ready for verification
Last activity: 2026-06-25

Progress: [██████████] 100%

## Accumulated Context

### Decisions

Decisions are logged in PROJECT.md Key Decisions table.
Recent decisions affecting current work:

- Checkpoint writes: ES-first, Postgres-second (at-least-once semantics; idempotent ES writes via deterministic `_id`)
- Snap ~> 0.16 chosen as ES client (only maintained Elixir ES client; ships hotswap, bulk, auth extension)
- Checkpoints always stay in Postgres regardless of backend; ES projectors still require `:checkpoint_repo`
- `dynamic: strict` enforced on all managed indexes to prevent mapping footguns
- Finch named pool dedicated to ES adapter (prevents connection exhaustion during bulk rebuild)

### Pending Todos

None yet.

### Blockers/Concerns

- Phase 7 (GenServer batch accumulation): exact conditions for `:catching_up` → `:live` mode transition need verification against actual GenServer state machine during planning
- Phase 9 (Rebuild): alias-swap race window concurrency strategy (Postgres advisory lock suggested) needs detailed design during Phase 9 planning

## Deferred Items

| Category | Item | Status | Deferred At |
|----------|------|--------|-------------|
| MongoDB adapter | MONGO-01, MONGO-02 | v2 | v1.0 Roadmap |
| Dead-letter drain/resume tooling | ERR-05 | v2 | v1.0 Roadmap |
| AWS SigV4 auth | AUTH-01 | Future | v1.1 Requirements |
| Rebuild crash recovery (persisted state) | RRES-01 | Future | v1.1 Requirements |
| Search/count/get_by_id helpers | QHLP-01 | Future | v1.1 Requirements |

## Session Continuity

Last session: 2026-06-25T09:31:52.175Z
Stopped at: Completed 09-01: __projection_config__/0 extended + GenServer pause/resume
Resume file: None
