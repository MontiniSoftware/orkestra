# Roadmap: Orkestra — Projection / Read-Model Subsystem

## Overview

This milestone adds a complete projection / read-model subsystem to Orkestra. Starting from the correctness foundations (schemas, behaviour contract, lifecycle pure functions, and the EventStore catch-up subscription API), the work builds upward through the Projector GenServer and Ecto adapter, then the developer-facing DSL and operational tooling, then telemetry, and finally MCP code generators and the optional Queries helper. Each phase delivers a coherent, independently verifiable capability. The Postgres/Ecto adapter is built first and proves the shared lifecycle abstraction that future MongoDB and Elasticsearch adapters will slot into.

## Phases

**Phase Numbering:**

- Integer phases (1, 2, 3): Planned milestone work
- Decimal phases (2.1, 2.2): Urgent insertions (marked with INSERTED)

Decimal phases appear between their surrounding integers in numeric order.

- [ ] **Phase 1: Foundations** - Checkpoint + DeadLetter schemas, Storage behaviour, Lifecycle pure functions, and EventStore catch-up subscription API
- [ ] **Phase 2: Projector GenServer + Ecto Adapter** - Full subscribe→catch-up→live→retry→halt state machine with atomic Ecto checkpoint co-write and per-projection Repo isolation
- [ ] **Phase 3: DSL, Supervisor, Mix Tasks, and Config** - `use Orkestra.Projector` macro, one_for_one Supervisor, migrate/rollback/drop/rebuild mix tasks, and config cleanup
- [ ] **Phase 4: Telemetry & Observability** - OTel spans per event, positional lag metric, rebuild progress metric, and halted-projector telemetry
- [ ] **Phase 5: MCP Integration and Query Helpers** - `gen_projection` / `gen_read_model` generators, introspection resources, and optional Queries module

## Phase Details

### Phase 1: Foundations

**Goal**: The shared correctness contracts and data structures are in place so all subsequent phases build on a solid, dependency-free base
**Depends on**: Nothing (first phase)
**Requirements**: STORE-01, ERR-01, ERR-02, ERR-03, PROJ-02
**Success Criteria** (what must be TRUE):

  1. `Orkestra.Projection.Storage` behaviour is defined with `write/4` and `reset/2` callbacks; a module implementing it passes the behaviour contract
  2. `Orkestra.Projection.Checkpoint` and `Orkestra.Projection.DeadLetter` Ecto schemas exist with Orkestra-owned migrations that create the `projection_checkpoints` and `projection_dead_letters` tables
  3. `Orkestra.Projector.Lifecycle` pure functions correctly classify errors, compute retry delays, and decide halt — verifiable via unit tests with no I/O
  4. The `Orkestra.EventStore` behaviour exposes a `subscribe_from_position/3` callback; both InMemory and EventStoreDB adapters implement it, and the InMemory emulation delivers events in order during tests

**Plans**: 2/3 plans executed
**Wave 1**

- [x] 01-01-PLAN.md — Optional Ecto deps + pure Projector.Lifecycle (retry/backoff/halt) [ERR-01, ERR-03]
- [x] 01-02-PLAN.md — Storage behaviour + EventStore subscribe_from_position/3 (both adapters) [STORE-01, PROJ-02]

**Wave 2** *(blocked on Wave 1 completion)*

- [ ] 01-03-PLAN.md — Checkpoint + DeadLetter Ecto schemas + Orkestra-owned migration [ERR-02, ERR-03]

### Phase 2: Projector GenServer + Ecto Adapter

**Goal**: A projector GenServer processes events end-to-end — subscribing from its checkpoint, catching up, going live, retrying errors, parking exhausted events, and halting — with checkpoint and read-model writes committed atomically in one Ecto transaction, in a fully isolated per-projection Repo
**Depends on**: Phase 1
**Requirements**: PROJ-03, PROJ-04, STORE-02, STORE-03, STORE-04, MIG-01, ERR-04, READ-01
**Success Criteria** (what must be TRUE):

  1. A projector GenServer resumes from its persisted checkpoint position after a restart, replaying only events it has not yet processed
  2. Events are applied strictly in order — no concurrent application to the same read model; a projector processes events sequentially
  3. The checkpoint position and the read-model write commit in a single `Ecto.Multi` transaction; a simulated crash between them does not produce a double-write or missed-write on restart
  4. A projector that exhausts retries has its halted status persisted to the checkpoint store, so the halt is visible and not a silent stall
  5. A developer can query a read model directly using Ecto on the per-projection Repo; the Repo uses its own isolated `migration_source` table and `priv/` directory

