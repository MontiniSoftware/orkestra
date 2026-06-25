# Project Research Summary

**Project:** Orkestra v1.1 — Elasticsearch/OpenSearch Projection Storage Adapter
**Domain:** CQRS/ES read-model adapter for Elasticsearch and OpenSearch
**Researched:** 2026-06-25
**Confidence:** HIGH (stack and pitfalls verified against official sources; architecture reasoned from existing v1.0 codebase with MEDIUM confidence)

## Executive Summary

Orkestra v1.1 adds an Elasticsearch/OpenSearch storage adapter to the already-shipped projection subsystem. The adapter plugs into the existing `Orkestra.Projection.Storage` behaviour — implementing `write/4` and `reset/2` — while the rest of the projection lifecycle (subscription, checkpointing, retry/halt, error handling) remains unchanged. The right client library is **Snap** (~> 0.16), the only actively maintained Elixir ES/OpenSearch client; it ships first-class APIs for index creation, bulk indexing, alias management, and zero-downtime hotswap. All required Snap dependencies (Finch, castore, Jason) are already present or compatible with the existing lockfile.

The central architectural constraint is that ES has no RDBMS-style transactions. The Postgres adapter achieves atomic checkpoint + read-model writes via `Ecto.Multi` in a single transaction; the ES adapter cannot replicate this. Instead, the adapter writes to ES first and then writes the Postgres checkpoint — at-least-once semantics with idempotent handlers. Checkpoints and dead-letter records always stay in Postgres regardless of where the read model lives. This design holds throughout the entire feature set: live single-document indexing, batch accumulation during catch-up, and the zero-downtime alias-swap rebuild flow.

The primary production risks are operational rather than algorithmic. ES/OpenSearch API divergence can silently break a deployment when switching engines; bulk API partial failures return HTTP 200 and are invisible unless the response body is inspected per-item; alias-swap rebuilds have a race window where live events land on the wrong index; and mappings created without explicit definitions become unfixable without a full reindex. All of these pitfalls are well-understood and have clear prevention strategies that must be designed into the adapter from Phase 1 — they are not addressable retroactively.

## Key Findings

### Recommended Stack

The only net-new library required is **Snap ~> 0.16** (added as an optional dep alongside optional `:amqp` and `:spear`), plus **Finch ~> 0.17** which Snap requires and which is already present in `orkestra_mcp/` but not in the core library. `castore ~> 1.0` arrives transitively through Snap. Jason, mint, and telemetry are already in the lockfile at compatible versions. No version conflicts are expected.

Snap is recommended over all alternatives because it ships zero-downtime index hotswap (`Snap.Indexes.hotswap/5`), streaming bulk operations (`Snap.Bulk.perform/4`), a pluggable auth behaviour (`Snap.Auth`) for API key and future SigV4 support, and a pluggable HTTP client for test isolation — all as first-class APIs rather than things that need to be built. All alternative Elixir ES clients (elastix, elasticsearch-elixir, tirexs) are effectively abandoned. Orkestra should also ship a `Snap.Auth` API key module since Snap only bundles Basic Auth out of the box and ES 8.x / Elastic Cloud prefer API key auth in production.

**Core technologies:**
- `snap ~> 0.16`: ES/OpenSearch HTTP client — the only actively maintained option; ships hotswap, bulk, and auth extension points
- `finch ~> 0.17`: HTTP connection pool — required by Snap; already present in orkestra_mcp; additive for core lib
- `castore ~> 1.0`: TLS CA certificate store — arrives transitively through Snap; no explicit declaration needed
- `Orkestra.Projection.Storage.Elasticsearch.Auth.APIKey` (shipped in adapter): API key auth module implementing `Snap.Auth` — needed for ES 8.x and Elastic Cloud; trivial single-callback module

### Expected Features

The full MVP and differentiator breakdown is in `.planning/research/FEATURES.md`. Summary:

