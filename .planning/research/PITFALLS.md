# Pitfalls Research

**Domain:** Elasticsearch / OpenSearch projection adapter added to an existing Elixir CQRS/ES projection subsystem (Orkestra v1.1)
**Researched:** 2026-06-25
**Confidence:** HIGH (ES/OS official docs + multiple cross-checked sources; Elixir-specific patterns verified against Finch/Req hexdocs and forum discussions)

---

> **Scope note:** This file covers pitfalls specific to the v1.1 ES/OpenSearch storage adapter milestone.
> Pitfalls for the v1.0 projector core (ordering, checkpoint consistency, rebuild lifecycle, Ecto pool, poison events)
> were catalogued in the previous milestone and remain valid — the adapter build inherits all of those.
> The pitfalls below are either new to ES/OS or materially different in the ES/OS context.

---

## Critical Pitfalls

### Pitfall 1: ES 8.x vs OpenSearch 2.x API Divergence — Invisible at Dev Time, Fatal in Production

**What goes wrong:**
Code written and tested against one engine silently fails or returns wrong results against the other. The two most common failure modes:

1. **Security API paths diverge.** ES 8.x uses `/_security/…`; OpenSearch uses `/_plugins/_security/api/…`. Any code that calls the security API (e.g., creating index roles or inspecting permissions) will get a 404 on the other engine with no indication of which engine is running.

2. **`X-Elastic-Product` header check.** ES 8.x responses include `X-Elastic-Product: Elasticsearch`. Some ES client libraries (and any code that validates response provenance) will error on OpenSearch responses that lack this header. Conversely, sending `Accept: application/vnd.elasticsearch+json;compatible-with=8` to OpenSearch will get a 406 Not Acceptable.

3. **Mapping types removed in ES 8.x.** Any URL that includes a custom type (e.g., `PUT /index/_doc/type/1`) fails with a hard error on ES 8 but works on OpenSearch which forks from ES 7.10 and still supports the legacy type syntax in some paths.

**Why it happens:**
OpenSearch is a fork of ES 7.10. Since the fork, ES has made breaking API changes (security, content-type headers, mapping types) that OpenSearch did not follow. A custom HTTP client built against one engine is not aware of the other's divergence unless the adapter explicitly handles both.

**How to avoid:**
- Abstract every HTTP interaction behind an internal `Client` module with an `engine: :elasticsearch | :opensearch` config key. Never build request URLs or set headers in the projector code directly.
- At startup, call `GET /` and detect the engine from the `version.distribution` field (OpenSearch returns `"distribution":"opensearch"`; ES returns absence of that key or `"tagline":"You Know, for Search"`). Store the detected engine in the adapter state.
- Use `application/json` (not the ES vendor content-type) for all requests; it is accepted by both engines.
- Never call security-plane APIs from the adapter; confine them to admin tooling with clear engine guards.
- Write integration tests against both engines in CI using Docker Compose.

**Warning signs:**
- `406 Not Acceptable` responses when running against one engine after developing on the other.
- `Missing X-Elastic-Product header` errors when pointing an ES-biased client at OpenSearch.
- Index create/delete works but mapping PUT fails silently with a 400 when switching engines.

**Phase to address:** Phase 1 — HTTP client foundation. The engine detection and header strategy must be locked in before any higher-level adapter code is written.

---

### Pitfall 2: Checkpoint Stored in Postgres, Documents in Elasticsearch — No Shared Transaction

**What goes wrong:**
The v1.0 Postgres adapter achieves atomic checkpoint + read-model writes via `Ecto.Multi` in a single transaction. The ES adapter cannot participate in that transaction because ES has no RDBMS-style transactions. The failure window is: ES document is written successfully, then the Postgres checkpoint write fails (network blip, DB timeout, OOM). On restart the projector reprocesses the event and writes the ES document again. For `index` operations this is safe (idempotent upsert). For `update` or `script` operations that accumulate state (e.g., increment a counter, append to an array), the document ends up double-applied.

The symmetric failure is equally dangerous: the checkpoint write succeeds but the ES write fails. The projector advances past the event without the document being updated — a permanent gap, invisible until a query returns stale data.

**Why it happens:**
The `Storage.write/4` behaviour was designed around the Ecto.Multi composability model. The ES adapter returns a different `ops` descriptor that the projector GenServer executes in two separate I/O calls (HTTP to ES, then Ecto to Postgres), with no atomic boundary across both.