**Plans**: TBD

### Phase 3: DSL, Supervisor, Mix Tasks, and Config

**Goal**: A developer can define a projector with `use Orkestra.Projector`, start it under the Projection Supervisor, run per-projection migrations independently, and trigger a full rebuild — and the `:orkestra` config key is correct throughout
**Depends on**: Phase 2
**Requirements**: PROJ-01, PROJ-05, MIG-02, MIG-03, MIG-04, RBLD-01, RBLD-02, CFG-01, CFG-02, CFG-03
**Success Criteria** (what must be TRUE):

  1. A developer defines a projector with `use Orkestra.Projector` and `project EventType, fn event, multi -> ... end`; the projector starts, subscribes, and processes events without any additional boilerplate
  2. `Orkestra.Projection.Supervisor` starts all configured projectors under a one_for_one strategy; one projector crashing or halting does not affect others
  3. `mix orkestra.projection.migrate <name>`, `mix orkestra.projection.rollback <name>`, and `mix orkestra.projection.drop <name>` each operate exclusively on the named projection's isolated migration history and tables, leaving all other projections untouched
  4. `mix orkestra.projection.rebuild <name>` resets the read model and checkpoint, replays the full event stream from position zero in a single gap-free catch-up pass, and transitions to live
  5. The `:ultimus` config key bug is fixed (→ `:orkestra`); optional Ecto/Postgrex deps are declared following the existing `:amqp`/`:spear` optional-dep pattern; per-projection Repo config is documented

**Plans**: TBD
**UI hint**: no

### Phase 4: Telemetry & Observability

**Goal**: Every event processed by a projector emits an OTel span; lag, rebuild progress, errors, and halts are exposed as metrics so operators can alert on and diagnose projection health
**Depends on**: Phase 3
**Requirements**: TEL-01, TEL-02, TEL-03, TEL-04
**Success Criteria** (what must be TRUE):

  1. Each event processed by a projector emits an OpenTelemetry span consistent with existing `Orkestra.Telemetry` conventions (same attribute naming, same span wrapping pattern)
  2. A positional lag metric (head position minus checkpoint position) is emitted per projector and readable by an observability tool; it is zero when the projector is fully caught up
  3. A rebuild progress metric (separate from live lag) is emitted during a rebuild and reflects percentage of total events replayed
  4. A halted projector emits a telemetry event/counter on halt; the halt status flag is persisted so it remains visible after the GenServer has stopped

**Plans**: TBD

### Phase 5: MCP Integration and Query Helpers

**Goal**: Developers using orkestra_mcp can scaffold new projections with a generator command, inspect existing projections via MCP resources, and optionally use a generated Queries module for common read patterns
**Depends on**: Phase 4
**Requirements**: READ-02, MCP-01, MCP-02, MCP-03
**Success Criteria** (what must be TRUE):

  1. `gen_projection` MCP tool scaffolds a projector module plus its isolated migration file; `gen_read_model` scaffolds the Ecto schema and migration
  2. MCP introspection resources (`list_projections`, `domain_map`) surface all defined projectors and their associated read models alongside existing aggregates and event handlers
  3. An optional generated `Queries` module per read model exposes at minimum `list/1` (paged) and `get_by/2`; a developer opting in gets working query helpers without writing boilerplate

**Plans**: TBD

## Progress

**Execution Order:**
Phases execute in numeric order: 1 → 2 → 3 → 4 → 5

| Phase | Plans Complete | Status | Completed |
|-------|----------------|--------|-----------|
| 1. Foundations | 2/3 | In Progress|  |
| 2. Projector GenServer + Ecto Adapter | 0/TBD | Not started | - |
| 3. DSL, Supervisor, Mix Tasks, and Config | 0/TBD | Not started | - |
| 4. Telemetry & Observability | 0/TBD | Not started | - |
| 5. MCP Integration and Query Helpers | 0/TBD | Not started | - |
