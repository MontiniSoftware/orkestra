# Orkestra

## What This Is

Orkestra is an Elixir CQRS / event-sourcing library (plus an `orkestra_mcp` MCP server/CLI for code generation) for building event-driven Elixir applications. This milestone adds a **projection / read-model subsystem** — `event → projector → database` — that makes it easy for developers to derive and maintain read models from their event streams, starting with PostgreSQL and extending to MongoDB and Elasticsearch.

## Core Value

A developer can define a projection that consumes domain events and maintains a queryable read model — with safe rebuilds, in-order error handling, and per-projection migrations — without writing the plumbing themselves.

## Requirements

### Validated

<!-- Existing orkestra capabilities, inferred from the codebase map (.planning/codebase/). -->

- ✓ Command dispatch with command envelopes, lifecycle tracking, and retries — existing
- ✓ Aggregates (`Orkestra.Aggregate` behaviour + `Aggregate.Root` load→fold→decide→append→publish) — existing
- ✓ Events and event handlers with auto-subscription — existing
- ✓ Metadata with correlation/causation chaining — existing
- ✓ Message bus abstraction with PubSub (in-process) and RabbitMQ (distributed) adapters — existing
- ✓ Event store abstraction with InMemory and EventStoreDB (Spear) adapters — existing
- ✓ Snapshots (opt-in via `snapshot_every/0`) — existing
- ✓ OpenTelemetry spans + Logger metadata across the command/event pipeline — existing
- ✓ `orkestra_mcp` MCP server: code generators (`gen_*`), introspection resources (`list_*`, `domain_map`), and prompts — existing

### Active

<!-- This milestone's scope. Hypotheses until shipped and validated. -->

**Projection framework (storage-agnostic core)**
- [ ] Define a projector via a macro/behaviour that maps events → read-model writes, supervised like existing handlers
- [ ] Projectors consume events asynchronously via the message bus (eventually consistent)
- [ ] Per-projector checkpoint tracking — persist last-processed position, resume after restart
- [ ] Replay/rebuild — drop and rebuild a read model from the full event stream
- [ ] In-order error handling: retry (reuse orkestra retry semantics) → on exhaustion, park the event to dead-letter and **halt that projector** (no skipping ahead); configurable per projector
- [ ] Projection telemetry: OTel spans per event plus lag (events behind head), checkpoint position, rebuild progress, and error counts

**PostgreSQL adapter (Ecto) — first storage target**
- [ ] Ecto-backed read-model storage
- [ ] Per-projection migrations, **fully isolated**: each projection owns its tables and its own migration history, independently migratable / rollback-able / droppable / rebuildable
- [ ] Ecto-first read access (developers query their read models directly)
- [ ] Optional generated `Queries` module per read model with generic helpers (`list/1` paged, `get_by/2`, …) — prototype and refine

**MCP integration**
- [ ] `gen_projection` / `gen_read_model` generators (including migration scaffolding)
- [ ] Introspection: projections + read models surfaced in MCP resources (`domain_map`, `list_*`)

**Config cleanup (folded in)**
- [ ] Fix the `:ultimus` app-key bug in `event_store.ex` (→ `:orkestra`) and establish a clean config story alongside the new per-projection repo configuration

### Out of Scope

<!-- Explicit boundaries with reasoning. -->

- MongoDB projection adapter — deferred to a follow-up milestone; build it on the proven abstraction after Postgres
- Elasticsearch projection adapter — deferred to a follow-up milestone. When built, "full" support means: index mappings + versioned reindex (the ES analog of migrations), search query helpers (the `Queries` module for ES), zero-downtime rebuild via alias swap, and bulk indexing. The core abstraction must not preclude these.
- Fully-uniform write-once query API across all backends — rejected as leaky over SQL vs document vs search differences; storage write/query APIs stay adapter-specific
- Synchronous (write-path inline) projections — rejected for v1 in favor of async + replay to keep the write side decoupled

## Context

- **Brownfield**: Orkestra is an existing v0.1.0 Elixir library. Codebase map lives in `.planning/codebase/` (STACK, ARCHITECTURE, STRUCTURE, CONVENTIONS, TESTING, INTEGRATIONS, CONCERNS).
- **Repo layout**: core library in `lib/orkestra/`; the MCP server/CLI in the `orkestra_mcp/` sub-project (separate `mix.exs`, escript via `OrkestraMcp.CLI`).
- **Existing patterns to reuse**: behaviours + DSL macros (e.g. `param`/`field`), auto-subscribing GenServer handlers, the message bus and event store adapter abstractions, the OTel `Telemetry` module, and the optional-dependency pattern (amqp/spear) — Ecto/postgrex will follow the same optional-dep approach.
- **Known issues from the map** relevant here: the `:ultimus` config-key bug (being fixed this milestone); machine-specific absolute paths in `.mcp.json`; test-coverage gaps across core modules; regex-based introspection fragility in `orkestra_mcp`.
- **Audience**: Elixir developers building event-sourced apps; eventually the public Elixir/Hex community.

## Constraints

- **Tech stack**: Elixir `~> 1.18`; projections build on **Ecto** for the Postgres adapter (migrations/rollbacks/queries). Storage deps are optional dependencies, consistent with the existing amqp/spear approach.
- **Compatibility**: Must integrate with the existing event store + message bus rather than replacing them; projectors are additive consumers of the event stream.
- **Architecture**: Shared projector lifecycle (subscription, checkpoints, retry/park-halt error handling, replay/rebuild) with **per-adapter** storage write/query APIs — each backend stays idiomatic.
- **Observability**: Reuse the existing OpenTelemetry `Telemetry` module conventions for all new spans/metrics.

## Key Decisions

| Decision | Rationale | Outcome |
|----------|-----------|---------|
| Async projections via message bus + replay from event store | Decouples read side from the write path; standard CQRS/ES; fits orkestra's existing message_bus + event_store | — Pending |
| Full rebuild + per-projector checkpoints | Lets read models evolve safely (resume after restart; rebuild from scratch) | — Pending |
| Ecto for the Postgres adapter | Elixir standard; gives migrations/rollbacks/queries with strong ecosystem fit | — Pending |
| Migrations fully isolated per projection | Each read model can migrate/rollback/drop/rebuild independently of others and of the app's own migrations — the "graceful migrations" goal | — Pending |
| Error handling: retry → park to dead-letter → halt projector | Read models need in-order processing; halting prevents gaps/corruption; reuses existing retry semantics; configurable per projector | — Pending |
| Read API: Ecto-first + optional generated `Queries` module | Idiomatic and unopinionated, with a convenience layer (paged `list/1`, `get_by/2`) to explore | — Pending |
| Shared lifecycle, per-adapter storage APIs | SQL vs document vs search differ too deeply for a uniform write/query API; keep each backend idiomatic | — Pending |
| Postgres first; MongoDB + Elasticsearch as follow-up milestones | Prove the abstraction end-to-end on one backend before generalizing | — Pending |
| MCP: generators + introspection for projections | Consistent with existing `gen_*` tools and `list_*`/`domain_map` resources | — Pending |
| Fix `:ultimus` → `:orkestra` config bug this milestone | We're touching config for per-projection repos anyway; natural place to clean it up | — Pending |

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
*Last updated: 2026-06-24 after initialization*