**Must have (table stakes — P1):**
- `Storage` behaviour implementation (`write/4` single-doc upsert, `reset/2` delete/drop) — required for the adapter to work at all
- `index_mapping/0` and `document_id/1` optional callbacks on `Orkestra.Projector` — without explicit mappings the first schema change requires a full rebuild; without deterministic document IDs replays create duplicates
- Index existence check and creation on projector start via `Snap.Indexes.create/4`
- Versioned index naming (`base_YYYYMMDDTHHMMSS`) — prerequisite for zero-downtime alias swap
- `Snap` added as optional dep with `Code.ensure_loaded?` guard
- Batch indexing during catch-up/rebuild via `Snap.Bulk.perform/4` (configurable `batch_size`, default 500)
- Zero-downtime rebuild via alias-swap flow (implemented as explicit steps; not delegated entirely to `hotswap/5`)
- OTel spans for ES operations (single-doc write, bulk flush, alias swap, cleanup)

**Should have (P2):**
- `Orkestra.Projection.ES.Query` — pipe-based Elixir query DSL builder producing ES Query DSL maps
- Optional `ES.Queries` module (`search/1`, `get/1`, `list/1`)
- `mix orkestra.projection.es.rebuild` Mix task

**Defer to v1.2 (P3):**
- MCP `gen_es_projection` generator

