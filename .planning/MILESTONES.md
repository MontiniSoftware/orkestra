# Milestones

## v1.0 — Projection / Read-Model Subsystem

**Shipped:** 2026-06-24
**Phases:** 5 | **Plans:** 13

### Delivered

Complete projection / read-model subsystem for Orkestra: storage-agnostic projector lifecycle with PostgreSQL/Ecto as the first adapter, developer-facing DSL, per-projection migrations, telemetry, and MCP code generators.

### Key Accomplishments

1. Pure Lifecycle functions (retry/backoff/halt) + Storage behaviour + EventStore catch-up subscription API
2. Projector GenServer with full subscribe→catch-up→live→retry→halt state machine and atomic Ecto Multi checkpoint co-write
3. `use Orkestra.Projector` DSL macro + one_for_one Projection Supervisor + per-projection Mix tasks (migrate/rollback/drop/rebuild)
4. OpenTelemetry spans + telemetry metrics (positional lag, rebuild progress, halt counter, retry events) per projector
5. MCP generators (gen_projection, gen_read_model, gen_queries) + introspection resources (ListProjections, domain_map extension)

### Stats

- Requirements: 31/31 satisfied
- Commits: 103
- Files changed: 215
- LOC (lib): 4,866 Elixir
- LOC (test): 3,186 Elixir
- Timeline: 2026-06-24

### Tech Debt at Close

- 4 mix task Postgres integration tests have known migration_lock race failures
- @moduledoc slug word-boundary splitting inconsistency (cosmetic)
- Lag metric is always 0 during normal live processing (meaningful only for halted projectors)
- gen_queries Queries module uses runtime repo injection

### Archives

- [v1.0-ROADMAP.md](milestones/v1.0-ROADMAP.md)
- [v1.0-REQUIREMENTS.md](milestones/v1.0-REQUIREMENTS.md)
- [v1.0-MILESTONE-AUDIT.md](milestones/v1.0-MILESTONE-AUDIT.md)