**How to avoid:**
- Design the ES adapter's `write/4` to return an `ops` descriptor that describes the ES operation but does not execute it. The projector GenServer calls ES first, then writes the checkpoint. If the ES call fails, the checkpoint is not updated and the event is retried — safe, because ES `index` with a deterministic document ID is idempotent.
- Require that all ES document writes use an explicit `_id` derived from the aggregate ID (or event ID for append-log projections). This makes every `index` call idempotent by definition.
- For operations that are not naturally idempotent (scripts, partial updates that accumulate state), either redesign them as full-document overwrites (idempotent), or implement application-level idempotency: embed the last-processed event position in the ES document and skip the update if `doc._last_position >= event_position`.
- Order of operations must be: `ES write → checkpoint write`. If ES fails, retry ES. If checkpoint fails after ES succeeds, the retry re-runs ES (idempotent) then tries checkpoint again. Never checkpoint first.

**Warning signs:**
- Counter fields in ES documents drift above expected values after a node restart.
- ES document count exceeds aggregate count in the write-side event store after a crash-recovery cycle.
- Checkpoint position shows event N processed but the ES document for that event's aggregate is still at the state of event N-1.

**Phase to address:** Phase 1 — HTTP client + Storage adapter foundation. The ordering and idempotency contract must be explicit in the adapter specification before any projection DSL code is written.

---

### Pitfall 3: Bulk API Returns 200 Even When Every Document Failed

**What goes wrong:**
The ES `_bulk` API always returns HTTP 200 (or 201) as long as the request itself was well-formed — even if every single document operation inside it failed. The only indication of failure is the `"errors": true` field in the JSON body and per-item `"status"` codes inside the `"items"` array. Code that checks only the HTTP status code and moves on will silently advance the checkpoint past events whose ES documents were never written.

Partial failures are equally tricky: a bulk of 500 documents may have 498 succeed and 2 fail with `version_conflict_engine_exception` (concurrent update) or `mapper_parsing_exception` (schema mismatch). The 2 failures are invisible if the response body is not inspected per-item.

**Why it happens:**
The ES bulk API design intentionally decouples transport-level success (the HTTP request was received and processed) from operation-level success (each document was indexed). Most HTTP client code checks the status code and stops there, which is correct for all other APIs but wrong for bulk.

**How to avoid:**
- After every bulk request, inspect `response["errors"]`. If `true`, iterate `response["items"]` and collect all items where `item[action]["status"] >= 400`.
- Classify failures: `429` (backpressure — retry the whole batch with exponential backoff), `409` (version conflict — retry individual documents), `400` (mapping error — park to DLQ, do not retry).
- Never advance the projector checkpoint past a bulk batch until all items in that batch have `status < 400` or have been parked to the dead-letter queue.
- In integration tests: inject a mapping-incompatible document into a batch and assert that the batch partial failure is detected and handled correctly, not silently swallowed.

**Warning signs:**
- ES document count lower than expected after a rebuild completes.
- Checkpoint advances to head position but query returns fewer documents than events in the stream.
- No errors logged during bulk indexing despite known-bad test documents.

**Phase to address:** Phase 2 — Bulk indexing during catch-up/rebuild. The per-item error inspection must be part of the bulk executor, not an afterthought.

---

### Pitfall 4: Alias Swap Race Condition — Writes Land on the Wrong Index

**What goes wrong:**
Zero-downtime rebuild works like this: build a new index (`my_projection_v2`), replay all events into it, then atomically swap the alias (`my_projection`) from `v1` to `v2`. The `_aliases` atomic swap API is correct — there is no instant where the alias is undefined. But the race condition is subtler: during the rebuild window, live events are still arriving. The projector (correctly) writes live events to the current write-index via the alias. But when the alias swap completes, `v2` becomes the new write target. Any live events that arrived and were indexed into `v1` during the rebuild are now behind the alias swap — they exist in `v1` (the old index) but not in `v2` (the new index). Queries against the alias see `v2` only and miss those documents.

A second race condition: if two rebuild jobs run concurrently (e.g., a crash during rebuild triggers a restart that initiates a new rebuild), both may attempt to create `v2` and swap the alias. The first swap succeeds; the second swap points the alias back to a partially-built index.

**Why it happens:**
The alias swap is atomic at the ES level, but the coordination between "which index is currently the write target" and "which index the rebuilder is writing to" is not atomic. The projector's GenServer state and ES alias state can diverge after a crash.

**How to avoid:**
- During a rebuild, **pause live writes** (stop the live subscription) before the alias swap. Resume the live subscription pointing to the new index only after the swap completes.
- Store the current write-index name in the projector checkpoint (Postgres) so that after a crash, the new process knows whether to resume the rebuild or start fresh.
- Prevent concurrent rebuilds with a distributed lock keyed on the projector name (a `FOR UPDATE` advisory lock on the checkpoint row is sufficient).
- After the alias swap, verify with `GET /<alias>/_alias` that the alias points exclusively to the new index before re-enabling live writes.
- Never delete the old index immediately after the swap. Keep it for a configurable retention window (e.g., 24 hours) to allow rollback.