**Explicit anti-features (do not build):**
- Transactional checkpoint co-write with ES (impossible; ES has no cross-store transactions)
- Uniform cross-backend query API spanning Ecto and ES (hides both engines' strengths)
- ES as a primary event store (wrong tool; no ordering guarantees, no optimistic concurrency)
- Per-document ES checkpoint tracking (leaks infrastructure state into the read model)
- Dynamic mapping / `dynamic: true` (production footgun; always require `dynamic: strict`)

### Architecture Approach

The adapter integrates at the `Storage.write/4` boundary without modifying the `Storage` behaviour signature. `write/4` returns `{:ok, es_op}` where `es_op` is a single-document descriptor map (`%{action: :index | :update | :delete, id: term(), doc: map()}`). The projector GenServer detects the ops type by pattern matching and dispatches: `Ecto.Multi` ops take the existing Postgres path; `es_op` maps take the new ES path (HTTP call then checkpoint write). During catch-up/rebuild the GenServer accumulates `es_op` descriptors in a buffer and flushes via `Snap.Bulk.perform/4` at configurable batch size or timeout boundaries. Checkpoints remain in Postgres regardless of backend; ES projectors still require a `:checkpoint_repo` (an `Ecto.Repo`). Multiple ES projectors share one `Snap.Cluster`; one cluster per ES host, not one per projector.

**Files modified in the v1.0 codebase:**
1. `Orkestra.Projector.GenServer` — add ES-aware `apply_event` path and batch accumulation state
2. `Orkestra.Projector` macro — add `:backend` option; make `:repo` optional when `backend: :elasticsearch`; add `project_es/2` macro
3. `Orkestra.Projection.Checkpoint` — add `upsert/3` direct function (non-Multi path for post-write checkpoint)
4. `mix.exs` — add `{:snap, "~> 0.16", optional: true}` and `{:finch, "~> 0.17", optional: true}`

**New files:**
1. `lib/orkestra/projection/storage/elasticsearch.ex` — `Storage` behaviour implementation
2. `lib/mix/tasks/orkestra.projection.es.rebuild.ex` — alias-swap rebuild Mix task

### Critical Pitfalls

The full pitfall catalogue (10 pitfalls with prevention strategies, recovery costs, and phase assignments) is in `.planning/research/PITFALLS.md`. The top five that must be addressed in Phase 1:

1. **Bulk API returns HTTP 200 on partial failure** — inspect `response["errors"]` and iterate `response["items"]` for every bulk call; never trust HTTP status alone. Not doing this silently drops documents and advances the checkpoint past un-indexed events, producing a permanent gap.

2. **Checkpoint/ES non-atomic write ordering** — always execute ES write first, then write the Postgres checkpoint. If ES succeeds and the checkpoint write fails, the retry re-executes ES (idempotent) and retries the checkpoint. Reversing the order produces a permanent gap: the event is checkpointed as done but the ES document was never written.

3. **ES 8.x vs OpenSearch 2.x API divergence** — detect the engine at startup via `GET /` and abstract all HTTP interactions behind an internal client. Never hardcode ES 8.x URL patterns. Use `application/json` (not the ES vendor content-type) for all requests.

4. **Index mapping conflicts silently breaking projections** — always create the index with an explicit mapping before the first write; set `dynamic: "strict"` to reject unexpected fields loudly. Dynamic mapping is a dev-time convenience that becomes an unfixable production footgun.

5. **Near-real-time visibility gap in tests** — ES has a default 1-second refresh interval; documents are not immediately searchable after indexing. In tests always call `POST /<index>/_refresh` explicitly before asserting on query results. During rebuild set `refresh_interval: -1` and call `_refresh` once after the rebuild completes.

Additional critical pitfalls addressed in later phases:
- **Alias swap race condition** — live events land on the wrong index if writes are not paused during swap; rebuild state must be persisted to Postgres to survive crashes (Phase 4)
- **HTTP connection pool exhaustion under rebuild load** — use a named Finch pool dedicated to the ES adapter; implement 429 exponential backoff (Phase 1 + Phase 2)
- **Version conflicts from concurrent projection instances** — use full-document `index` (upsert) as the default, not partial `update` (Phase 2)
- **Rebuild state lost on crash** — extend the Postgres checkpoint with `rebuild_status` and `rebuild_target_index` fields (Phase 4)
- **Query DSL composition silently dropping clauses** — use typed structs and list accumulators, not raw `Map.merge` (Phase 5)

## Implications for Roadmap

Architecture research (`ARCHITECTURE.md`) already produced a detailed 7-phase build order. The roadmap should follow this dependency graph closely.

### Phase 1: ES Storage Adapter Foundation

**Rationale:** Everything else depends on a correct, tested adapter that implements the `Storage` behaviour and handles the critical ES correctness constraints (write ordering, idempotency, engine detection, explicit mapping, refresh semantics). Pitfall research assigns five of the ten critical pitfalls to Phase 1. Starting here with these constraints locked in prevents all subsequent phases from inheriting correctness defects.

**Delivers:** `Orkestra.Projection.Storage.Elasticsearch` module; `Code.ensure_loaded?` guard; `es_op` type definition; Snap + Finch as optional deps in `mix.exs`; API key auth module; engine detection at startup via `GET /`; explicit index creation with `dynamic: strict`; `wait_for_refresh` option for tests; dedicated named Finch pool with configurable `pool_size` and `receive_timeout`.

**Addresses:** `Storage` behaviour implementation, `index_mapping/0` callback, `document_id/1` callback, index existence check, Snap optional dep wiring (all P1 table stakes from FEATURES.md)

**Avoids:** Bulk partial failure silent skip, checkpoint/ES ordering inversion, ES/OS API divergence, dynamic mapping, NRT visibility gap in tests, HTTP pool exhaustion (Pitfalls 1–3, 5, 6, 8)

### Phase 2: GenServer ES Commit Path and Batch Accumulation

**Rationale:** The adapter from Phase 1 returns an `es_op` descriptor but the GenServer does not yet know how to execute it. This phase wires the commit path in the GenServer, adds the direct `Checkpoint.upsert/3` function, and implements the batch accumulation state machine for catch-up/rebuild mode. Batch mode is a hard performance requirement — single-doc indexing during catch-up is 10–100x slower than bulk.

**Delivers:** Patched `Orkestra.Projector.GenServer` with ES `apply_event` path and batch buffer (`batch_buffer`, `batch_size`, `batch_timer_ref` state); `Checkpoint.upsert/3` direct function; `Snap.Bulk.perform/4` integration during catch-up; single-doc to batch mode transition on catch-up-to-live; OTel spans for ES operations (single-doc write, bulk flush).

**Addresses:** Batch indexing during catch-up/rebuild, OTel spans for ES operations (P1 from FEATURES.md)

**Avoids:** Version conflicts from concurrent writes (use full-document `index` as default), bulk partial failure per-item inspection, HTTP pool exhaustion under rebuild load (Pitfalls 7, 3, 8)

### Phase 3: Projector Macro DSL Changes

**Rationale:** Users cannot write ES projectors until the `use Orkestra.Projector` macro supports `backend: :elasticsearch`, the `project_es/2` macro, and optional `:repo`. This phase is separated from the GenServer changes because it modifies public API surface and generated code — higher risk of regression in existing Postgres projectors.

**Delivers:** `backend: :elasticsearch` option on `use Orkestra.Projector`; `project_es/2` macro; `:cluster` and `:checkpoint_repo` required opts for ES backend; `:repo` made optional when backend is `:elasticsearch`; `child_spec/1` sets `storage_adapter: Storage.Elasticsearch`.

**Addresses:** ES-aware projector DSL, Snap cluster integration (FEATURES.md table stakes)

**Avoids:** Regression in existing Postgres projector behaviour (verified by existing test suite)

### Phase 4: Zero-Downtime Rebuild and Alias-Swap Mix Task

**Rationale:** Without a rebuild flow the adapter has no safe path for mapping migrations or full replays. Deferred to Phase 4 because it requires the full GenServer and DSL changes from Phases 2–3 to be stable, and it introduces the most operational complexity (rebuild state persistence, alias swap coordination, crash recovery).

**Delivers:** `mix orkestra.projection.es.rebuild` Mix task implementing: stop projector, create versioned index, reset checkpoint, restart with rebuild target index, alias swap on caught-up signal, optional old index cleanup. Checkpoint schema extended with `rebuild_status` and `rebuild_target_index` fields (Ecto migration). OTel spans for alias swap and cleanup.

**Addresses:** Zero-downtime rebuild, versioned index naming, `mix orkestra.projection.es.rebuild` task (FEATURES.md P1 and P2)

**Avoids:** Alias swap race condition, rebuild state lost on crash, orphan index accumulation (Pitfalls 4, 9, and related operational failure modes)

### Phase 5: ES Query DSL Builder

**Rationale:** Independent of the write path; can be built after the core adapter is proven. Deferred to avoid blocking the P1 milestone. No external dependencies — pure Elixir map building over Snap.Search.

**Delivers:** `Orkestra.Projection.ES.Query` pipe-based composable builder (`search/1`, `must/2`, `filter/2`, `range/3`, `aggs/3`, `size/2`, `from/2`, `to_query/1`) using typed structs and list accumulators for bool clauses; optional `ES.Queries` module (`search/1`, `get/1`, `list/1`).

**Addresses:** ES query DSL builder, optional ES Queries module (FEATURES.md P2)

**Avoids:** Query DSL silent clause drops via typed structs and list accumulators instead of raw `Map.merge` (Pitfall 10)

### Phase 6: MCP Generator for ES Projections

**Rationale:** Developer ergonomics enhancement with no blockers on other phases once the core adapter and DSL are complete. Lowest risk — follows the existing `gen_projection` generator pattern.

**Delivers:** `gen_es_projection` MCP tool generating projector module with `index_mapping/0`, `document_id/1`, `project_es/2` callbacks; cluster config snippet; sample query; test stub using Snap's mock HTTP adapter.

**Addresses:** MCP `gen_es_projection` generator (FEATURES.md P3)

### Phase Ordering Rationale

- **Phases 1–2** must complete in order: the adapter defines the `es_op` type; the GenServer consumes it. Neither is fully useful without the other.
- **Phase 3** (macro DSL) is deferred until the GenServer changes are stable to avoid shipping users a shifting API.
- **Phase 4** (rebuild) is the highest operational risk and depends on all three previous phases being correct. Doing it last reduces the chance of having to redesign the rebuild flow to accommodate an incomplete GenServer.
- **Phases 5–6** are strictly additive and have no ordering constraints relative to each other.
- The FEATURES.md dependency graph confirms this order: `Storage.write/4` then `GenServer ES path` then `batch mode` then `rebuild/alias swap`.

### Research Flags

Phases likely needing deeper research during planning:
- **Phase 4 (Zero-Downtime Rebuild):** The alias swap + live-write pause coordination has an under-specified race window. The checkpoint schema extension needs exact field design before implementation. PITFALLS.md documents the failure modes but does not fully specify the concurrency locking strategy (a Postgres advisory lock on the checkpoint row is suggested but not detailed).
- **Phase 2 (Batch Accumulation):** The exact conditions for transitioning from batch to live mode and the timer-flush interaction with the GenServer `handle_info` loop require careful design. The projector lifecycle must expose the `:catching_up` vs `:live` mode distinction cleanly to the batch accumulation logic; verify this against the actual GenServer state machine.

Phases with well-documented patterns (skip research-phase if time is constrained):
- **Phase 1 (Adapter Foundation):** All Snap APIs verified against hexdocs at HIGH confidence. The `Code.ensure_loaded?` guard pattern is established. The `es_op` type design is clearly specified in ARCHITECTURE.md.
- **Phase 3 (Macro DSL):** Follows the existing `use Orkestra.Projector` macro pattern exactly; no novel Elixir macro patterns needed.
- **Phase 6 (MCP Generator):** Follows the existing `gen_projection` generator structure.

## Confidence Assessment

| Area | Confidence | Notes |
|------|------------|-------|
| Stack | HIGH | Snap v0.16.0 API verified against hexdocs and GitHub. All version compatibility confirmed against existing lockfile. No conflicts. |
| Features | MEDIUM-HIGH | Core adapter features verified against Snap API and ES/OS official docs. Query DSL design is a proposal cross-referenced against Python elasticsearch-dsl and ExlasticSearch — needs validation during Phase 5 implementation. |
| Architecture | MEDIUM | Integration design reasoned from the v1.0 codebase (HIGH confidence first-party source) and Snap hexdocs (MEDIUM confidence). Exact GenServer state machine changes are detailed but not validated against the live GenServer code. Verify the `apply_event` path during Phase 2 planning. |
| Pitfalls | HIGH | 10 pitfalls documented with official ES/OS documentation as primary sources for correctness issues (bulk partial failures, mapping conflicts, NRT visibility). ES/OS API divergence cross-checked against GitHub issues and the OpenSearch FAQ. |

**Overall confidence:** MEDIUM-HIGH

### Gaps to Address

- **`Snap.Indexes.hotswap/5` vs manual steps:** ARCHITECTURE.md recommends implementing rebuild as individual steps (create, replay, alias swap) rather than delegating to `hotswap/5`, because `hotswap/5` requires all documents upfront. Validate this against the actual `hotswap/5` implementation during Phase 4 planning — if Snap has streaming support it may simplify the implementation.
- **ES 8.x + OpenSearch 2.x integration tests:** Wire compatibility is documented as compatible for the APIs Orkestra uses, but this is MEDIUM confidence. CI must run against both engines from Phase 1 onward.
- **Checkpoint schema extension for rebuild state:** The fields `rebuild_status` and `rebuild_target_index` are specified in PITFALLS.md but not detailed in the existing Ecto schema. Verify the migration approach for the `projection_checkpoints` table during Phase 4 planning.
- **Snap.Test mock adapter:** STACK.md references Snap's `http_client_adapter` for test isolation without a live cluster. Verify this pattern works for integration testing the adapter during Phase 1.
- **Shard count planning:** PITFALLS.md notes that shard count must be defined in the index template based on expected document volume but provides no concrete defaults. Add shard count guidance to the `index_mapping/0` documentation during Phase 1.

## Sources

### Primary (HIGH confidence)
- [hex.pm/packages/snap](https://hex.pm/packages/snap) — v0.16.0 release, Elixir requirement, dependency list
- [snap.hexdocs.pm/Snap.Indexes.html](https://snap.hexdocs.pm/Snap.Indexes.html) — `hotswap/5`, `alias/4`, `create/4`, `update_mapping`, `cleanup/4`, `list_starting_with/3`
- [snap.hexdocs.pm/Snap.Bulk.html](https://snap.hexdocs.pm/Snap.Bulk.html) — `perform/4`, `page_size`, `page_wait`, action types
- [snap.hexdocs.pm/Snap.Auth.html](https://snap.hexdocs.pm/Snap.Auth.html) — `sign/5` callback, extensibility model
- [snap.hexdocs.pm/Snap.Document.html](https://snap.hexdocs.pm/Snap.Document.html) — `index/6`, `update/6`, `delete/5`
- [github.com/breakroom/snap mix.exs](https://github.com/breakroom/snap/blob/main/mix.exs) — dep versions, CHANGELOG ES 8.x compat fix in 0.11.0
- [Elasticsearch Bulk API docs (elastic.co)](https://www.elastic.co/docs/api/doc/elasticsearch/operation/operation-bulk) — NDJSON format, partial failure semantics, `errors: true` field
- [OpenSearch Bulk API docs (opensearch.org)](https://docs.opensearch.org/latest/api-reference/document-apis/bulk/) — compatibility confirmation
- [Near real-time search — Elastic Docs](https://www.elastic.co/guide/en/elasticsearch/reference/8.19/near-real-time.html) — 1s refresh interval, `_refresh` endpoint
- [Elasticsearch Dynamic Mapping Conflict (pulse.support)](https://pulse.support/kb/elasticsearch-dynamic-mapping-conflict-during-indexing) — `mapper_parsing_exception`, field type locking
- [Elasticsearch Optimistic Concurrency Control (elastic.co)](https://www.elastic.co/docs/reference/elasticsearch/rest-apis/optimistic-concurrency-control) — `_seq_no`, `_primary_term`, idempotent writes
- Orkestra v1.0 codebase — existing `Storage` behaviour, GenServer state machine, Checkpoint/DeadLetter schemas

### Secondary (MEDIUM confidence)
- [Elixir Forum: Snap + OpenSearch startup thread](https://elixirforum.com/t/create-opensearch-index-on-startup-with-snap/70419) — no known ES/OS incompatibilities for Snap
- [Elasticsearch Zero Downtime Reindexing — codecentric](https://www.codecentric.de/wissens-hub/blog/2014/09/elasticsearch-zero-downtime-reindexing-problems-solutions) — alias swap rationale
- [Projecting Marten events to Elasticsearch (event-driven.io)](https://event-driven.io/en/projecting_from_marten_to_elasticsearch/) — batch-on-catch-up, single-doc-on-live projection pattern in .NET
- [Python elasticsearch-dsl Search DSL](https://elasticsearch-dsl.readthedocs.io/en/latest/search_dsl.html) — immutable builder pattern reference for Phase 5 query DSL
- [ExlasticSearch (Frameio)](https://github.com/Frameio/exlasticsearch) — Elixir pipe-based query DSL design reference
- [Finch hexdocs — pool configuration](https://hexdocs.pm/finch/Finch.html) — `pool_size`, `pool_max_idle_time`, `receive_timeout`

### Tertiary (LOW confidence)
- [ES Bulk API performance — Opster](https://opster.com/guides/elasticsearch/how-tos/optimizing-elasticsearch-bulk-indexing-high-performance/) — batch size guidance (1K–5K ops); needs project-specific benchmarking
- [Zero Downtime Reindex blog post (tuleism.github.io, 2021)](https://tuleism.github.io/blog/2021/elasticsearch-zero-downtime-reindex/) — alias swap rationale; pattern is well-established but source is personal blog
- [Domaincentric.net — ES read model deduplication](https://domaincentric.net/blog/event-sourcing-projection-patterns-deduplication-strategies) — external versioning for idempotency; single source

---
*Research completed: 2026-06-25*
*Ready for roadmap: yes*
