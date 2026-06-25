# Roadmap: Orkestra — Projection / Read-Model Subsystem

## Milestones

- ✅ **v1.0 Projection / Read-Model Subsystem** — Phases 1-5 (shipped 2026-06-24)
- 🚧 **v1.1 Elasticsearch / OpenSearch Projection Adapter** — Phases 6-11 (in progress)

## Phases

<details>
<summary>✅ v1.0 Projection / Read-Model Subsystem (Phases 1-5) — SHIPPED 2026-06-24</summary>

- [x] Phase 1: Foundations (3/3 plans) — completed 2026-06-24
- [x] Phase 2: Projector GenServer + Ecto Adapter (3/3 plans) — completed 2026-06-24
- [x] Phase 3: DSL, Supervisor, Mix Tasks, and Config (2/2 plans) — completed 2026-06-24
- [x] Phase 4: Telemetry & Observability (2/2 plans) — completed 2026-06-24
- [x] Phase 5: MCP Integration and Query Helpers (3/3 plans) — completed 2026-06-24

Full details: [milestones/v1.0-ROADMAP.md](milestones/v1.0-ROADMAP.md)

</details>

### 🚧 v1.1 Elasticsearch / OpenSearch Projection Adapter (In Progress)

**Milestone Goal:** Add an ES/OpenSearch storage adapter to the existing projection subsystem, with batch indexing, zero-downtime alias-swap rebuild, and an Elixir query DSL — so a developer can point a projector at Elasticsearch the same way they point one at Postgres.

- [ ] **Phase 6: ES Storage Adapter Foundation** - Implement the `Storage` behaviour for ES/OpenSearch with engine detection, auth, idempotent writes, and explicit index mapping management
- [ ] **Phase 7: GenServer ES Commit Path and Batch Indexing** - Wire the ES write path in the projector GenServer, add batch accumulation for catch-up mode, and instrument all ES operations with OTel spans and telemetry metrics
- [ ] **Phase 8: Projector Macro DSL for Elasticsearch** - Add `backend: :elasticsearch`, `project_es/2`, and ES-specific options to `use Orkestra.Projector` without regressing Postgres projectors
- [ ] **Phase 9: Zero-Downtime Rebuild and Mix Task** - Implement versioned index creation, alias swap, live-write pause, and the `mix orkestra.projection.es.rebuild` task
- [ ] **Phase 10: ES Query DSL Builder** - Deliver a pipe-based composable ES query builder and optional generated `ES.Queries` module per projection
- [ ] **Phase 11: MCP Generator and Introspection** - Add `gen_es_projection` tool and surface ES projections in `domain_map` and `ListProjections`

## Phase Details

### Phase 6: ES Storage Adapter Foundation
**Goal**: Developers can configure and start an ES/OpenSearch storage adapter that correctly implements the `Storage` behaviour, detects the engine at runtime, authenticates via Basic Auth or API key, creates indexes with explicit mappings, and writes full-document upserts with deterministic IDs
**Depends on**: Phase 5 (v1.0 complete)
**Requirements**: ADPT-01, ADPT-02, ADPT-03, ADPT-04, ADPT-06
**Success Criteria** (what must be TRUE):
  1. A projector configured with `Orkestra.Projection.Storage.Elasticsearch` starts without error against both an ES 8.x cluster and an OpenSearch 2.x cluster
  2. On first start the adapter creates the target index with the mapping returned by `index_mapping/0` and `dynamic: strict` enforcement
  3. A `write/4` call returns an `es_op` descriptor map with `:action`, `:id`, and `:doc` keys; the document is indexed as a full-document upsert using a deterministic ID
  4. Authentication works with both Basic Auth credentials and an API key without code changes to the projector
  5. Engine divergences between ES 8.x and OpenSearch 2.x are handled transparently via runtime detection at startup
**Plans**: TBD

### Phase 7: GenServer ES Commit Path and Batch Indexing
**Goal**: An ES projector processes events end-to-end: single-document writes in live mode and batched bulk indexing during catch-up/rebuild, with per-item partial failure detection, OTel spans for every ES operation, and telemetry metrics for batch throughput and rebuild progress
**Depends on**: Phase 6
**Requirements**: BULK-01, BULK-02, BULK-03, OBSV-01, OBSV-02
**Success Criteria** (what must be TRUE):
  1. In live mode, each event processed by an ES projector results in exactly one single-document `index` call via `Snap.Document`
  2. During catch-up/rebuild the projector accumulates `es_op` descriptors and flushes via `Snap.Bulk.perform/4` at the configured batch size (default 500)
  3. A bulk response containing per-item failures is detected, reported with structured error detail, and does not silently advance the checkpoint
  4. OTel spans are emitted for single-doc write, bulk flush, with ES-specific attributes (index name, doc count, engine)
  5. Telemetry events expose bulk batch size, bulk flush duration, and rebuild replay progress
**Plans**: TBD
**UI hint**: no