**Warning signs:**
- Query against alias returns fewer documents than a direct query against `v2`.
- After rebuild, some aggregate IDs are missing from the ES projection but present in the Postgres event store.
- Two indices share the same alias as the write index (ES will reject writes with "no write index defined" if `is_write_index` is set on both, or silently fail with ambiguous routing if not).

**Phase to address:** Phase 3 — Zero-downtime rebuild / alias swap. The pause-live-write + checkpoint-stored-index-name pattern must be designed before implementation begins.

---

### Pitfall 5: Index Mapping Conflicts Break an Entire Projection Silently

**What goes wrong:**
An index is created without explicit mappings, so ES/OS applies dynamic mapping from the first document it sees. Event A produces a document with `"status": "active"` (string). Later, event B produces a document where `status` is mapped as a keyword in a different context with an integer value `"status": 1`. ES/OS cannot coerce an integer into a keyword field. The document is rejected with a `mapper_parsing_exception`. With dynamic mapping enabled, a future schema change to the event (adding a field that ES interprets as a different type than intended) permanently breaks indexing of all documents that include that field until the index is recreated.

A subtler variant: two events produce documents where the same field name carries semantically different types (e.g., `metadata` is a `map` in event A and a `string` in event B). The first document wins the mapping race; subsequent documents with the other type silently fail.

**Why it happens:**
Developers prototype with dynamic mapping because it requires no upfront schema definition. This works during development when all events are the same shape, but breaks when:
1. An event schema evolves (field type changes across versions).
2. Two event types handled by the same projection have overlapping field names with different types.

**How to avoid:**
- Always define explicit index mappings via index templates before creating any projection index. Never rely on dynamic mapping for production projections.
- Set `"dynamic": "strict"` on projection indices so that documents containing unexpected fields are rejected at index time (fail-fast) rather than silently accepted with those fields ignored.
- Keep the index mapping definition in the Elixir module (as a `@mapping` attribute or `mapping/0` function), colocated with the projector code, so it evolves alongside the event handlers.
- After any event schema change, run a migration that: (1) creates a new index with the updated mapping, (2) re-runs the projection rebuild into the new index, (3) swaps the alias.
- In tests: assert that the mapping matches expectations after projection setup. Never assume the mapping is correct; verify it.

**Warning signs:**
- `mapper_parsing_exception` errors in projector logs after an event schema change.
- A field that should be aggregatable (keyword) is mapped as `text` because the first document contained it as a string.
- Partial bulk failures where some documents succeed but others fail with type conflicts.

**Phase to address:** Phase 1 — Index lifecycle management. Mapping definition and the strict-dynamic policy must be part of index creation, not an optional addition.

---

### Pitfall 6: Near-Real-Time Visibility Gap — Tests Pass But Queries Return Empty

**What goes wrong:**
A document is indexed successfully (ES/OS returns 201 Created). The projector checkpoint is updated. A test (or end-user query) immediately reads from the index and gets zero results. The document is there — it was written successfully — but it is not yet searchable because ES/OS has not refreshed the in-memory buffer into a searchable Lucene segment. The default `index.refresh_interval` is `1s`, meaning worst-case 1 second of invisibility after a write.

In tests, this produces intermittent false-negatives: the test reads the index within the 1-second window and gets no results, then passes on the next run because the previous run populated the data before the refresh fired.

In production, this produces read-after-write surprises: a command is dispatched, the projection catches up (checkpoint advances), but a query fired immediately after still returns stale data.

**Why it happens:**
ES/OS "near-real-time" means indexed documents are not immediately searchable. The 1-second refresh interval is a deliberate performance trade-off: fewer segment refreshes = higher indexing throughput. Developers who come from relational databases expect writes to be immediately visible after `INSERT`.

**How to avoid:**
- In tests: after writing test documents, call `POST /<index>/_refresh` explicitly before asserting on query results. Never use `Process.sleep` as a substitute.
- During rebuild: set `index.refresh_interval: -1` on the index being built to disable automatic refreshes and maximize bulk indexing throughput. After the rebuild is complete and before the alias swap, call `_refresh` once to flush all segments.
- For live-mode writes: accept the 1-second visibility lag as inherent to the ES/OS storage model and document it clearly for API consumers (same eventual-consistency warning as the v1.0 Postgres adapter, but with an additional search-visibility dimension).
- Expose a `wait_for_refresh` option on the adapter for use in integration tests (`?refresh=wait_for` appended to index requests). Do not use `?refresh=true` (synchronous) in production — it serializes all indexing.

