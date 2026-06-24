# Project Retrospective

*A living document updated after each milestone. Lessons feed forward into future planning.*

## Milestone: v1.0 — Projection / Read-Model Subsystem

**Shipped:** 2026-06-24
**Phases:** 5 | **Plans:** 13

### What Was Built
- Pure Lifecycle functions (retry/backoff/halt) + Storage behaviour + EventStore catch-up subscription API
- Projector GenServer with full subscribe→catch-up→live→retry→halt state machine and atomic Ecto Multi checkpoint co-write
- `use Orkestra.Projector` DSL macro + one_for_one Projection Supervisor + per-projection Mix tasks
- OpenTelemetry spans + telemetry metrics (lag, rebuild progress, halt, retry) per projector
- MCP generators (gen_projection, gen_read_model, gen_queries) + introspection resources

### What Worked
- Layered phase design: each phase built cleanly on the previous one's contracts
- Pure functions first (Lifecycle module) — made everything testable with `async: true`
- Oban migration pattern (Orkestra owns DDL, consumer controls timing) — clean separation
- Code.ensure_loaded? guard pattern — library compiles without Ecto installed
- Wave-based plan execution with worktree isolation enabled parallel work safely

### What Was Inefficient
- ROADMAP progress table and REQUIREMENTS checkboxes fell out of sync with actual execution state
- Some CWD drift during worktree merges required recovery commits
- STATE.md progress counters stalled after Phase 1 — not updated during execution

### Patterns Established
- `Storage.write/4` returns `ops :: term()` — adapter-agnostic write descriptor pattern for future backends
- Per-projection isolated Repo with dedicated `migration_source` — clean multi-tenant migration isolation
- subscribe_from_position/3 exclusive semantics — consistent with Spear, foundation for all future adapters
- Checkpoint/DeadLetter in Code.ensure_loaded? guard — optional-dep compile safety pattern

### Key Lessons
1. Planning state files (ROADMAP progress, REQUIREMENTS checkboxes) must be updated atomically with execution — stale tracking creates confusion at audit time
2. The audit step is essential — it caught two real integration bugs (slug mismatch + default event_store) that would have shipped broken
3. Pure-functions-first design pays off: Lifecycle module was zero-rework across all 5 phases

---

## Cross-Milestone Trends

### Process Evolution

| Milestone | Phases | Plans | Key Change |
|-----------|--------|-------|------------|
| v1.0 | 5 | 13 | First milestone — established research→plan→execute→verify workflow |

### Top Lessons (Verified Across Milestones)

1. Run milestone audit before close — it catches real integration bugs
2. Keep planning state files in sync with execution state
