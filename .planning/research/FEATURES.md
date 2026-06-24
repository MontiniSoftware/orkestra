# Feature Research

**Domain:** Event-sourced projection / read-model subsystem (Elixir CQRS library)
**Researched:** 2026-06-24
**Confidence:** MEDIUM (cross-checked against Commanded ecosystem docs + community sources; websearch confidence LOW, context7 MEDIUM, cross-verification elevates overall to MEDIUM)

---

## Scope Note

This document covers only the **read/projection side** of Orkestra. The write side (aggregates, commands, events, message bus, event store) is existing and validated. Research benchmarks against the dominant Elixir CQRS library (Commanded + commanded-ecto-projections) to identify gaps, parity, and opportunities.

---

## Feature Landscape

### Table Stakes (Users Expect These)

Features users assume exist. Missing these = the projection subsystem is not usable.

| Feature | Why Expected | Complexity | Notes |
|---------|--------------|------------|-------|
| **Projector definition via macro/behaviour** | Every CQRS library provides a DSL for mapping events → read-model writes. Developers won't hand-roll GenServer subscriptions. | MEDIUM | Use `use Orkestra.Projector` + `project EventType, fn event, multi -> ... end` DSL modeled on Commanded's `project/3`. Wraps Ecto.Multi per event. |
| **Async consumption via message bus** | Write path must be decoupled from read path. In-process sync projections break on distributed deployments and cause write-path failures from constraint violations. | LOW | Reuse the existing `MessageBus` abstraction (PubSub or RabbitMQ). Projector is a supervised consumer, not inline in `Aggregate.Root`. |
| **Per-projector checkpoint persistence** | Without checkpoints, a projector restart replays all events from the beginning. Users expect resume-from-last-position. | MEDIUM | Store `{projector_name, last_event_position}` in Postgres (same Ecto repo). Checkpoint update and read-model write are in the same transaction — the only way to guarantee idempotency. |
| **Resume after restart** | Corollary of checkpoint: the projector reads its persisted checkpoint on startup and subscribes from that position. | LOW | Depends on checkpoint persistence (above). Read checkpoint → pass to message bus subscription as `start_from` equivalent. |
| **Full rebuild / replay from event store** | Read models must be rebuildable when schema changes or bugs are found. Without rebuild, users can't evolve read models safely. | HIGH | Drop read-model tables + checkpoint → replay all events from event store head position 0. Requires direct event store access (not just message bus), since the bus does not replay history. |
| **In-order error handling: retry then halt** | At-least-once delivery means retries happen. Skipping-ahead on error creates gaps / corrupt read models. Users must be able to trust read-model consistency. | HIGH | On error: retry N times (configurable, reuse orkestra retry semantics) → on exhaustion, park event to dead-letter store and **halt that projector** (no further events consumed). Configurable per-projector. This is stricter than Commanded (which offers `:skip` as a return). |
| **Dead-letter / park semantics** | Halting a projector without persistence means the problematic event is lost after restart. Users expect to inspect and re-drive failed events. | MEDIUM | Persist parked events (projector_name, event_position, error, attempts, parked_at). Provide a way to drain/retry the dead-letter or discard and resume. |
| **Ecto-backed storage for Postgres adapter** | Elixir standard. Developers expect their read models to be Ecto schemas, queryable with Ecto.Query. | LOW | Each projector declares its read-model schema(s). Writes use Ecto.Multi. Developers query via standard `Repo.all/2`, `Repo.get/3`, etc. |
| **Idempotent event processing** | Message bus guarantees at-least-once, not exactly-once. Duplicate event delivery must not double-apply writes. | MEDIUM | Checkpoint position tracked atomically with the write in the same Ecto transaction. Stale/duplicate events (position <= last checkpoint) are ignored before processing. |
| **Supervised lifecycle (OTP)** | Projectors must restart on crash, integrate with application supervision trees. | LOW | Projector is a GenServer (consistent with existing `EventHandler` pattern). Users add it to their supervision tree like any other Orkestra process. |

### Differentiators (Competitive Advantage)

Features that set Orkestra apart from the Commanded ecosystem. These are the gaps in the state of the art.