**Warning signs:**
- Integration tests fail ~10% of the time with "expected 1 result, got 0."
- Tests pass when run individually but fail when run in the full suite (timing interactions).
- Queries return results with `_seq_no` lower than the last indexed document's sequence number.

**Phase to address:** Phase 1 — HTTP client and adapter foundation. The `wait_for_refresh` option and the test helper pattern must be established before any projection tests are written.

---

### Pitfall 7: ES Version Conflicts Breaking Concurrent Projection Rebuilds

**What goes wrong:**
ES/OS uses `_seq_no` + `_primary_term` for optimistic concurrency control (replacing the deprecated `_version` field). During a rebuild, multiple documents for the same aggregate ID may be indexed in rapid succession from different bulk batches. If two bulk batches overlap and both try to update the same document using `if_seq_no` / `if_primary_term`, one will get a `version_conflict_engine_exception`. Without explicit handling, this either halts the rebuild or silently drops one of the updates.

The same issue appears during normal live processing if the projector has ever been accidentally run twice (e.g., two OTP nodes sharing the same projector name during a rolling deploy).

**Why it happens:**
ES/OS optimistic concurrency prevents lost updates. The projection rebuild may generate multiple updates for the same document in a short window. The naive assumption is "events are strictly ordered, so there are no concurrent updates for the same document" — but bulk batches can overlap within the same rebuild pipeline, and rolling deploys can cause two instances to run simultaneously.

**How to avoid:**
- For projection writes: use full-document `index` (not `update`) whenever possible. Full `index` overwrites the document unconditionally and never produces a version conflict.
- When partial updates are required: use `retry_on_conflict: 3` in the update action to absorb transient conflicts automatically.
- During rebuild: process events strictly in order (no parallelism across documents for the same aggregate ID). Use a sequential stream, not `Task.async_stream` with unconstrained concurrency.
- Prevent duplicate projector instances: use a named GenServer and ensure the supervision tree does not allow two projectors with the same name on different nodes (or use distributed Erlang/Horde with singleton semantics).

**Warning signs:**
- `version_conflict_engine_exception` appearing in projector logs during rebuild or immediately after deploy.
- Document count in ES is lower than event count in the event store after a full rebuild.
- Some aggregate IDs in ES reflect only the first event, not the latest state.

**Phase to address:** Phase 2 — Bulk indexing and live-mode write path. Version conflict handling policy must be specified in the bulk executor before implementation.

---

### Pitfall 8: HTTP Connection Pool Exhaustion and Silent Timeouts Under Rebuild Load

**What goes wrong:**
During a rebuild, the projector issues many bulk HTTP requests to ES/OS in rapid succession. Finch pools connections per `{scheme, host, port}`. If the rebuild loop generates requests faster than ES can respond (especially under ES indexing pressure), the Finch queue fills and new requests block waiting for a free connection. The default Finch receive timeout is 15 seconds; if ES is saturated and responses take longer, requests time out. The rebuild appears to stall or — worse — partial bulk batches are reported as failures, causing the checkpoint to stop advancing while the rebuild loop keeps generating new requests.

A secondary risk: long-lived connections silently dropped by intermediate network equipment (load balancers, NATs) while the Finch pool keeps references to them. The next request on a dead connection gets a connection-reset error that is not automatically retried.

**Why it happens:**
ES `_bulk` responses can be slow when the cluster is under indexing pressure (GC pauses, segment merges, shard rebalancing). Finch's default pool size (typically 10 per pool) is appropriate for API call workloads but undersized for high-throughput bulk indexing.

**How to avoid:**
- Configure a named Finch pool dedicated to the ES adapter with tuned `pool_size` (start at `4` connections, benchmark) and `pool_max_idle_time` to detect and drop stale connections.
- Set explicit `receive_timeout` on all bulk requests. 30 seconds is a reasonable upper bound; anything longer suggests the ES cluster is overwhelmed and the rebuild should back off.
- Implement backpressure-aware bulk dispatch: if ES returns 429, wait `retry_after_ms` (or exponential backoff) before retrying. Do not simply re-enqueue and immediately retry.
- Cap the in-flight rebuild concurrency to 2–4 concurrent bulk requests max. More parallelism does not help ES and exhausts the pool.
- Instrument every bulk request with an OTel span that includes duration, batch size, and response status. Aggregate this to detect pool saturation before it becomes a crisis.

**Warning signs:**
- `Finch.Error` with `reason: :timeout` during rebuild.
- Rebuild throughput drops to near zero during ES GC pauses.
- `connection reset by peer` errors that are not retried and cause the rebuild to halt.
- ES responds with `429 Too Many Requests` and the adapter does not back off.

