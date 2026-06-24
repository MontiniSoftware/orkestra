# Phase 2: Projector GenServer + Ecto Adapter - Context

**Gathered:** 2026-06-24
**Status:** Ready for planning

<domain>
## Phase Boundary

This phase delivers the **runtime** of the projection subsystem: a projector
GenServer that processes events end-to-end and a Postgres/Ecto Storage adapter.
Building on Phase 1's pure pieces (`Storage` behaviour, `Projector.Lifecycle`,
`Checkpoint`/`DeadLetter` schemas, `Migration`), the GenServer subscribes from
its persisted checkpoint, catches up, goes live, applies events strictly in
order, retries with backoff, parks exhausted events to dead-letter, and halts —
committing the checkpoint and read-model writes atomically in a single
`Ecto.Multi` transaction on a fully isolated per-projection Repo.

Out of scope (later phases): the `use Orkestra.Projector` DSL, supervisor, mix
tasks, config key wiring (Phase 3); telemetry spans/metrics (Phase 4); MCP
generators (Phase 5); auto-resume after halt.

</domain>

<decisions>
## Implementation Decisions

### Subscription & Catch-up → Live
- Consume events via the adapter's **unified push subscription** — `subscribe_from_position` replays history from the checkpoint then streams live events to the GenServer as process messages, giving a single code path (consistent with Phase 1 D-03).
- Process events **strictly sequentially**, one event per `handle_info`, using the GenServer mailbox as the in-order queue. No concurrent application to the same read model (success criterion 2).
- No hard catch-up/live state machine in v1 — the continuous ordered stream is treated uniformly. A `caught_up?` flag may be tracked only as a hook for later telemetry (Phase 4); it does not gate processing.
- Subscribe from the checkpoint's `last_position` using exclusive `>` semantics (Phase 1 D-01), so a restart resumes at the next unprocessed event (success criterion 1). Default `last_position` is `-1`, i.e. replay from position 0.

### Ecto Repo & Atomic Transaction
- The checkpoint update is written **inside the same `Ecto.Multi`** as the read-model writes, via `Multi.insert` with `on_conflict` upsert keyed on the `projector_name` unique index (replacing `last_position`/`halted`/`updated_at`).
- The checkpoint, dead_letter, and read-model tables all live in the **same per-projection Repo**, so the one transaction spans all of them — this is what makes STORE-03's atomic co-write possible. A shared/global repo was rejected because it would break atomicity.
- The GenServer receives its **Repo module via projector config/opts** at start (not derived implicitly from the name).
- **One `Ecto.Multi` transaction per event** — the simplest construction that satisfies STORE-03. Batching multiple events per transaction is deferred (a throughput optimization, not a correctness need in v1).
- A simulated crash between the checkpoint write and the read-model write must not produce a double-write or missed-write on restart (success criterion 3) — guaranteed by the single-transaction commit.

### Halt & Error Behavior
- On retry exhaustion the GenServer persists `halted=true` to the checkpoint **and** writes the event to the dead_letter store, then **stays alive in an idle halted state** (it does not crash). This keeps the halt visible and avoids supervisor restart loops (success criterion 4, ERR-03/ERR-04).
- Retries are scheduled with `Process.send_after` using `Lifecycle.next_delay/2` backoff; the same failing event is re-attempted (no blocking sleep that would stall the process).
- The dead_letter insert and the checkpoint `halted=true` update commit in a **single transaction** (atomic halt).
- Resume-after-halt is **out of scope** for Phase 2 — a halted projector stays parked until a later phase / manual intervention resolves it.

### Test Strategy (Ecto/Postgres adapter)
- Test against **real Postgres** via `Ecto.Adapters.SQL.Sandbox`. The Storage behaviour and `Lifecycle` stay pure/unit-testable, but the Postgres adapter and the atomic-commit GenServer tests genuinely need a database.
- DB-dependent tests are **tagged** (e.g. `@tag :postgres`) so they are runnable locally/CI but skippable when no database is present — keeping the existing fast async suite green without Postgres.
- The crash/restart end-to-end test (success criterion 3) uses the **InMemory EventStore + a real test Repo** to simulate a crash between the checkpoint and read-model writes and assert no double/missed write on restart.
- Use `SQL.Sandbox` in manual/shared mode so the GenServer process can share the test transaction/ownership.

### Claude's Discretion
- Exact GenServer module name(s) and internal state shape.
- Postgres adapter module name and how `write/4` ops compose into the `Ecto.Multi` (the concrete "Multi-shaped ops" representation from Phase 1 D-06).
- Naming of the `caught_up?` flag and whether to include it at all in Phase 2.
- Test helper/fixture structure, example read-model schema used in tests.
- Backoff defaults already set in `Lifecycle` may be tuned.

</decisions>

<code_context>
## Existing Code Insights

### Reusable Assets
- `Orkestra.Projection.Storage` (`lib/orkestra/projection/storage.ex`) — behaviour with `write/4` returning opaque Multi-shaped `ops` and `reset/2`. The Postgres adapter implements this.
- `Orkestra.Projector.Lifecycle` (`lib/orkestra/projector/lifecycle.ex`) — pure `next_delay/2`, `classify/2`, `should_halt?/2` for retry/park/halt decisions. The GenServer calls these.
- `Orkestra.Projection.Checkpoint` and `Orkestra.Projection.DeadLetter` Ecto schemas — both wrapped in `Code.ensure_loaded?(Ecto.Schema)` guards so the lib compiles without Ecto. Checkpoint has `projector_name`, `last_position` (default -1), `halted`, `halted_at`, `updated_at`.
- `Orkestra.Projection.Migration` — `up/0`/`down/0` (Oban-style) owning the DDL for `projection_checkpoints` (and dead_letter); the consumer wrapper migration delegates to it and controls timing/Repo.
- `Orkestra.EventStore` behaviour — `subscribe_from_position/3` (exclusive `>` semantics, push delivery) and `Orkestra.EventStore.InMemory` (gap-free global counter, push subscription) for tests.

### Established Patterns
- Optional deps guarded with `Code.ensure_loaded?` so the core library compiles without amqp/spear/ecto (the projection Ecto modules follow this).
- Behaviour + per-adapter implementation split (EventStore, MessageBus) — Storage follows the same shape.
- Error tuples `{:ok, _}` / `{:error, reason}`; bang variants raise. GenServers use structured Logger metadata with `orkestra: :domain_area` tags.
- OpenTelemetry spans wrap critical paths (deferred to Phase 4 for projectors but keep boundaries clean).

### Integration Points
- GenServer subscribes through `EventStore.subscribe_from_position/3` (InMemory in tests; EventStoreDB in prod).
- GenServer commits via the per-projection `Ecto.Repo` passed in opts; merges `Storage.write/4` ops with the checkpoint upsert into one `Ecto.Multi`.
- `Migration.up/0` provisions the checkpoint/dead_letter tables in that same Repo.

</code_context>

<specifics>
## Specific Ideas

- The atomic-commit invariant (checkpoint + read-model in one `Ecto.Multi`) is the
  non-negotiable correctness centerpiece — the crash-between-writes test is the
  binding proof.
- Halt must be a persisted, visible state — never a silent stall.

</specifics>

<deferred>
## Deferred Ideas

- `use Orkestra.Projector` DSL, Projection Supervisor, mix tasks, `:orkestra` config wiring → Phase 3.
- Telemetry spans, lag/rebuild/error/halt metrics → Phase 4.
- MCP generator + Queries module → Phase 5.
- Auto-resume / dead-letter replay after halt → later phase.
- Batched multi-event transactions (throughput) → future optimization.

</deferred>
