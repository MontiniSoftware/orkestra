# Pitfalls Research

**Domain:** Event-sourced projection / read-model subsystem in Elixir (Orkestra)
**Researched:** 2026-06-24
**Confidence:** MEDIUM (multiple web sources cross-checked; Elixir-specific patterns inferred from Commanded ecosystem and general ES literature)

---

## Critical Pitfalls

### Pitfall 1: Out-of-Order Event Processing Corrupting Read Models

**What goes wrong:**
A projector processes event N+1 before event N, leaving the read model in an impossible intermediate state. This is especially likely when multiple projector instances run concurrently, or when message bus redelivery hands the same event to a different process while the original is still in-flight. The result is a read model whose fields reflect a mix of event-orderings that never existed in the write side — silent data corruption with no error raised.

**Why it happens:**
Message buses (PubSub, RabbitMQ) do not guarantee strict FIFO delivery across concurrent consumers. At-least-once delivery implies redelivery, which means two workers can hold the same event simultaneously. Orkestra's existing RabbitMQ adapter has no per-stream partition key enforcement that would pin a given stream's events to one consumer.

**How to avoid:**
- Enforce a single GenServer per projector (one consumer, one ordered queue). Do not run multiple concurrent workers for the same projector unless partitioned by stream ID.
- Process one event fully (write to DB + update checkpoint) before ACKing and picking up the next. Never prefetch more events than you can commit atomically.
- Use the event store's global sequence position as the checkpoint, not wall-clock time. Only advance the checkpoint after a confirmed write.
- For projectors that must parallelize: partition by aggregate ID so all events for a given stream go to the same worker.

**Warning signs:**
- Read model rows have field combinations that violate known invariants (e.g., `status: :shipped` but `shipped_at: nil`).
- Checkpoint advances but event counts don't match expected totals.
- Flaky tests that pass on first run but fail on replay.

**Phase to address:** Projector core lifecycle phase (checkpoint + subscription design). Get this correct before any storage adapter work.

---

### Pitfall 2: Checkpoint / Idempotency Bugs from At-Least-Once Delivery

**What goes wrong:**
An event is processed successfully (read model updated) but the checkpoint write fails or the process crashes before the checkpoint is persisted. On restart the projector reprocesses the event, applying the same mutation twice. For additive projections (e.g., incrementing a counter, appending to a list) this produces incorrect results. For overwrite-style projections it may be harmless, but developers conflate the two and assume safety.

**Why it happens:**
Checkpoint writes and read model writes are not in the same transaction. Developers write to the read model table, then separately write the checkpoint. If the process crashes between the two, the checkpoint is stale. On restart, at-least-once delivery causes the event to replay against an already-updated read model.

**How to avoid:**
- Write the read model update and the checkpoint in a single database transaction. The checkpoint row lives in the same Ecto repo as the read model, or in a shared projector-checkpoint table committed atomically.
- If the read model and checkpoint must be in different stores (e.g., read model in Redis, checkpoint in Postgres), implement idempotency at the application layer: store the last-processed event sequence number on the read model entity itself and skip events whose sequence is <= the stored position.
- Design projections to be naturally idempotent where possible (upserts keyed on aggregate ID, not blind inserts or increments).
- Never use a separate `event_id` deduplication table as the primary strategy — it grows without bound and requires separate cleanup.

**Warning signs:**
- Counter-type fields drift upward over time relative to expected domain totals.
- Duplicate rows in append-style tables.
- Checkpoint position lags behind the actual DB state after a restart.

**Phase to address:** Projector core lifecycle phase, alongside checkpoint schema design. Must be resolved before the Ecto adapter phase begins.

---

### Pitfall 3: Rebuild / Replay Race Condition — Events Skipped During Cutover

**What goes wrong:**
A rebuild is initiated: the read model is cleared and replay starts. While replay is in progress, new live events arrive. The rebuilder processes historical events up to position N; live events at positions N+1 to N+5 arrive and are processed by the live subscription path simultaneously. Then the rebuild "catches up" and processes positions N+1 to N+5 again from the event store, applying them a second time — or, worse, the live subscription marks the projector as "active" before the rebuilder finishes, and the rebuilder's late commits overwrite the live projector's correct state.