**Phase to address:** Phase 1 — HTTP client foundation. Pool configuration and backpressure handling must be part of the initial client design. Phase 2 — Bulk rebuild path must implement the concurrency cap and 429 backoff.

---

### Pitfall 9: Dynamic Checkpoint / Index Name Coupling Breaks After a Crash During Rebuild

**What goes wrong:**
The rebuild process creates a new index (`my_proj_v2`), writes documents into it, then swaps the alias. This state is tracked only in the in-memory GenServer state. If the process crashes mid-rebuild, the GenServer restarts from the checkpoint stored in Postgres. But the checkpoint does not know that a `v2` index was being built. The new process creates `v2` again (or a `v3`), which orphans the partially-built `v2` index in ES. Over time, ES accumulates orphan indices that consume disk and shard quota.

A worse variant: the restart re-enters the normal live subscription mode instead of resuming the rebuild, causing the projector to write live events to the alias (`v1`) while the orphan `v2` is half-built. The alias swap never runs, the rebuild silently abandons, and the operator has no indication the rebuild did not complete.

**Why it happens:**
Rebuild state (which index is being built, how many events have been replayed) is transient GenServer state, not persisted state. The checkpoint only stores `last_position` and `halted`. There is no `rebuild_in_progress` or `rebuild_target_index` persisted to Postgres.

**How to avoid:**
- Extend the Postgres checkpoint record with `rebuild_status :: nil | :in_progress | :completed` and `rebuild_target_index :: string | nil`. These fields are updated atomically before and after the rebuild.
- On projector startup, check `rebuild_status`. If `:in_progress`, resume the rebuild from `last_position` into `rebuild_target_index` rather than starting from scratch.
- At the start of a rebuild, write `rebuild_status: :in_progress, rebuild_target_index: "my_proj_v2"` to Postgres before creating the ES index. On crash recovery, the process can find the partially-built index and continue.
- Implement a periodic orphan-index cleanup task that scans for indices matching the projection naming pattern that are not referenced by any alias and are older than a configurable TTL.

**Warning signs:**
- Multiple `my_proj_v2`, `my_proj_v3`, etc. indices accumulate in ES with no corresponding alias.
- A rebuild that was initiated does not appear to have completed, but the projector is running in live mode.
- ES shard count grows unboundedly after repeated restart cycles.

**Phase to address:** Phase 3 — Zero-downtime rebuild. Persisted rebuild state must be designed into the checkpoint schema extension before implementation.

---

### Pitfall 10: Query DSL Composability Traps — Silent Invalid Queries

**What goes wrong:**
An Elixir query DSL for ES is built as maps that are JSON-serialized and sent to ES. The trap: ES accepts structurally invalid queries in many cases without returning an error — it simply returns zero results. For example, a `bool` query with `must` containing a non-list value (a single clause map instead of a list of clause maps) is silently ignored by ES, returning all documents unfiltered. A `range` query with a mistyped field name (`"gte"` instead of `"gt"`) is also accepted and returns unexpected results.

A second trap: query clauses at different levels of the DSL are merged via `Map.merge/2`, which silently drops one clause if two clauses share the same key (e.g., two `must` filters at different call sites both resolve to `%{"must" => ...}` and the second overwrites the first).

**Why it happens:**
ES Query DSL is a deeply nested JSON structure. Elixir maps have no schema enforcement. A DSL built on top of bare maps provides no compile-time or runtime validation. The Elixir developer expects `{:error, reason}` on invalid input; ES returns `200 {"hits": {"total": 0}}`.

**How to avoid:**
- Build the query DSL on typed structs (`defstruct`), not raw maps. Each clause type (`BoolQuery`, `MatchQuery`, `RangeQuery`, etc.) is a struct with typed fields. Validation happens at struct construction time, not at serialization.
- For `bool` query composition, accumulate `must` / `should` / `filter` / `must_not` as lists. Use a dedicated `add_must/2`, `add_filter/2` etc. API instead of raw `Map.put/3`.
- Write property-based tests that generate random valid query compositions and assert the serialized JSON is structurally correct (not that it returns expected results — that requires a live ES instance).
- Test every public DSL function with an intentionally wrong argument and assert `{:error, reason}` (or an ArgumentError) is returned, not a silently-invalid map.

**Warning signs:**
- A filter that should narrow results returns the full dataset.
- Composing two partial queries produces a query where one clause silently disappeared.
- Adding a new `must` clause to an existing query overwrites a previous clause with the same key.

