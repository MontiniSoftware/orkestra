# Phase 1: Foundations - Context

**Gathered:** 2026-06-24
**Status:** Ready for planning

<domain>
## Phase Boundary

Phase 1 delivers the **dependency-light correctness contracts and data structures** that every later phase of the projection/read-model subsystem builds on. Concretely, four deliverables:

1. `Orkestra.Projection.Storage` behaviour — the pluggable storage-adapter contract (`write/4`, `reset/2`).
2. `Orkestra.Projection.Checkpoint` and `Orkestra.Projection.DeadLetter` Ecto schemas, with **Orkestra-owned** migrations that create the `projection_checkpoints` and `projection_dead_letters` tables.
3. `Orkestra.Projector.Lifecycle` pure functions — error classification, retry-delay computation, and the halt decision (no I/O; unit-testable).
4. A new `Orkestra.EventStore.subscribe_from_position/3` callback on the EventStore behaviour, implemented by both the InMemory and EventStoreDB adapters, with InMemory delivering events strictly in order during tests.

This phase defines **contracts**, not the GenServer that consumes them (that is Phase 2). It must stay buildable without committing the runtime/atomic-write behaviour, while leaving room for Phase 2's atomic checkpoint co-write.

</domain>

<decisions>
## Implementation Decisions

### Position semantics (subscribe_from_position/3 + checkpoint)
- **D-01:** A projection "position" is a **non-negative monotonic integer**, adapter-provided. The InMemory adapter generates a gap-free global counter (0, 1, 2, …) across all events; the EventStoreDB adapter maps it to the `$all` stream commit position (monotonic but *not* gap-free). The contract is "monotonic integer," not "gap-free."
- **D-02:** The checkpoint stores this integer position directly (single comparable column), so positional lag (`head − checkpoint`, TEL-02) is plain integer arithmetic that works identically for both adapters.

### InMemory subscription delivery
- **D-03:** The InMemory adapter delivers events via **process messages (push)**: it tracks subscriber pids, replays history from the requested position on subscribe, then pushes ordered messages to subscribers on each append. This mirrors EventStoreDB's push-subscription model so the Phase 2 Projector GenServer codes against **one** delivery model. Strict in-order, deterministic delivery in tests is the binding success criterion.

### Error classification & retry (Projector.Lifecycle)
- **D-04:** **Uniform retry with exponential backoff.** Every error retries up to `max_retries` with exponential backoff (base × 2^attempt, capped), then the event is parked to the dead-letter store and the projector halts. No transient/permanent error classification in v1 (matches the existing `attempts <= max_retries` model; backoff is the new part). Retry count/backoff are configurable per projector.
- **D-05:** `Lifecycle` is pure: it classifies the outcome (retry vs park), computes the next delay, and decides halt — all as return values with no I/O, so it is fully unit-testable.