**Why it happens:**
Naive rebuild implementations have a gap between "finished replaying from store" and "switched to live subscription." There is no atomic handoff. This is compounded if the projector is not halted during rebuild, allowing the live subscription to continue processing events concurrently with the rebuilder.

**How to avoid:**
- During a rebuild: halt the live subscription first, mark the projector status as `:rebuilding`, then replay. Only after replay is complete and the checkpoint is written should the live subscription be restarted.
- Use the event store's catch-up subscription pattern instead of separate replay + live paths: one subscription that starts at position 0 and catches up to head, then seamlessly continues live. This is the correct abstraction (used by EventStoreDB's persistent subscriptions and Commanded's `EventStore.subscribe_to_all_streams`).
- Use a status flag (`idle | rebuilding | live`) persisted to the checkpoint store so that restarts during rebuild resume rather than restart from scratch.
- Do not clear the read model until the rebuild completes and the checkpoint is written. Prefer building into a shadow table and doing an atomic rename/swap.

**Warning signs:**
- Read model has data from two "eras" with inconsistent timestamps.
- Rebuild completes but some events are counted twice in aggregate fields.
- Post-rebuild queries return results that do not match event store state.

**Phase to address:** Projector core lifecycle phase (rebuild/replay correctness). This must be designed before the first storage adapter is built since all adapters share this lifecycle.

---

### Pitfall 4: Poison Events Stalling the Entire Projector

**What goes wrong:**
A single malformed or schema-incompatible event causes the projector's `handle_event/2` to crash or return an error. The projector retries the event repeatedly (correctly, per Orkestra's retry semantics), exhausts its retry budget, and parks the event to the dead-letter queue. Then — if the projector is designed to halt on DLQ — all subsequent events for that projector stop processing. The read model freezes at the position of the poison event, growing increasingly stale without any visible error in normal monitoring dashboards.

The opposite bug is equally dangerous: the projector silently catches the error and skips the event, advancing the checkpoint past it. The read model now has a gap — an entity that was never updated, or a row that was never inserted — with no record that anything was skipped.

**Why it happens:**
- Silently skipping: broad `rescue` clauses or catch-all `{:error, _}` returns in projector code that return `:ok` to the supervisor.
- Stalling without visibility: halt is correct behavior for ordering safety, but there is no alerting on "projector has been halted for 5 minutes."
- Schema drift: an event struct changes (field added/removed/renamed) but the projector code is not updated, causing pattern match failures or `nil` field access.

**How to avoid:**
- Adopt Orkestra's planned design exactly: retry → exhaust → park to dead-letter → halt projector. Never skip.
- Make halted projector status observable: emit a telemetry event when halted (`[:orkestra, :projector, :halted]`), write the halted status to the checkpoint store, and alert on it.
- Log the full event payload (or its ID and position) when parking to the DLQ. The DLQ record must contain enough to diagnose the failure.
- Add a `__handle_event__/2` wrapper that catches all exceptions and converts them to `{:error, reason}` — never let raw exceptions propagate as a control-flow mechanism.
- For schema evolution: use `defp upcast(event)` pattern to normalize old event versions before passing to the projector handler. Never pattern-match directly on event structs across versions without an upcast layer.

**Warning signs:**
- Projector checkpoint stops advancing while the event stream continues to grow.
- DLQ accumulates events for a projector but no alert fires.
- A read model silently returns stale data while the system appears healthy.

**Phase to address:** Projector core lifecycle phase (error handling design). Telemetry phase must include halted-projector alerts, not just lag metrics.

---

### Pitfall 5: Ecto Connection Pool Exhaustion During Bulk Rebuild

**What goes wrong:**
A projector rebuild replays potentially thousands or millions of events. Each event triggers an Ecto repo call. If the replay loop is concurrent (e.g., `Task.async_stream`) or if the rebuild spawns multiple parallel streams, it can exhaust the Ecto connection pool. Other parts of the application that share the pool (web requests, other projectors) start timing out. Alternatively, the rebuild uses long-running transactions to batch writes, holding connections for minutes and causing pool starvation.

