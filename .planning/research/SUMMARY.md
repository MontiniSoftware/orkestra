# Project Research Summary

**Project:** Orkestra — Projection / Read-Model Subsystem
**Domain:** Elixir CQRS/ES library — event-sourced projection subsystem
**Researched:** 2026-06-24
**Confidence:** MEDIUM

## Executive Summary

Orkestra is adding a projection / read-model subsystem to an existing Elixir CQRS/ES library. The dominant reference implementation in the Elixir ecosystem (Commanded + commanded-ecto-projections) provides a well-understood blueprint for the DSL, checkpoint pattern, and Ecto.Multi-based transactional writes — but it has notable gaps: no per-projection migration isolation, no park-and-halt error semantics (only skip), no first-class lag telemetry, and no rebuild progress reporting. Orkestra's design intentionally addresses all four of these gaps, which makes the projection subsystem a genuine improvement over the state of the art rather than a clone.

The recommended approach is a shared projector lifecycle (subscription, checkpointing, retry/park/halt, rebuild) with adapter-specific write APIs, starting exclusively with PostgreSQL via Ecto. The core architectural insight is that projectors must subscribe to the EventStore directly (catch-up subscription from last checkpoint), not to the MessageBus — the bus only delivers live events and cannot replay history. Each projector owns its own Ecto.Repo, migration table, and `priv/` directory, enabling fully independent migrate/rollback/drop/rebuild cycles. Checkpoints and read-model writes happen in a single Ecto.Multi transaction — this is the non-negotiable correctness constraint.

The principal risks are lifecycle correctness: out-of-order processing, checkpoint/idempotency bugs, and rebuild race conditions where events are silently lost during the catch-up-to-live handoff. All three are design-time concerns that must be addressed in the core GenServer lifecycle before any storage adapter work begins. Using EventStoreDB's native catch-up subscription (via Spear) eliminates the rebuild race condition by making the history-to-live transition seamless and gap-free.

## Key Findings

### Recommended Stack

Ecto `~> 3.14` + ecto_sql `~> 3.14` + postgrex `~> 0.22` is the only stack for the Postgres adapter. These are the current stable versions (all released May 2026) and the Elixir community standard. All three must be declared as optional dependencies in Orkestra's `mix.exs`, consistent with the existing `:amqp` / `:spear` pattern — the consumer app adds them explicitly.

Future adapter dependencies (`mongodb_driver ~> 1.5`, `snap ~> 0.16` for Elasticsearch) are deferred to follow-on milestones. Both packages are actively maintained; the legacy `mongodb` and `elastix` hex packages must not be used.

**Core technologies (this milestone):**
- `ecto ~> 3.14`: Schema definition, changesets, query API — Elixir standard, required for migration DSL
- `ecto_sql ~> 3.14`: SQL adapter layer + `Ecto.Migrator.run/4` — required for per-projection isolated migration execution
- `postgrex ~> 0.22`: PostgreSQL wire-protocol driver — required alongside ecto_sql; pin for reproducibility

**Not added (this milestone):** `commanded` / `commanded_ecto_projections` — only patterns are borrowed, not code.

### Expected Features

**Must have (P1 — this milestone):**
- Projector DSL: `use Orkestra.Projector` + `project EventType, fn event, multi -> ... end`
- Async consumption via EventStore catch-up subscription (not MessageBus)
- Per-projector checkpoint persistence — atomic with read-model write in one Ecto.Multi transaction
- Resume after restart — read checkpoint on init, subscribe from that position
- Full rebuild / replay — drop tables + checkpoint → replay from position 0 → transition to live
- In-order error handling: retry N times → park event to dead-letter → halt projector (no skip)
- Dead-letter table — (projector_name, event_position, event_data, error, attempts, parked_at)
- Per-projection isolated migrations — own Repo, own `migration_source`, own `priv/` directory
- Projection lag + checkpoint telemetry — OTel gauges: lag = head − checkpoint position
- Rebuild progress telemetry — separate gauge for rebuild % complete
- Config bug fix: `:ultimus` → `:orkestra` app key in event_store.ex

**Should have (P2 — v1.x):** Optional generated Queries module, MCP `gen_projection` generator, dead-letter drain/resume tooling.

**Defer (P3):** MongoDB adapter, Elasticsearch adapter.

**Explicit anti-features:** Synchronous inline projections, skip-on-error as default, shared migration repo, uniform cross-backend query API.

### Architecture Approach

The projection subsystem sits entirely on the read side. A new `Orkestra.Projection.Supervisor` (one_for_one) manages all projector GenServers and their per-projection Repos. The `Orkestra.Projection.Storage` behaviour (`write/4`, `reset/1`) separates the shared lifecycle from adapter-specific write mechanics.