| Feature | Value Proposition | Complexity | Notes |
|---------|-------------------|------------|-------|
| **Per-projection isolated migrations** | Commanded-ecto-projections uses the application's shared Ecto repo migration history — there's no way to migrate, rollback, or drop a single projection independently. Orkestra's isolated migrations let a projection own its schema fully: run migrations, roll back, drop, and rebuild without touching other projections or the main app schema. | HIGH | Each projector configures its own `Ecto.Repo` (or a logical schema prefix / migration table prefix). Migration runner (`Orkestra.Projector.Migrate`, `Orkestra.Projector.Rollback`, `Orkestra.Projector.Drop`) operates exclusively on that projection's migration history. This is the "graceful migrations" goal. Depends on Ecto migration API. |
| **Park-and-halt error mode (not skip)** | Commanded's `error/3` offers `:skip` (swallow the event and advance) — a footgun that silently corrupts read models. Orkestra's default is park-then-halt: the problematic event is preserved in a dead-letter store and the projector stops advancing until an operator intervenes. Users get safety by default with an explicit escape hatch. | MEDIUM | Differentiates on correctness guarantee. Configurable: `on_error: :halt` (default) vs `on_error: :skip` for projectors where losing an event is acceptable. |
| **Projection lag telemetry** | No Elixir CQRS library ships first-class lag metrics. Lag = `head_event_position - checkpoint_position`. This is the single most operationally useful metric for a projection subsystem. | MEDIUM | Emit as OTel metric (counter/gauge): `orkestra.projection.lag`, `orkestra.projection.checkpoint`, `orkestra.projection.events_processed`, `orkestra.projection.events_failed`, `orkestra.projection.rebuild_progress`. One OTel span per event processed. Reuse existing `Telemetry` module conventions. |
| **Rebuild progress reporting** | Rebuilds can take minutes or hours on large event stores. Without progress reporting, users have no idea if a rebuild is stalled or near completion. | LOW | During rebuild, emit `orkestra.projection.rebuild_progress` with `{events_done, total, percent}`. Exposed via the telemetry module (same OTel pattern). |
| **Optional generated `Queries` module** | Ecto-first access is idiomatic, but boilerplate list/get operations are tedious. A generated `Queries` module per read model (paged `list/1`, `get_by/2`) reduces friction for common patterns without hiding Ecto. | MEDIUM | `use Orkestra.Projector.Queries, schema: MyApp.ReadModels.OrderView, repo: MyApp.ProjectionRepo` generates `list(page: 1, per_page: 20)` and `get_by(id: uuid)` as thin Ecto wrappers. Prototype and refine — not a replacement for Ecto.Query. |
| **MCP code generation (`gen_projection`)** | Consistent with existing `gen_aggregate`, `gen_command` tools in orkestra_mcp. Removes boilerplate for common projection patterns. | MEDIUM | Generates: projector module, read-model Ecto schema, migration file, optional Queries module, and test stub. Introspection: projections surfaced in `domain_map` and `list_projections` resources. |
| **Elasticsearch adapter: zero-downtime reindex via alias swap** | ES projections are complex to evolve safely. The alias-swap pattern (build new versioned index → replay → atomic alias switch → drop old) gives zero-downtime schema evolution with event-sourced replay as the source of truth. No Elixir library ships this. | HIGH | `Orkestra.Projector.Elasticsearch`: `index_mapping/0` callback defines ES mapping. Versioned index naming (`my_index_v2`). `reindex/0` replays from event store into new index. `swap_alias/0` atomically redirects the alias. `bulk_index/1` for batch ingest during replay. This is a follow-up milestone adapter — core abstraction must not preclude it. |
| **Elasticsearch adapter: bulk indexing during replay** | Naive per-event ES writes during replay are 10–100x slower than bulk. Without bulk support, large-event-store replays are impractical. | MEDIUM | Buffer events during replay phase, flush in configurable batch sizes (e.g., 500 docs) using ES bulk API. Switch to per-event indexing once caught up with live stream. |

### Anti-Features (Commonly Requested, Often Problematic)

Features that seem good but create correctness or complexity problems. Explicitly avoid these.