**Why it happens:**
- Developers reach for `Task.async_stream` to parallelize replay for speed, without bounding concurrency against pool size.
- Rebuild uses `Repo.transaction/2` wrapping thousands of writes, holding one connection for the entire rebuild duration.
- The projector's Ecto repo shares the application pool instead of having a dedicated pool.

**How to avoid:**
- Give each projector's Ecto repo a dedicated connection pool (separate `Repo` process with its own `pool_size`). This is consistent with Orkestra's design goal of per-projection isolated Ecto repos.
- During rebuild, process events in batches using `Repo.insert_all/3` (which takes a list and issues a single `INSERT` statement) rather than one `Repo.insert/2` per event.
- Bound any parallelism: if using `Task.async_stream`, set `max_concurrency: pool_size - 1`.
- Set explicit `timeout` values on `Repo.transaction/2` during rebuild (default 60s may be too short for large batches, or too long if you want fail-fast behavior).
- Use streaming reads from the event store (the event store's `stream_from/2`) rather than loading all events into memory, then process-and-commit in fixed-size chunks.

**Warning signs:**
- `DBConnection.ConnectionError` or pool checkout timeouts during rebuild.
- Web requests slow down or time out while a rebuild is running.
- Memory spikes before `Repo.insert_all` calls (entire event batch loaded in memory).

**Phase to address:** Ecto adapter phase and rebuild/replay phase. Pool isolation design must be established in the adapter architecture before implementation.

---

### Pitfall 6: Per-Projection Migration Drift and Rollback Unsafety

**What goes wrong:**
Each projection has its own migration history (Orkestra's design goal). Over time, projection A's migrations assume certain Postgres extensions or roles exist; projection B's migrations conflict with A's table naming; or a migration for projection C is run but the corresponding projector code is on a different version. Rolling back projection C's migration after it has run removes a column that the still-running projector code is writing to, causing runtime errors.

A subtler variant: the projector code is deployed before its migration runs (column doesn't exist yet) or after the migration is rolled back (column no longer exists). Both cases cause `Postgrex.Error` on write.

**Why it happens:**
- Independent migration histories mean there is no single migration command that keeps all projections in lockstep with the application code.
- Mix release deploys code atomically but migrations are run separately; the window between "code deployed" and "migration ran" leaves projectors writing to a schema they expect to be different.
- Rollbacks are tested in development but never exercised in staging, so rollback safety is assumed rather than verified.

**How to avoid:**
- Each projection's `Repo` runs its own migrations via a dedicated Mix task (e.g., `mix orkestra.projection.migrate MyApp.OrderProjection`). Document this as the canonical deploy procedure.
- Use additive-only migrations during normal development (add columns, add tables). Never remove a column in the same migration that code depends on; instead: (1) deploy code that tolerates null/absent column, (2) run migration, (3) deploy code that requires column.
- Test rollback in CI: run migrations up, then `mix ecto.rollback`, verify the projection repo is in the expected prior state.
- Keep migration version numbers in the projector module's checkpoint metadata so it is visible which schema version a projector is running against.
- For breaking schema changes, prefer side-by-side projection versioning (build `V2` projection alongside `V1`, cut over when caught up) rather than in-place migration of a live projection.

**Warning signs:**
- `Postgrex.Error: column "x" of relation "y" does not exist` appearing after a deploy.
- A migration rollback in one projection's repo causes failures in a different projector that shares a Postgres user/schema.
- `schema_migrations` tables for different projections have gaps or out-of-order versions.

**Phase to address:** Ecto adapter phase (per-projection migration isolation design). Must be validated with a real rollback test in the test suite before shipping.

---

### Pitfall 7: Eventual Consistency / Read-After-Write Surprises for API Consumers

**What goes wrong:**
A user submits a command that is processed successfully (event appended to the store). The API returns 200. The user's next request reads from the projection-backed read model. The projection has not yet processed the event (lag of 10–500ms is typical under normal load; seconds under rebuild or high load). The read model returns stale data, making it appear as if the command had no effect. For a POST/redirect/GET flow this means a redirect to a 404 — the newly created resource does not yet exist in the read model.

**Why it happens:**
Async projections are eventually consistent by design. Developers often understand this in the abstract but do not account for it in specific API flows, especially those that use the standard synchronous request/response pattern where users expect to see their write reflected immediately.

**How to avoid:**
- Document the consistency model explicitly in Orkestra's projection framework. Projectors should expose their current checkpoint position so callers can compare it to the event position returned by the command dispatch.
- For flows that require read-after-write consistency: implement a `wait_for_projection/3` helper that polls the projector's checkpoint until it advances past the event's global position, with a configurable timeout. This is an opt-in, not the default.
- Alternatively: return the event's position from the command dispatch, and have the API layer use it to implement version-aware reads (pass the expected position as a query param; the read model returns 202 Accepted if not yet at that position).
- Set SLAs for projection lag (e.g., P99 < 500ms under normal load) and alert when breached.
- In test suites: always wait for projector catch-up before asserting on read model state. A test helper `wait_for_projection/1` prevents false-green tests masking real lag bugs.

**Warning signs:**
- Integration tests pass on their own but fail when run in parallel (race between command and read).
- Users report "I just created X but it's not showing up."
- `wait_for_projection` calls with `sleep(100)` workarounds scattered across tests.

**Phase to address:** Projector core lifecycle phase (expose checkpoint position in public API). Telemetry phase (lag SLA alerting). Test helpers should be part of the core phase delivery.

---

### Pitfall 8: Silently-Skipped Events Creating Permanent Gaps During Rebuild

**What goes wrong:**
During a rebuild, the projector is in `:rebuilding` status. A new live event arrives and is handled by the live subscription path, which checks the status and decides to skip the event (correct behavior: don't double-apply). The rebuild then finishes and the checkpoint is written. But the live event that was skipped during the rebuild window was never replayed by the rebuilder (it arrived after the rebuilder's read position) and was never applied by the live path (it was skipped). The event is permanently lost from the projection.

This is the "rebuild race condition" from pitfall 3, expressed specifically as a gap rather than a duplicate. Both are possible depending on which side wins the race.

**Why it happens:**
The "skip during rebuild" logic is a necessary safeguard against double-processing, but it creates a window where events in-flight during the cutover can be neither replayed nor applied live.

**How to avoid:**
- Use a catch-up subscription (not two separate paths) that starts at position 0 and seamlessly transitions to live events without a gap. The event store's `subscribe_to_all_streams` with a start position of `:origin` and checkpointing is the correct pattern.
- If a dual-path (replay + live) design is used anyway: implement a skip-tracking table. When a live event is skipped because status is `:rebuilding`, record the event ID in a `skipped_events` table within the same transaction. After rebuild completes, drain `skipped_events` before marking the projector `:live`.
- Never discard a skipped event silently. Log it at minimum; persist it for recovery where possible.

**Warning signs:**
- Entity count in read model differs from entity count derived from event store.
- Rebuild completes but certain aggregate IDs are missing from the projection.
- Checkpoint position equals the event store head, but some events between 0 and head are not reflected.

**Phase to address:** Projector core lifecycle phase (rebuild design). This is a design constraint that must be encoded before the lifecycle GenServer is implemented.

---

### Pitfall 9: Telemetry Lag Measurement Misimplementation

**What goes wrong:**
Lag is reported as "time since last event processed" (wall-clock delta) rather than "number of events between the projector's checkpoint position and the event store's head position." Wall-clock lag looks fine during low-traffic periods (few events per minute means lag appears 0 even if the projector is stuck) and looks alarming during high-traffic periods (many events per second means lag spikes even when the projector is healthy and keeping up).

A secondary error: lag is measured per-projector without accounting for the projector's own rebuild state. A projector in `:rebuilding` with 1 million events to process correctly has very high "lag" — this should not page the on-call engineer. The rebuild progress metric (% complete) is different from the live-lag metric.

**Why it happens:**
Lag as wall-clock delta is easy to implement (just track the timestamp of the last processed event). Positional lag requires knowing the event store's current head position, which requires an extra query to the event store on each measurement cycle.

**How to avoid:**
- Define lag as: `head_position - checkpoint_position` (event count, not time). This is meaningful at all traffic levels.
- Expose rebuild progress as a separate metric: `rebuild_events_processed / rebuild_events_total`.
- Separate the alert on live lag (SLA breach) from rebuild progress reporting (informational only).
- Emit `[:orkestra, :projector, :lag]` with a `%{projector: name, lag: N, status: :live | :rebuilding}` measurement. Alerting rules should filter on `status: :live` only.
- Use the existing Orkestra `Telemetry` module conventions: OTel span per event processed, gauge for checkpoint position, gauge for lag.

**Warning signs:**
- Alert fatigue from lag alerts firing during every rebuild.
- Lag appears 0 during off-hours even when the projector is halted.
- No metric for "how many events does the projector still need to process."

**Phase to address:** Telemetry / observability phase. Must be designed alongside the checkpoint store (checkpoint position must be queryable to compute lag).

---

## Technical Debt Patterns

| Shortcut | Immediate Benefit | Long-term Cost | When Acceptable |
|----------|-------------------|----------------|-----------------|
| Single shared Ecto Repo for all projections | Simpler setup, one pool to configure | Pool contention during rebuilds; migrations entangled; no independent rollback | Never — violates Orkestra's per-projection isolation design |
| Wall-clock lag metric instead of positional lag | Trivial to implement | Misleading at low/high traffic; cannot detect stuck projector during off-hours | Never for production alerting |
| `rescue _e -> :ok` in projector handlers | Prevents crashes | Silently skips events, creating gaps; defeats the halt-on-error design | Never |
| Skipping idempotency (assume events arrive once) | Simpler handler logic | Data corruption on any redelivery or replay | Only in early prototyping against a local in-memory event store |
| Global sequence checkpoint without per-stream ordering | Simpler checkpoint schema | Out-of-order processing within a stream when multiple streams share a global queue | Only if message bus guarantees per-stream FIFO (PubSub in-process does; RabbitMQ does not by default) |
| Drop-and-rebuild for every schema change | Simple migration story | Minutes-to-hours of stale read model; unacceptable for production | Only during development, never in production without a maintenance window |

---

## Integration Gotchas

| Integration | Common Mistake | Correct Approach |
|-------------|----------------|------------------|
| Ecto multi-repo (per-projection) | Forgetting to add each projection's Repo to the application supervisor tree | Each projection Repo must be started as a child in the application supervisor, or via `DynamicSupervisor` |
| Ecto `insert_all` during rebuild | Passing structs instead of maps; Ecto `insert_all` requires keyword lists or maps, not `%Schema{}` structs | Convert structs to maps before `insert_all`; use `Map.from_struct/1` |
| EventStoreDB catch-up subscription | Using `subscribe_to_stream` (single stream) when the projector must handle all events | Use `subscribe_to_all_streams` with a start position; filter by event type in the handler |
| RabbitMQ and projection ordering | Relying on RabbitMQ queue ordering across multiple consumers for the same projector | Use a single consumer per projector, or partition by aggregate ID using consistent hashing into separate queues |
| Ecto sandbox in tests | Projector GenServer uses a different connection than the test process; test assertions see empty read model | Use `Ecto.Adapters.SQL.Sandbox.allow/3` to share the test connection with the projector process, or use async: false |
| Elasticsearch alias swap | Writing directly to the index name instead of the alias during normal operation | Always write to the alias; use `is_write_index: true` on the current index; swap atomically via `_aliases` API |
| Elasticsearch bulk indexing | Using individual index calls per event during rebuild | Use the `_bulk` API with batch sizes of 100–1000 documents; handle partial failures (bulk response includes per-document status) |

---

## Performance Traps

| Trap | Symptoms | Prevention | When It Breaks |
|------|----------|------------|----------------|
| One `Repo.insert/1` per event during rebuild | Rebuild of 1M events takes hours; DB CPU high | Use `Repo.insert_all/3` in batches of 100–1000; benchmark batch size | Beyond ~10K events in rebuild |
| Loading full event stream into memory before replay | OOM crash or GC pressure during rebuild | Use `Stream` / lazy event store reads; process chunks | Beyond ~100K events |
| Synchronous checkpoint write per event | Checkpoint table becomes I/O bottleneck | Checkpoint every N events (configurable) with at-most-once risk, or pipeline writes | High-throughput streams (>1000 events/sec) |
| N+1 queries in projector (querying current state before update) | Read model writes slow linearly with volume | Use upserts (`on_conflict: :replace_all`) instead of read-then-write | Any meaningful load |
| Elasticsearch index without explicit mappings during rebuild | ES dynamically maps fields on first insert; mapping conflicts corrupt the index on subsequent inserts with different types | Always define explicit index mappings before indexing; use `PUT /<index>/_mapping` before bulk indexing | First time a field appears with an incompatible type |

---

## "Looks Done But Isn't" Checklist

- [ ] **Checkpoint write**: Verify the checkpoint and read model update are in the same Ecto transaction — not two separate `Repo` calls.
- [ ] **Rebuild status**: Verify the projector status (`idle` / `rebuilding` / `live`) is persisted to the checkpoint store and survives a process crash mid-rebuild.
- [ ] **Halt observability**: Verify a telemetry event is emitted when a projector halts and the halt status is visible in the checkpoint store — not just a log line.
- [ ] **Idempotency**: Verify that replaying the same event twice produces identical read model state — not incremented counters or duplicate rows.
- [ ] **Per-projection Repo supervisor**: Verify each projection's Ecto Repo is listed in the application supervisor tree and starts before the projector GenServer.
- [ ] **Migration rollback**: Verify `mix ecto.rollback` on a per-projection repo works in CI and does not affect other projections' repos.
- [ ] **Test await helper**: Verify integration tests use `wait_for_projection/1` before asserting on read model state — not `Process.sleep`.
- [ ] **DLQ record content**: Verify dead-letter events include the event ID, global position, projector name, error reason, and full payload — enough to replay or diagnose without reading the event store directly.

---

## Recovery Strategies

| Pitfall | Recovery Cost | Recovery Steps |
|---------|---------------|----------------|
| Out-of-order corruption | MEDIUM | Identify affected aggregate IDs from event store; trigger partial rebuild for those streams |
| Checkpoint / duplicate application | MEDIUM | Identify duplicated rows from event log; delete duplicates; reset checkpoint to last known-good position; rebuild from there |
| Rebuild gap (skipped events) | HIGH | Rebuild the entire projection from position 0; there is no partial recovery when the gap is unknown |
| Poison event halting projector | LOW | Fix the projector code (add upcast or handle new event shape); delete the event from the DLQ or fix the event in the store; restart the projector |
| Ecto pool exhaustion | LOW | Cancel the rebuild; increase pool size or reduce rebuild concurrency; restart with bounded parallelism |
| Migration drift / column missing | MEDIUM | Roll back the projector code to the prior version; run the missing migration; re-deploy |
| ES alias swap missed (writes to wrong index) | HIGH | Identify window where writes went to wrong index; re-replay events for that window against the correct index |

---

## Pitfall-to-Phase Mapping

| Pitfall | Prevention Phase | Verification |
|---------|------------------|--------------|
| Out-of-order concurrent processing | Core projector lifecycle (subscription + checkpoint design) | Test: two concurrent workers on same stream must produce correct final state |
| Checkpoint / idempotency bugs | Core projector lifecycle + Ecto adapter | Test: replay same event twice, assert read model unchanged |
| Rebuild race condition / cutover gap | Core projector lifecycle (rebuild design) | Test: send live events during a rebuild, verify all are present in final read model |
| Poison events stalling projector | Core projector lifecycle (error handling) | Test: inject a malformed event, verify projector halts and emits telemetry; verify subsequent events are not processed |
| Ecto pool exhaustion during rebuild | Ecto adapter phase (per-projection Repo isolation + batch writes) | Load test: rebuild 100K events, verify application pool is unaffected |
| Per-projection migration drift | Ecto adapter phase (migration isolation design + CI rollback test) | CI: run migrations up then rollback on every PR |
| Eventual consistency / read-after-write | Core projector lifecycle (expose checkpoint position) + telemetry phase | Integration test: use `wait_for_projection/1`; verify lag SLA alert fires on simulated stall |
| Silent event gaps during rebuild | Core projector lifecycle (rebuild design) | Test: count events in event store vs entities in read model after rebuild |
| Telemetry lag misimplementation | Telemetry / observability phase | Test: assert lag metric equals `head_position - checkpoint_position`; assert rebuild metric is separate |
| ES alias swap pitfalls | Elasticsearch adapter phase (future milestone) | Test: perform alias swap under write load; verify no documents written to stale index |

---

## Sources

- [Guide to Projections and Read Models — Event-Driven.io](https://event-driven.io/en/projections_and_read_models_in_event_driven_architecture/)
- [On Rebuilding Read Models, Dead-Letter Queues and Why Letting Go is Sometimes the Answer — Event-Driven.io](https://event-driven.io/en/rebuilding_read_models_skipping_events/)
- [Event Sourcing Projection Patterns: Deduplication Strategies — Domain Centric](https://domaincentric.net/blog/event-sourcing-projection-patterns-deduplication-strategies/)
- [The Ugly of Event Sourcing: Projection Schema Changes — Dennis Doomen / LinkedIn](https://www.linkedin.com/pulse/ugly-event-sourcing-projection-schema-changes-dennis-doomen)
- [Eventual Consistency is a UX Nightmare — CodeOpinion](https://codeopinion.com/eventual-consistency-is-a-ux-nightmare/)
- [CQRS Pitfalls: Why Your Read Model is Stale — DEV Community](https://dev.to/alex_aslam/cqrs-pitfalls-why-your-read-model-is-stale-2f99)
- [Things I Wish I Knew When I Started with Event Sourcing — SoftwareMill](https://softwaremill.com/things-i-wish-i-knew-when-i-started-with-event-sourcing-part-1/)
- [Elasticsearch Zero Downtime Reindexing: Problems and Solutions — codecentric](https://www.codecentric.de/en/knowledge-hub/blog/elasticsearch-zero-downtime-reindexing-problems-solutions)
- [Zero Downtime Re-indexing with Elasticsearch — Juby Victor / Medium](https://juby-victor.medium.com/zero-down-time-re-indexing-with-elasticsearch-7fc8c69acde8)
- [Tackling Performance Issues in Ecto Applications — AppSignal Blog](https://blog.appsignal.com/2023/05/23/tackling-performance-issues-in-ecto-applications.html)
- [Idempotency in CQRS and Event Sourcing Part 2 — DEV Community](https://dev.to/ohugonnot/idempotency-in-cqrs-and-event-sourcing-part-2-commands-projections-and-outbox-4ei)
- [Dealing with Eventual Consistency in a CQRS/ES Application — 10consulting.com](https://10consulting.com/2017/10/06/dealing-with-eventual-consistency/)
- [Event Sourcing Projections Patterns: Consumer Scaling — Domain Centric](https://domaincentric.net/blog/event-sourcing-projections-patterns-consumer-scaling/)
- [Lessons from the Trenches: CQRS, Event Sourcing, and the Cost of Tooling Constraints — Ashraf Mageed](https://www.ashrafmageed.com/cqrs-eventsourcing-and-the-cost-of-tooling-constraints/)
- [Handling Poison Events: Best Practices — AxonIQ Community](https://discuss.axoniq.io/t/handling-poison-events-do-we-have-some-shared-best-practices/2580)
- Orkestra codebase concerns (`.planning/codebase/CONCERNS.md`) — existing RabbitMQ error-handling and atom-exhaustion issues are relevant to projector error handling

---

*Pitfalls research for: event-sourced projection / read-model subsystem (Elixir / Orkestra)*
*Researched: 2026-06-24*