**Phase to address:** Phase 4 — Query DSL. The struct-based composability model and list-accumulator pattern for bool clauses must be the design starting point, not a refactor after the fact.

---

## Technical Debt Patterns

| Shortcut | Immediate Benefit | Long-term Cost | When Acceptable |
|----------|-------------------|----------------|-----------------|
| Dynamic mapping (no explicit index template) | Zero upfront schema work | First incompatible event breaks the entire index; requires full rebuild to fix | Development/prototyping only, never production |
| Checking only HTTP status code from bulk API | Simple success/failure path | Partial failures are invisible; checkpoint advances past un-indexed events | Never |
| Storing rebuild progress only in GenServer state | No schema changes needed | Crash during rebuild abandons the index and orphans ES shards | Never for production |
| Using `?refresh=true` on every index request | Documents immediately searchable | Serializes all indexing; throughput collapses to ~10 docs/sec | Never in live or rebuild mode |
| Hardcoding ES 8.x URL patterns | Simpler request construction | Adapter breaks on OpenSearch without any error at compile time | Never — engine abstraction costs one abstraction layer, worth it |
| Naive `Map.merge` for query composition | Simple one-liner | Silently drops clauses; bool query filters disappear | Never |
| Single shared Finch pool for all HTTP calls | No pool configuration | ES rebuild traffic starves other adapters; timeout cascades | Never — dedicated pool is cheap |

---

## Integration Gotchas

| Integration | Common Mistake | Correct Approach |
|-------------|----------------|------------------|
| ES 8.x vs OpenSearch 2.x | Using `X-Elastic-Product` header validation or ES vendor content-type headers | Use `application/json` everywhere; detect engine at startup via `GET /` response |
| ES `_bulk` API | Trusting HTTP 200 as success | Always inspect `response["errors"]` and iterate `response["items"]` for per-item status codes |
| ES alias swap | Not marking exactly one index with `is_write_index: true` | Every alias used for writes must have exactly one `is_write_index: true` member; validate after swap |
| ES dynamic mapping | Creating an index without an explicit mapping | Always PUT the mapping before first document; set `dynamic: strict` |
| Finch + ES | Using default Finch pool shared with other HTTP calls | Create a named Finch pool with tuned settings exclusively for ES adapter requests |
| ES refresh interval | Using default 1s refresh in rebuild mode | Set `refresh_interval: -1` before bulk rebuild; call `_refresh` once after rebuild completes |
| ES `_update` with scripts | Scripts that accumulate state are not idempotent | Design projections as full-document overwrites; use `index` not `update` by default |
| OpenSearch security | Calling `/_security/…` paths | OpenSearch security lives at `/_plugins/_security/api/…`; gate all security calls behind engine check |
| Checkpoint + ES write ordering | Writing checkpoint before ES succeeds | Always `ES write → checkpoint update`. ES `index` with stable `_id` is idempotent on retry. |
| ES `version_conflict_engine_exception` | Not handling 409 in bulk response | Classify 409s: use `retry_on_conflict` for partial updates; use full `index` (upsert) to avoid them entirely |

---

## Performance Traps

| Trap | Symptoms | Prevention | When It Breaks |
|------|----------|------------|----------------|
| `refresh_interval: 1s` during rebuild | Indexing throughput 30–50% lower than achievable; GC pressure on ES nodes | Set `refresh_interval: -1` before bulk rebuild, restore after | Any rebuild of > 10K documents |
| Unbounded in-flight bulk requests | Finch pool exhaustion; ES 429 errors; projector stall | Cap concurrent bulk requests to 2–4; implement 429 exponential backoff | ES cluster under any non-trivial indexing load |
| Individual `index` calls per event in live mode during high-throughput catch-up | HTTP round-trip overhead dominates; catch-up falls behind live stream | Switch to bulk mode when position lag > configurable threshold | Catch-up streams of > 100 events/sec |
| Loading entire event batch into memory before bulk encoding | OOM crash in projector process | Stream events from event store; encode and dispatch batches of 100–500; never buffer all pending events | Rebuilds of > 100K events |
| ES `_update` with `retry_on_conflict: N` as the default | High conflict rates under rebuild cause repeated retries and slow bulk batches | Use full `index` (upsert) as the default; reserve `_update` for partial updates with no replay path | Any concurrent projector access, rolling deploys |
| No shard count planning for projection indices | Query latency grows as shard count approaches per-node limits | Define shard count in the index template based on expected document volume; default 1 shard for small projections | ES cluster with many small indices exhausting shard quota |

---

## "Looks Done But Isn't" Checklist