| Feature | Why Requested | Why Problematic | Alternative |
|---------|---------------|-----------------|-------------|
| **Synchronous (inline) projections in the command path** | Feels simpler — "update the read model in the same transaction as the command." | Database constraint violations in the projection roll back the command's events. Write and read sides become coupled. Breaks on distributed message bus (RabbitMQ). Standard CQRS wisdom: async projections + eventual consistency is correct. | Async projections via message bus + replay. If strong read-after-write consistency is needed, use `:strong` consistency mode (block command dispatch until handler ack) — but do not merge write and read transactions. |
| **Skip-on-error as the default behavior** | "Don't let one bad event stall the whole pipeline." | Silently corrupts the read model by creating gaps. The read model drifts from the true event history. Operators don't know a problem occurred. | Park-and-halt: preserve the bad event in dead-letter, stop the projector, alert via telemetry. An operator can fix the projector code, drain the dead-letter, and resume. |
| **Uniform cross-backend query API (SQL + ES + Mongo under one interface)** | Seems like a clean abstraction. | SQL (Ecto.Query), Elasticsearch (DSL + scores + aggregations), and MongoDB (document queries) have fundamentally different semantics. A leaky abstraction that covers all three poorly helps no one. | Per-adapter idiomatic query APIs. Ecto-first for Postgres, ES query DSL for Elasticsearch, Mongo query for MongoDB. The optional `Queries` module is adapter-specific, not cross-backend. |
| **Shared migration repo across all projections** | Feels simpler to run one `mix ecto.migrate`. | A migration failure in one projection blocks all others from migrating. Projections cannot be dropped/rebuilt independently. Read-model evolution becomes tangled with app schema. | Per-projection isolated migration table. Each projector migrates independently. Provide a `mix orkestra.projector.migrate ProjectorName` task. |
| **In-memory projections as the primary pattern** | Useful for tests; sometimes requested for low-latency "live" read models. | State is lost on restart. Requires full replay on every boot. Does not compose with the checkpoint/rebuild system. | In-memory projections are acceptable for tests only (using InMemory event store). For production, always persist. |
| **Fully normalized read-model schemas** | Habits from ORM-first development. | JOINs at query time destroy the performance benefit of having a read model. Projections exist precisely to pre-compute denormalized query shapes. | Design projections for query patterns (one record = one view). Embrace redundancy. Use Ecto schemas that match what the query needs, not third normal form. |

---

## Feature Dependencies

```
[Async consumption via message bus]
    └──requires──> [Supervised lifecycle (OTP)]

[Per-projector checkpoint persistence]
    └──requires──> [Ecto-backed storage]
    └──enables──>  [Resume after restart]
    └──enables──>  [Idempotent event processing]

[Full rebuild / replay]
    └──requires──> [Per-projector checkpoint persistence]  (reset checkpoint on rebuild start)
    └──requires──> [Event store direct read access]        (bus does not replay history)
    └──enhances──> [Per-projection isolated migrations]    (drop + migrate + replay)

[In-order error handling: retry then halt]
    └──requires──> [Dead-letter / park semantics]          (halt needs somewhere to put the event)
    └──requires──> [Per-projector checkpoint persistence]  (halt must not advance checkpoint)

[Per-projection isolated migrations]
    └──requires──> [Ecto-backed storage]
    └──enhances──> [Full rebuild / replay]                 (drop schema → migrate → replay)

[Optional generated Queries module]
    └──requires──> [Ecto-backed storage]
    └──enhances──> [Projector definition via macro/behaviour]

[Projection lag telemetry]
    └──requires──> [Per-projector checkpoint persistence]  (checkpoint position is needed to compute lag)
    └──requires──> [Event store head position API]         (need head to compute lag = head - checkpoint)

[Rebuild progress reporting]
    └──requires──> [Full rebuild / replay]

[MCP gen_projection]
    └──requires──> [Projector macro/behaviour]             (generates conforming module)
    └──requires──> [Per-projection isolated migrations]    (generates migration scaffold)
    └──enhances──> [Optional generated Queries module]     (optionally generates Queries module)

[ES adapter: zero-downtime alias swap]
    └──requires──> [Full rebuild / replay]                 (replay into new index is the rebuild)
    └──requires──> [ES bulk indexing]                      (replay at scale needs batching)
    └──requires──> [Core projector abstraction]            (adapter plugs into shared lifecycle)

[ES adapter: bulk indexing]
    └──requires──> [Async consumption via message bus]
    └──enhances──> [ES adapter: zero-downtime alias swap]
```

### Dependency Notes

- **Checkpoint persistence requires atomic Ecto transaction with write:** The checkpoint update and read-model mutation must happen in the same `Ecto.Multi` transaction. If they're separate, a crash between them causes either duplicate writes (if checkpoint is written last) or missed writes (if checkpoint is written first). This is the foundational correctness constraint.
- **Full rebuild requires event store access, not just message bus:** The message bus only delivers live/recent events. To replay from position 0, the projector must call the event store directly (same `EventStore` behaviour that aggregates use). The message bus subscription then takes over at the position where the event store replay ended.
- **Park-and-halt requires dead-letter persistence before halting:** The event must be written to dead-letter storage in the same transaction as the checkpoint freeze (or before halting). A crash between parking and halting must not lose the parked event.
- **ES alias swap conflicts with single-active-projector assumption:** During blue-green rebuild for ES, two projector instances logically run (old live, new rebuilding). The lifecycle must support a "shadow rebuild" mode that doesn't conflict with the primary projector's checkpoint. This is a design constraint for the ES adapter milestone.

