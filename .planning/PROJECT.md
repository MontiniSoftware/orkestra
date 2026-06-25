# Orkestra

## What This Is

Orkestra is an Elixir CQRS / event-sourcing library (plus an `orkestra_mcp` MCP server/CLI for code generation) for building event-driven Elixir applications. It provides command dispatch, aggregate lifecycle, event handling, pluggable message bus and event store adapters, and a **projection / read-model subsystem** with PostgreSQL/Ecto and Elasticsearch/OpenSearch storage adapters.

## Core Value

A developer can define a projection that consumes domain events and maintains a queryable read model — with safe rebuilds, in-order error handling, and per-projection migrations — without writing the plumbing themselves.

## Requirements

### Validated

- ✓ Command dispatch with command envelopes, lifecycle tracking, and retries — existing
- ✓ Aggregates (`Orkestra.Aggregate` behaviour + `Aggregate.Root` load→fold→decide→append→publish) — existing
- ✓ Events and event handlers with auto-subscription — existing
- ✓ Metadata with correlation/causation chaining — existing
- ✓ Message bus abstraction with PubSub (in-process) and RabbitMQ (distributed) adapters — existing
- ✓ Event store abstraction with InMemory and EventStoreDB (Spear) adapters — existing
- ✓ Snapshots (opt-in via `snapshot_every/0`) — existing
- ✓ OpenTelemetry spans + Logger metadata across the command/event pipeline — existing
- ✓ `orkestra_mcp` MCP server: code generators (`gen_*`), introspection resources (`list_*`, `domain_map`), and prompts — existing
- ✓ Projector DSL (`use Orkestra.Projector`) that maps events → read-model writes, supervised — v1.0
- ✓ Async event consumption via EventStore catch-up subscription with checkpoint resume — v1.0
- ✓ Per-projector checkpoint tracking with persisted resume-from-position — v1.0
- ✓ Strict in-order processing (single consumer per projector) — v1.0
- ✓ Supervised, isolated projectors (one halting doesn't stop others) — v1.0
- ✓ Pluggable storage-adapter behaviour (write/reset) — v1.0
- ✓ PostgreSQL/Ecto storage adapter with atomic checkpoint co-write (Ecto.Multi) — v1.0
- ✓ Per-projection isolated Ecto.Repo with dedicated connection pool and migration history — v1.0
- ✓ Per-projection Mix tasks: migrate, rollback, drop, rebuild — v1.0
- ✓ Rebuild: reset + gap-free replay from position zero + transition to live — v1.0
- ✓ Retry with backoff → park to dead-letter → halt (configurable per projector) — v1.0
- ✓ Halted status persisted and observable — v1.0
- ✓ Direct Ecto read access to read models — v1.0
- ✓ Optional generated Queries module (list/1 paged, get_by/2) — v1.0
- ✓ OTel spans per processed event + positional lag metric + rebuild progress metric + halt/error counters — v1.0
- ✓ MCP generators: gen_projection, gen_read_model, gen_queries — v1.0
- ✓ MCP introspection: projections surfaced in domain_map and ListProjections resource — v1.0
- ✓ Config: `:ultimus` → `:orkestra` fix + optional Ecto/Postgrex deps + documented per-projection config — v1.0

### Active

## Current State

**Latest shipped:** v1.1 Elasticsearch / OpenSearch Projection Adapter (2026-06-25)

**v1.1 delivered:**
- ES/OpenSearch storage adapter implementing `Orkestra.Projection.Storage` behaviour via Snap ~> 0.16
- Runtime engine detection (ES 8.x vs OpenSearch 2.x) with Basic Auth and API key auth
- GenServer ES commit path: single-doc writes (live) + batch bulk indexing (catch-up/rebuild)
- `use Orkestra.Projector, backend: :elasticsearch` with `project_es/2` macro
- Zero-downtime rebuild via `mix orkestra.projection.es.rebuild` using alias swap
- Pipe-based ES Query DSL (`Orkestra.Projection.ES.Query`)
- MCP generators: `gen_es_projection`, `gen_es_queries`
- ES projections visible in `domain_map` and `ListProjections` introspection

### Out of Scope

- MongoDB projection adapter — deferred to v2; build on the proven abstraction after Postgres
- Elasticsearch projection adapter — promoted to v1.1 (Active)
- Fully-uniform write-once query API across all backends — rejected; storage write/query APIs stay adapter-specific
- Synchronous (write-path inline) projections — rejected for v1 in favor of async + replay
- Dead-letter drain/resume tooling — deferred to v2

## Context

Shipped v1.0 with 4,866 LOC Elixir (lib/) + 3,186 LOC Elixir (test/).
Tech stack: Elixir 1.18+, OTP 27+, Ecto, Phoenix.PubSub, OpenTelemetry, Hermes.MCP.
Repo layout: core library in `lib/orkestra/`; MCP server/CLI in `orkestra_mcp/` sub-project.
All 31 v1 requirements verified by milestone audit (31/31 passed).

## Constraints

- **Tech stack**: Elixir `~> 1.18`; projections build on **Ecto** for the Postgres adapter. Storage deps are optional, consistent with the existing amqp/spear approach.
- **Compatibility**: Integrates with the existing event store + message bus; projectors are additive consumers.
- **Architecture**: Shared projector lifecycle with per-adapter storage write/query APIs — each backend stays idiomatic.
- **Observability**: Reuses existing OpenTelemetry `Telemetry` module conventions.

## Key Decisions

| Decision | Rationale | Outcome |
|----------|-----------|---------|
| Async projections via EventStore catch-up subscription | Decouples read side from write path; standard CQRS/ES | ✓ Good |
| Full rebuild + per-projector checkpoints | Safe read-model evolution (resume + rebuild from scratch) | ✓ Good |
| Ecto for the Postgres adapter | Elixir standard; migrations/rollbacks/queries with strong ecosystem fit | ✓ Good |
| Migrations fully isolated per projection | Independent migrate/rollback/drop/rebuild per read model | ✓ Good |
| Error handling: retry → park → halt | In-order integrity; reuses existing retry semantics; configurable | ✓ Good |
| Read API: Ecto-first + optional Queries module | Idiomatic and unopinionated with convenience layer | ✓ Good |
| Shared lifecycle, per-adapter storage APIs | SQL/document/search differ; keep each backend idiomatic | ✓ Good |
| Postgres first; MongoDB + ES as follow-up | Prove abstraction end-to-end before generalizing | ✓ Good |
| MCP generators + introspection for projections | Consistent with existing gen_*/list_*/domain_map | ✓ Good |
| Fix `:ultimus` → `:orkestra` config bug | Touching config for per-projection repos — natural cleanup point | ✓ Good |
| Storage.write/4 returns `ops :: term()` | Adapter-agnostic write descriptor; Ecto Multi fragment | ✓ Good |
| subscribe_from_position/3 exclusive semantics | Matches Spear `from:` parameter semantics | ✓ Good |
| Checkpoint/DeadLetter in Code.ensure_loaded? guard | Library compiles without Ecto installed | ✓ Good |
| Oban migration pattern (Orkestra owns DDL, consumer controls timing) | Clean separation of concerns | ✓ Good |

## Evolution

This document evolves at phase transitions and milestone boundaries.

**After each phase transition** (via `/gsd-transition`):
1. Requirements invalidated? → Move to Out of Scope with reason
2. Requirements validated? → Move to Validated with phase reference
3. New requirements emerged? → Add to Active
4. Decisions to log? → Add to Key Decisions
5. "What This Is" still accurate? → Update if drifted

**After each milestone** (via `/gsd-complete-milestone`):
1. Full review of all sections
2. Core Value check — still the right priority?
3. Audit Out of Scope — reasons still valid?
4. Update Context with current state

---
*Last updated: 2026-06-25 after v1.1 milestone start*