### Storage write contract (forward-compat with Phase 2 atomic co-write)
- **D-06:** `Storage.write/4` **returns Ecto.Multi-shaped write operations** — a description of the read-model writes that the Postgres adapter composes into a single `Ecto.Multi` together with the checkpoint update (enabling STORE-03's atomic co-write in Phase 2). The "ops" abstraction must stay generic enough that future Mongo/ES adapters (which have no `Ecto.Multi`) can implement `write/4` their own idiomatic way. The shared lifecycle owns *when* to write + checkpoint; the adapter owns *how* to commit.

### Claude's Discretion
- Exact arity/argument order and naming of `subscribe_from_position/3` (e.g. which args are position / subscriber / opts) — pick the shape that best fits the push model and existing EventStore conventions.
- Exact column set/types of the `Checkpoint` and `DeadLetter` schemas beyond the fields mandated by ERR-02 (projector, position, event, error, attempts, timestamp) and ERR-04 (persisted halted status).
- Concrete representation of the "Multi-shaped ops" returned by `write/4`.
- Backoff base/cap defaults.

</decisions>

<canonical_refs>
## Canonical References

**Downstream agents MUST read these before planning or implementing.**

### Milestone scope & decisions
- `.planning/PROJECT.md` — milestone scope, Key Decisions table (async projections, per-projection isolation, error handling = retry→park→halt).
- `.planning/REQUIREMENTS.md` §"Storage Abstraction", §"Error Handling", §"Telemetry" — Phase 1 covers STORE-01, ERR-01, ERR-02, ERR-03, PROJ-02.
- `.planning/ROADMAP.md` §"Phase 1: Foundations" — goal, success criteria, and the explicit deliverable list.

### Existing code to extend / mirror
- `lib/orkestra/event_store.ex` — the EventStore behaviour to extend with `subscribe_from_position/3`. NOTE: contains the `:ultimus` config-key bug (`impl/0`); the fix is scheduled CFG-01 in Phase 3, do not silently change it here unless planning decides otherwise.
- `lib/orkestra/event_store/in_memory.ex` — Agent-backed, currently stream-scoped with **no global ordering**; must gain a global monotonic counter + subscriber tracking for push delivery.
- `lib/orkestra/event_store/event_store_db.ex` — Spear adapter; `$all` + commit position is the source of the EventStoreDB position.
- `lib/orkestra/command_envelope.ex` — the existing retry model (`attempts`/`max_retries`/`retryable?`); Lifecycle's retry semantics should be consistent with it (it has no backoff today — backoff is new).
- `lib/orkestra/telemetry.ex` — OTel/span conventions to reuse later (TEL-* is Phase 4, but keep contracts compatible).

### Codebase map
- `.planning/codebase/ARCHITECTURE.md`, `.planning/codebase/CONVENTIONS.md` — behaviour + adapter patterns, error-tuple conventions, naming.

</canonical_refs>

<code_context>
## Existing Code Insights

### Reusable Assets
- **EventStore behaviour + two adapters** (`event_store.ex`, `in_memory.ex`, `event_store_db.ex`): extend, don't replace. Add `subscribe_from_position/3` as a new callback.
- **Optional-dependency pattern** (`:amqp`/`:spear` in `mix.exs`): Ecto/Postgrex follow the same approach. NOTE for planner: the Checkpoint/DeadLetter Ecto schemas cannot compile without `ecto`/`ecto_sql` on the path, so Phase 1 likely needs those optional deps declared **earlier** than CFG-03 (Phase 3) nominally schedules — a sequencing point to resolve in planning.
- **CommandEnvelope retry fields** as the shape reference for the per-projector retry config.

### Established Patterns
- Behaviours via `@callback` + adapters via `@behaviour` + `@impl true`.
- Pure functions return `:ok | {:ok, value} | {:error, reason}` with structured atom/tuple reasons.
- Adapters resolved via `Application.get_env` + `Keyword.get(:adapter, Default)`.

### Integration Points
- New `subscribe_from_position/3` is the seam the Phase 2 Projector GenServer subscribes through.
- The `Storage` behaviour is the seam the Phase 2 Ecto adapter implements.
- `projection_checkpoints` / `projection_dead_letters` are Orkestra-owned tables (distinct from per-projection read-model tables, which are isolated per MIG-01 in later phases).

</code_context>

<specifics>
## Specific Ideas

- Position = monotonic integer was chosen explicitly over an opaque adapter token to keep lag math and checkpoint storage simple and uniform across adapters; the gap-free-vs-monotonic nuance for EventStoreDB's `$all` was acknowledged and accepted.
- InMemory push delivery was chosen explicitly to give Phase 2 a single delivery model matching the real adapter, even though it requires adding subscriber tracking to the Agent-backed store.

</specifics>

<deferred>
## Deferred Ideas

- **Transient/permanent error classification** — considered for Lifecycle but deferred; v1 uses uniform retry + backoff. Revisit if park-and-halt proves too aggressive for transient infrastructure errors.
- **Pluggable backoff strategies** (fixed/linear in addition to exponential) — deferred; exponential is the v1 default.
- **Dead-letter drain/resume tooling** (ERR-05) — already a v2 item per REQUIREMENTS.md; Phase 1 only persists the parked events + halt status.

</deferred>

---

*Phase: 1-Foundations*
*Context gathered: 2026-06-24*
</content>
</invoke>