---

## MVP Definition

### Launch With (v1 — this milestone, Postgres/Ecto adapter)

Minimum viable projection subsystem. All table stakes + the key differentiators that justify building Orkestra over using Commanded directly.

- [ ] **Projector macro/behaviour** — `use Orkestra.Projector` with `project/2` DSL (event module → Ecto.Multi function)
- [ ] **Async consumption via message bus** — reuse existing `MessageBus` abstraction; projector is a supervised GenServer consumer
- [ ] **Per-projector checkpoint persistence** — checkpoint table in Postgres, updated atomically with read-model write
- [ ] **Resume after restart** — read checkpoint on init, pass to message bus `start_from`
- [ ] **Full rebuild / replay** — drop tables + checkpoint → replay from event store → hand off to bus at caught-up position
- [ ] **In-order error handling: retry → park → halt** — configurable max_retries per projector; dead-letter table; halt on exhaustion
- [ ] **Dead-letter / park table** — Postgres table with (projector_name, event_position, event_data, error, attempts, parked_at)
- [ ] **Per-projection isolated migrations** — each projector declares its own migration module; `mix orkestra.projector.migrate`, `rollback`, `drop` tasks
- [ ] **Ecto-first read access** — no framework needed; developers query their schemas with `Repo.all/2`, etc.
- [ ] **Projection lag + checkpoint telemetry** — OTel spans per event; lag gauge, checkpoint gauge, events_processed counter, events_failed counter
- [ ] **Rebuild progress telemetry** — rebuild progress gauge (events_done/total)
- [ ] **Config cleanup (`:ultimus` → `:orkestra` bug fix)** — fix config key bug; establish clean per-projection repo config story

### Add After Validation (v1.x)

- [ ] **Optional generated `Queries` module** — `list/1` paged, `get_by/2`; generated via `use Orkestra.Projector.Queries`; prototype and refine based on real usage
- [ ] **MCP `gen_projection` / `gen_read_model`** — code generator for projector + schema + migration + optional Queries module; introspection in `domain_map` and `list_projections` resources
- [ ] **Dead-letter drain / resume UI** — mix task or MCP tool to inspect parked events, retry or discard, and resume halted projector

### Future Consideration (v2+ — subsequent milestones)

- [ ] **MongoDB adapter** — projector storage adapter for MongoDB; reuses shared lifecycle, adds Mongo-idiomatic writes and queries
- [ ] **Elasticsearch adapter: index mappings + versioned index naming** — `index_mapping/0` callback; versioned suffix naming convention
- [ ] **Elasticsearch adapter: bulk indexing during replay** — buffer + flush in configurable batch sizes during catch-up
- [ ] **Elasticsearch adapter: zero-downtime alias swap** — blue-green rebuild via alias; replay into shadow index; atomic alias swap on catch-up
- [ ] **Elasticsearch adapter: search query helpers** — ES-idiomatic `Queries` module (search by field, full-text, aggregations)

---

## Feature Prioritization Matrix

| Feature | User Value | Implementation Cost | Priority |
|---------|------------|---------------------|----------|
| Projector macro/behaviour | HIGH | MEDIUM | P1 |
| Async consumption via message bus | HIGH | LOW | P1 |
| Per-projector checkpoint persistence | HIGH | MEDIUM | P1 |
| Resume after restart | HIGH | LOW | P1 |
| Full rebuild / replay | HIGH | HIGH | P1 |
| In-order error: retry → park → halt | HIGH | HIGH | P1 |
| Dead-letter / park table | HIGH | MEDIUM | P1 |
| Per-projection isolated migrations | HIGH | HIGH | P1 |
| Ecto-first read access | HIGH | LOW | P1 |
| Lag + checkpoint telemetry | MEDIUM | MEDIUM | P1 |
| Rebuild progress telemetry | MEDIUM | LOW | P1 |
| Config bug fix (`:ultimus` → `:orkestra`) | MEDIUM | LOW | P1 |
| Optional generated Queries module | MEDIUM | MEDIUM | P2 |
| MCP gen_projection / introspection | MEDIUM | MEDIUM | P2 |
| Dead-letter drain/resume tooling | MEDIUM | LOW | P2 |
| MongoDB adapter | MEDIUM | HIGH | P3 |
| ES adapter: index mappings + versioning | HIGH (ES users) | HIGH | P3 |
| ES adapter: bulk indexing | HIGH (ES users) | MEDIUM | P3 |
| ES adapter: zero-downtime alias swap | HIGH (ES users) | HIGH | P3 |
| ES adapter: search query helpers | MEDIUM (ES users) | MEDIUM | P3 |