**Major components:**
1. `Orkestra.Projector` — behaviour + DSL macro; developer-facing entry point
2. `Orkestra.Projector.Server` — GenServer: subscribe → catch-up → live → retry → park → halt state machine
3. `Orkestra.Projector.Lifecycle` — pure functions: error classification, retry delay, halt decision
4. `Orkestra.Projection.Storage` — behaviour contract for all storage adapters
5. `Orkestra.Projection.Storage.Ecto` — Postgres adapter: Ecto.Multi + atomic checkpoint co-write
6. `Orkestra.Projection.Checkpoint` — read/write checkpoint position (shared Ecto schema)
7. `Orkestra.Projection.DeadLetter` — park failed events (shared Ecto schema)
8. `Orkestra.Projection.Supervisor` — one_for_one; projectors use `restart: :transient`
9. Mix tasks — `mix orkestra.projection.migrate/rollback/drop/rebuild`

**Build order is strict:** Checkpoint + DeadLetter schemas → Storage behaviour → Storage.Ecto → Lifecycle pure functions → Projector.Server GenServer → Projector macro → Supervisor → Mix tasks → EventStore `subscribe_from_position` API.

### Critical Pitfalls

1. **EventStore subscription vs MessageBus** — MessageBus misses all pre-subscription events. Always use EventStore catch-up subscription. This is an architectural choice that cannot be retrofitted.

2. **Non-atomic checkpoint writes** — Separate transactions for checkpoint and read-model write cause double-writes on restart. The checkpoint upsert must be inside the same `Ecto.Multi` as the read-model write.

3. **Rebuild race condition** — Dual-path (replay + live subscription) creates a window where events are applied twice or missed. Use a single EventStore catch-up subscription that transitions seamlessly to live — no separate paths.

4. **Poison events without observability** — Halt is correct, but halt status must be emitted as telemetry and persisted to the checkpoint store. A silent halt looks like a healthy but stale projector.

5. **Ecto connection pool exhaustion during rebuild** — Per-projection Repos with dedicated pools prevent rebuild from starving the main app. Batch writes (`Repo.insert_all/3`) and streaming event reads are required for large event stores.

## Implications for Roadmap

### Phase 1: Core Lifecycle Foundations
**Rationale:** Checkpoint + DeadLetter schemas and the Storage behaviour have zero external dependencies and define the correctness contracts for all subsequent work. Lifecycle pure functions must be correct before the GenServer is built against them.
**Delivers:** `Orkestra.Projection.Checkpoint`, `Orkestra.Projection.DeadLetter` (Ecto schemas + Orkestra-owned migrations), `Orkestra.Projection.Storage` behaviour, `Orkestra.Projector.Lifecycle` pure functions, EventStore `subscribe_from_position` API addition.
**Avoids:** Non-atomic checkpoint writes (Pitfall 2), out-of-order processing (Pitfall 1), rebuild race condition design flaw (Pitfall 3).

### Phase 2: Projector GenServer + Ecto Adapter
**Rationale:** With behaviour contract and pure functions in place, the GenServer and Ecto adapter can be built and validated together — the adapter proves the Storage behaviour is complete; the Server proves the lifecycle state machine is correct end-to-end.
**Delivers:** `Orkestra.Projector.Server` (full state machine), `Orkestra.Projection.Storage.Ecto` (Ecto.Multi + atomic checkpoint), per-projection Repo isolation (separate `migration_source` + `priv/`).
**Uses:** ecto ~> 3.14, ecto_sql ~> 3.14, postgrex ~> 0.22 (optional deps).
**Avoids:** Ecto pool exhaustion (Pitfall 5), migration drift (Pitfall 6).

### Phase 3: Projector Macro, Supervisor, and Mix Tasks
**Rationale:** Developer-facing DSL and operational tooling require a working Server and adapter underneath. This makes the subsystem usable by consuming applications.
**Delivers:** `use Orkestra.Projector` DSL macro, `Orkestra.Projection.Supervisor`, mix tasks for migrate/rollback/drop/rebuild, config bug fix (`:ultimus` → `:orkestra`).

### Phase 4: Telemetry and Observability
**Rationale:** Telemetry depends on checkpoint positions (lag computation) and projector status (rebuild vs live). Must follow the proven core lifecycle.
**Delivers:** OTel spans per event, positional lag gauge (head − checkpoint), rebuild progress gauge (separate metric), halted-projector telemetry event + checkpoint status flag, `wait_for_projection/1` test helper.
**Avoids:** Lag misimplementation (Pitfall 9 — positional not wall-clock), halt without visibility (Pitfall 4), read-after-write test races (Pitfall 7).