- [ ] **Bulk partial failure handling:** Verify the adapter inspects `response["errors"]` and iterates `response["items"]` for every bulk call — not just checks HTTP status.
- [ ] **Engine detection:** Verify the adapter calls `GET /` at startup and stores the detected engine; verify different URL/header paths are taken for ES 8.x vs OpenSearch 2.x.
- [ ] **Idempotent writes:** Verify every ES document has a deterministic `_id` derived from aggregate ID (or event ID). Verify replaying the same event twice produces identical document state.
- [ ] **Alias write-index:** Verify the alias always has exactly one `is_write_index: true` member after creation and after any swap. Verify ES rejects a second write-index being added.
- [ ] **Mapping explicit:** Verify the index mapping is PUT before the first document is indexed. Verify `dynamic: strict` is set. Verify a document with an unknown field is rejected, not silently accepted.
- [ ] **Refresh interval during rebuild:** Verify `refresh_interval` is set to `-1` before bulk rebuild begins and restored after rebuild completes.
- [ ] **Rebuild state persisted:** Verify `rebuild_status` and `rebuild_target_index` are persisted to Postgres before the ES index is created. Verify a restart during rebuild resumes from the correct position.
- [ ] **Checkpoint ordering:** Verify the adapter writes to ES before updating the Postgres checkpoint — never the reverse. Verify the test suite covers the "ES succeeds, checkpoint fails" scenario.
- [ ] **Finch pool isolation:** Verify the ES adapter uses a named Finch pool separate from the default application pool. Verify pool_size and receive_timeout are configured, not left at defaults.
- [ ] **429 backoff:** Verify the bulk executor handles `429 Too Many Requests` with exponential backoff, not an immediate retry loop.
- [ ] **Test refresh calls:** Verify every integration test that queries ES after writing calls `POST /<index>/_refresh` explicitly before asserting results.
- [ ] **Orphan index cleanup:** Verify there is a mechanism (Mix task or periodic job) to identify and remove ES indices that were created by a rebuild that never completed.

---

## Recovery Strategies

| Pitfall | Recovery Cost | Recovery Steps |
|---------|---------------|----------------|
| ES/OS API divergence (wrong engine) | LOW | Fix engine detection; redeploy adapter. No data loss if writes were rejected (they errored out). |
| Checkpoint ahead of ES (ES write failed, checkpoint succeeded) | HIGH | Identify the gap position from Postgres checkpoint vs ES `_seq_no`. Trigger a full rebuild from position 0. |
| Checkpoint behind ES (ES write succeeded, checkpoint failed) | LOW | Restart projector — idempotent ES writes on retry produce same document state. Checkpoint catches up. |
| Bulk partial failure silent skip | HIGH | Identify missing documents by comparing event store IDs to ES `_id`s. Replay affected events. Consider full rebuild. |
| Alias swap with writes on wrong index | MEDIUM | Identify write window from timestamps. Re-index documents from that window from the event store. Restore alias to correct target. |
| Mapping conflict (field type locked) | HIGH | Create new index with corrected mapping. Full projection rebuild into new index. Alias swap. Delete old index. |
| Orphan indices accumulating | LOW | Run cleanup Mix task to identify and delete orphan indices matching projection naming pattern. |
| ES 429 during rebuild (no backoff) | LOW | Stop rebuild. Fix 429 handling to include exponential backoff. Restart rebuild from last checkpoint position. |
| Rebuild state lost on crash (no persistence) | MEDIUM | Cancel partial rebuild. Add `rebuild_status` to checkpoint schema. Rebuild from position 0 with persistence. |
| Query DSL map merge dropping clauses | MEDIUM | Identify affected queries via test failures. Rewrite using struct-based DSL with list accumulation. Re-validate all queries. |

---

## Pitfall-to-Phase Mapping

| Pitfall | Prevention Phase | Verification |
|---------|------------------|--------------|
| ES 8.x vs OpenSearch 2.x API divergence | Phase 1 — HTTP client foundation | Integration tests pass against both engines in CI Docker Compose |
| Checkpoint/ES non-atomic write ordering | Phase 1 — Storage adapter design | Test: ES write succeeds + checkpoint fails → retry produces idempotent ES state |
| Bulk API partial failures | Phase 2 — Bulk indexing path | Test: inject mapping-incompatible document into batch; assert failure detected and parked to DLQ |
| Alias swap race condition | Phase 3 — Zero-downtime rebuild | Test: send live events during rebuild; assert all present in final index after alias swap |
| Index mapping conflicts | Phase 1 — Index lifecycle management | Test: index document with unknown field against `dynamic: strict` index; assert 400 returned |
| Near-real-time visibility (refresh) | Phase 1 — HTTP client foundation | Test: all integration tests use `_refresh` call; assert no `Process.sleep` workarounds |
| Version conflicts from concurrent writes | Phase 2 — Bulk and live write path | Test: two bulk batches update same document; assert final state is correct; no version conflict errors |
| HTTP pool exhaustion under rebuild load | Phase 1 — Client config; Phase 2 — rebuild path | Load test: rebuild 50K events; assert Finch pool never exhausts; assert 429 triggers backoff |
| Rebuild state lost on crash | Phase 3 — Zero-downtime rebuild | Test: crash during rebuild; restart; assert rebuild resumes from last position into same target index |
| Query DSL composition silent drops | Phase 4 — Query DSL | Unit tests: compose two bool queries; assert both clauses present in serialized output |