**Priority key:**
- P1: Must have for this milestone launch
- P2: Should have; add in v1.x after core is validated
- P3: Future milestone (MongoDB or Elasticsearch adapter sprints)

---

## Competitor Feature Analysis

| Feature | Commanded (Elixir) | Our Approach |
|---------|-------------------|--------------|
| Projector DSL | `project EventType do ... end` via Ecto.Multi | Same pattern; `project EventType, fn event, multi -> ... end` |
| Checkpoint persistence | Atomic with write in same transaction | Same; table per projector not shared |
| Error handling | `error/3` → `:retry`, `:skip`, `{:stop, reason}` — `:skip` is the escape hatch | `error/3` → `:retry`, `{:park_and_halt, reason}` — halt is default, skip requires explicit opt-in |
| Rebuild / reset | `before_reset/0` callback; drop + replay | `Orkestra.Projector.rebuild/1` — drop schema + checkpoint → replay from event store |
| Per-projection migrations | Not supported — shared app Ecto repo | Per-projection isolated migration history; independent migrate/rollback/drop |
| Lag telemetry | Not built-in | First-class OTel gauge: lag = head_position - checkpoint |
| Rebuild progress | Not built-in | OTel gauge: rebuild_progress = events_done/total |
| Generated query helpers | Not built-in | Optional `Queries` module (list/1, get_by/2) |
| MCP code generation | Not applicable | `gen_projection`, `gen_read_model` in orkestra_mcp |
| Elasticsearch adapter | Not available | Future milestone: mapping + versioned reindex + alias swap + bulk |
| MongoDB adapter | Not available | Future milestone |

---

## Sources

- [commanded-ecto-projections (GitHub)](https://github.com/commanded/commanded-ecto-projections) — projection DSL, Ecto.Multi, checkpoint, error/3 — MEDIUM confidence
- [Commanded.Event.Handler (HexDocs)](https://commanded.hexdocs.pm/Commanded.Event.Handler.html) — error/3 return values, start_from, consistency modes — MEDIUM confidence
- [Projections and Read Models in Event-Driven Architecture (event-driven.io)](https://event-driven.io/en/projections_and_read_models_in_event_driven_architecture/) — left-fold pattern, idempotency, blue-green rebuild, truncate-and-rebuild — LOW confidence (web)
- [Some CQRS and Event Sourcing Pitfalls (AxonIQ)](https://www.axoniq.io/blog/some-cqrs-and-event-sourcing-pitfalls) — synchronous projection risks, normalization anti-pattern, CUD event pitfall — LOW confidence (web)
- [Zero Downtime Reindex in Elasticsearch](https://tuleism.github.io/blog/2021/elasticsearch-zero-downtime-reindex/) — alias swap, versioned index naming — LOW confidence (web)
- [Blue-Green Deployment in Elasticsearch (widhianbramantya.com)](https://widhianbramantya.com/elasticsearch/blue-green-deployment-in-elasticsearch-safe-reindexing-and-zero-downtime-upgrades/) — blue-green pattern, dual write, atomic alias swap — LOW confidence (web)
- [Kafka Consumer Lag Monitoring (Sematext)](https://sematext.com/blog/kafka-consumer-lag-offsets-monitoring/) — lag metric definition (head - checkpoint), alert patterns — LOW confidence (web, adapted to ES context)
- [Elixir Commanded (Curiosum)](https://curiosum.com/blog/segregate-responsibilities-with-elixir-commanded) — practical Commanded usage patterns — LOW confidence (web)
- [Building Conduit (Leanpub)](https://leanpub.com/buildingconduit/read) — commanded-ecto-projections in practice — LOW confidence (web)
- [CQRS and Event Sourcing: Implementation Guide (knowledgelib.io)](https://knowledgelib.io/software/system-design/cqrs-event-sourcing/2026) — anti-patterns: idempotency, DLQ, out-of-order events — LOW confidence (web)

---

*Feature research for: Orkestra projection / read-model subsystem*
*Researched: 2026-06-24*