### Phase 5: MCP Integration and Query Helpers (v1.x)
**Rationale:** Code generation requires a validated, stable API surface. Ship only after end-to-end integration is proven in a real application.
**Delivers:** `gen_projection` / `gen_read_model` MCP generators, `domain_map` + `list_projections` introspection, optional `Orkestra.Projector.Queries` module.

### Phase Ordering Rationale

- Phases 1→2 follow the strict build-order dependency graph from ARCHITECTURE.md: behaviours before adapters, pure functions before GenServers.
- Phase 3 (macro + supervisor) requires a working Server and adapter to generate meaningful, testable code.
- Phase 4 (telemetry) requires queryable checkpoint positions and persisted projector status — only available after Phase 2.
- Phase 5 is additive and must wait for real-world API validation before generators can produce idiomatic scaffolding.

### Research Flags

Phases needing deeper research during planning:
- **Phase 1:** EventStore `subscribe_from_position` API — the existing `Orkestra.EventStore` behaviour must be extended; InMemory emulation strategy and Spear's persistent subscription API need targeted research.
- **Phase 2:** Per-projection Repo isolation — `migration_source` config key, `Ecto.Migrator.with_repo/3` interaction with app supervisor — well-documented but worth a targeted hexdocs pass during planning.

Phases with standard patterns (skip research-phase):
- **Phase 3:** Follows existing `Orkestra.EventHandler` macro pattern — brownfield extension, no novel territory.
- **Phase 4:** Follows existing `Orkestra.Telemetry` OTel conventions — established internal pattern.
- **Phase 5:** Follows existing `gen_aggregate` / `gen_command` MCP generator pattern — additive.

## Confidence Assessment

| Area | Confidence | Notes |
|------|------------|-------|
| Stack | MEDIUM | Versions confirmed on hex.pm June 2026; optional-dep pattern confirmed against Orkestra codebase |
| Features | MEDIUM | Commanded ecosystem is the reference; Orkestra differentiators are soundly reasoned but unvalidated until shipped |
| Architecture | MEDIUM | Core lifecycle and Ecto isolation verified against hexdocs; EventStore subscription design inferred from Commanded + EventStore library patterns |
| Pitfalls | MEDIUM | Multiple web sources cross-checked; Elixir-specific pitfalls inferred from Commanded ecosystem literature |

**Overall confidence:** MEDIUM

### Gaps to Address

- **EventStore `subscribe_from_position` API:** The current `Orkestra.EventStore` behaviour does not expose a catch-up subscription. Exact callback signature and both adapter implementations (InMemory emulation, Spear call) need to be defined in Phase 1 planning.
- **InMemory adapter subscription emulation:** Polling vs process-local delivery tradeoff needs a decision during Phase 1 — affects test ergonomics significantly.
- **Checkpoint table ownership:** Whether Orkestra ships its own migrations (run by the consumer) or the checkpoint/dead-letter tables are created by the consumer app's migration needs to be locked down in Phase 1 planning.
- **Ecto Sandbox in tests:** Projector GenServers use a different DB connection than the test process; `Ecto.Adapters.SQL.Sandbox.allow/3` is required and must be explicitly designed into the Phase 4 test helper.

## Sources

### Primary (MEDIUM confidence)
- hexdocs.pm/ecto — Ecto.Repo `:priv`, `migration_source`, multiple repo config
- hexdocs.pm/ecto_sql — Ecto.Migrator.run/4, with_repo/3
- hex.pm/packages/ecto, ecto_sql, postgrex — version 3.14.0 / 0.22.2, May 2026
- hexdocs.pm/commanded — Commanded.Event.Handler error/3, start_from, lifecycle
- hexdocs.pm/commanded-ecto-projections — project macro, Ecto.Multi, projection_versions table
- Orkestra codebase (.planning/codebase/) — existing patterns: behaviours, macros, OTel, optional deps

### Secondary (MEDIUM confidence)
- hex.pm/packages/mongodb_driver v1.6.3 — confirmed actively maintained
- hex.pm/packages/snap v0.16.0 — confirmed actively maintained; zero-downtime alias swap
- commanded/commanded-ecto-projections (GitHub) — source-verified checkpoint schema, project macro

### Tertiary (LOW confidence)
- event-driven.io — projections/read models, rebuild patterns
- domaincentric.net — deduplication strategies, consumer scaling
- codeopinion.com — eventual consistency UX concerns
- dev.to, softwaremill.com, axoniq.io — CQRS/ES pitfall literature

---
*Research completed: 2026-06-24*
*Ready for roadmap: yes*