---

## Sources

- [Elasticsearch REST API compatibility (ES 8.18)](https://www.elastic.co/guide/en/elasticsearch/reference/8.18/rest-api-compatibility.html)
- [ES 8.x to OpenSearch 2 Support — opensearch-project/opensearch-migrations #1071](https://github.com/opensearch-project/opensearch-migrations/issues/1071)
- [OpenSearch FAQ — API compatibility with Elasticsearch](https://opensearch.org/faq/)
- [Elasticsearch Bulk API — partial failure handling, Discuss Elastic Stack](https://discuss.elastic.co/t/get-the-only-failed-document-response-in-bulk-api-elasticsearch/128873)
- [Elasticsearch Zero Downtime Reindexing: Problems and Solutions — codecentric](https://www.codecentric.de/wissens-hub/blog/2014/09/elasticsearch-zero-downtime-reindexing-problems-solutions)
- [Elasticsearch Index Aliases: Read Aliases, Write Aliases, and Rollover Patterns](https://pulse.support/kb/elasticsearch-index-aliases)
- [20 seconds downtime when swapping alias — Discuss Elastic Stack](https://discuss.elastic.co/t/20-seconds-downtime-when-swapping-alias/287739)
- [Elasticsearch Dynamic Mapping Conflict During Indexing — pulse.support](https://pulse.support/kb/elasticsearch-dynamic-mapping-conflict-during-indexing)
- [Elasticsearch best practice: disable dynamic mapping — Thomas Queste, 2025](https://www.tomsquest.com/blog/2025/04/elasticsearch-best-practice-disable-dynamic-mapping/)
- [Near real-time search — Elastic Docs](https://www.elastic.co/guide/en/elasticsearch/reference/8.19/near-real-time.html)
- [Optimistic concurrency control — Elasticsearch Reference](https://www.elastic.co/guide/en/elasticsearch/reference/current/optimistic-concurrency-control.html)
- [Elasticsearch version_conflict_engine_exception — Baeldung Ops](https://www.baeldung.com/ops/elasticsearch-version_conflict_engine_exception)
- [Indexing pressure settings — Elasticsearch Reference](https://www.elastic.co/guide/en/elasticsearch/reference/current/index-modules-indexing-pressure.html)
- [Elasticsearch Client: Handling Scale and Backpressure — DZone](https://dzone.com/articles/elasticsearch-client-handling-scale-and-back-press)
- [Finch — unable to provide a connection within timeout — Elixir Forum](https://elixirforum.com/t/finch-was-unable-to-provide-a-connection-within-the-timeout-due-to-excess-queuing-for-connections-consider-adjusting-the-pool-size-count-timeout-or-reducing-the-rate-of-requests-if-it-is-possible-that-the-downstream-service-is-unable-to-keep-up-with-th/67120)
- [Finch hexdocs — pool configuration](https://hexdocs.pm/finch/Finch.html)
- [Avoiding the Elasticsearch split brain problem — BigData Boutique](https://bigdataboutique.com/blog/avoiding-the-elasticsearch-split-brain-problem-and-how-to-recover-f6451c)
- [Is ElasticSearch Set/Get Eventual Consistent? — Medium](https://medium.com/@Tom1212121/is-elasticsearch-set-get-eventual-consistent-3698ea95fa56)
- [Command Query Responsibility Segregation and Pekko/Akka Projections with Elasticsearch — Mehmet Salgar](https://mehmetsalgar.wordpress.com/2022/05/17/akka-projections-and-elasticearch/)
- [How to Optimize Elasticsearch Bulk Indexing for High Performance — Opster](https://opster.com/guides/elasticsearch/how-tos/optimizing-elasticsearch-bulk-indexing-high-performance/)
- [OpenSearch Security API reference](https://docs.opensearch.org/latest/api-reference/security/index/)

---

*Pitfalls research for: Elasticsearch / OpenSearch storage adapter (Elixir / Orkestra v1.1)*
*Researched: 2026-06-25*