### Phase 8: Projector Macro DSL for Elasticsearch
**Goal**: A developer can write `use Orkestra.Projector, backend: :elasticsearch` with a `project_es/2` macro and ES-specific options, and the generated `child_spec/1` wires the ES storage adapter automatically without any changes to existing Postgres projectors
**Depends on**: Phase 7
**Requirements**: ADPT-05, ADPT-07
**Success Criteria** (what must be TRUE):
  1. A module using `use Orkestra.Projector, backend: :elasticsearch` compiles and starts with `:cluster` and `:checkpoint_repo` options; `:repo` is not required
  2. The `project_es/2` macro maps an event type to an ES write descriptor the same way `project/2` maps to a Postgres write
  3. Checkpoint writes execute ES-first then Postgres-second (at-least-once semantics), verified by a test that kills the process between the two writes and confirms the event is reprocessed on restart
  4. All existing Postgres projector tests continue to pass unchanged
**Plans**: TBD

### Phase 9: Zero-Downtime Rebuild and Mix Task
**Goal**: A developer can trigger a full ES projection rebuild via `mix orkestra.projection.es.rebuild` that creates a versioned index, replays all events, atomically swaps the alias, and cleans up the old index — without any search downtime and without a race condition between live writes and the alias swap
**Depends on**: Phase 8
**Requirements**: RBLD-01, RBLD-02, RBLD-03
**Success Criteria** (what must be TRUE):
  1. Running `mix orkestra.projection.es.rebuild MyProjector` creates a new versioned index, replays all events into it, swaps the alias atomically, and removes the old index
  2. Search queries against the projection alias return results throughout the entire rebuild (no downtime window)
  3. Live writes are paused during the alias swap window to prevent documents landing on the old index; the projector resumes normal operation after the swap completes
  4. If the rebuild process crashes mid-replay, re-running the Mix task starts a fresh rebuild from position zero (no orphan index accumulation)
**Plans**: TBD

### Phase 10: ES Query DSL Builder
**Goal**: A developer can compose Elasticsearch queries in idiomatic Elixir using a pipe-based DSL, and optionally scaffold a generated `ES.Queries` module per projection with common search operations
**Depends on**: Phase 6
**Requirements**: QDSL-01, QDSL-02
**Success Criteria** (what must be TRUE):
  1. A developer can compose a bool query with must/filter/range clauses and aggregations using `|>` pipes and call `to_query/1` to produce a valid ES Query DSL map
  2. Running `gen_es_projection` (or manual wiring) produces an optional `ES.Queries` module with `search/1`, `get/1`, and `list/1` functions scoped to that projection's index
  3. Composing two queries via pipe never silently drops clauses (verified by test with overlapping must/filter additions)
**Plans**: TBD
**UI hint**: no

### Phase 11: MCP Generator and Introspection
**Goal**: The MCP server can scaffold a complete ES projector module and ES projections appear in domain_map and ListProjections introspection resources alongside Postgres projections
**Depends on**: Phase 10
**Requirements**: MCP-01, MCP-02
**Success Criteria** (what must be TRUE):
  1. Calling `gen_es_projection` in the MCP server generates a projector module with `index_mapping/0`, `document_id/1`, and `project_es/2` callbacks, a cluster config snippet, and a test stub using Snap's mock HTTP adapter
  2. `domain_map` and `ListProjections` include ES projections with their backend type, cluster, and index name alongside existing Postgres projections
**Plans**: TBD

## Progress

**Execution Order:**
Phases execute in numeric order: 6 → 7 → 8 → 9 → 10 → 11
Note: Phase 10 depends only on Phase 6 (independent of write path) but is sequenced after Phase 9 for milestone coherence.

| Phase | Milestone | Plans Complete | Status | Completed |
|-------|-----------|----------------|--------|-----------|
| 1. Foundations | v1.0 | 3/3 | Complete | 2026-06-24 |
| 2. Projector GenServer + Ecto Adapter | v1.0 | 3/3 | Complete | 2026-06-24 |
| 3. DSL, Supervisor, Mix Tasks, and Config | v1.0 | 2/2 | Complete | 2026-06-24 |
| 4. Telemetry & Observability | v1.0 | 2/2 | Complete | 2026-06-24 |
| 5. MCP Integration and Query Helpers | v1.0 | 3/3 | Complete | 2026-06-24 |
| 6. ES Storage Adapter Foundation | v1.1 | 0/? | Not started | - |
| 7. GenServer ES Commit Path and Batch Indexing | v1.1 | 0/? | Not started | - |
| 8. Projector Macro DSL for Elasticsearch | v1.1 | 0/? | Not started | - |
| 9. Zero-Downtime Rebuild and Mix Task | v1.1 | 0/? | Not started | - |
| 10. ES Query DSL Builder | v1.1 | 0/? | Not started | - |
| 11. MCP Generator and Introspection | v1.1 | 0/? | Not started | - |
