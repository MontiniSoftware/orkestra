# Requirements: Orkestra

**Defined:** 2026-06-25
**Core Value:** A developer can define a projection that consumes domain events and maintains a queryable read model — with safe rebuilds, in-order error handling, and per-projection migrations — without writing the plumbing themselves.

## v1.1 Requirements

Requirements for Elasticsearch / OpenSearch Projection Adapter. Each maps to roadmap phases.

### Adapter

- [x] **ADPT-01**: Storage adapter implements `Orkestra.Projection.Storage` behaviour (`write/4`, `reset/2`) for Elasticsearch/OpenSearch
- [x] **ADPT-02**: Engine detection at runtime distinguishes ES 8.x from OpenSearch 2.x+ and handles API divergences
- [x] **ADPT-03**: Authentication supports Basic Auth and API key auth via Snap.Auth behaviour
- [x] **ADPT-04**: All writes use full-document `index` with deterministic `_id` for idempotency
- [x] **ADPT-05**: Projector DSL supports `backend: :elasticsearch` option with `project_es/2` macro
- [x] **ADPT-06**: Index mappings defined via `index_mapping/0` callback in projector module
- [x] **ADPT-07**: Checkpoint writes follow ES-first, Postgres-second ordering (at-least-once semantics)

### Bulk Indexing

- [x] **BULK-01**: During catch-up/rebuild, adapter buffers events and flushes via Snap.Bulk in configurable batch size
- [x] **BULK-02**: In live mode, adapter writes single documents immediately via Snap.Document
- [x] **BULK-03**: Bulk response body inspected per-item for partial failures with structured error reporting

### Rebuild

- [x] **RBLD-01**: Zero-downtime rebuild creates new index, replays events, atomically swaps alias, cleans up old index
- [x] **RBLD-02**: `mix orkestra.projection.es.rebuild` Mix task triggers full rebuild with alias swap
- [x] **RBLD-03**: Live writes paused during alias swap to prevent race conditions

### Query DSL

- [x] **QDSL-01**: Elixir query DSL module composes ES queries (bool, match, filter, range, aggs) with pipe syntax
- [x] **QDSL-02**: Optional generated ES.Queries module scaffolded per projection (like gen_queries for Postgres)

### Observability

- [x] **OBSV-01**: OTel spans emitted for ES operations (index, bulk, search, rebuild) with ES-specific attributes
- [x] **OBSV-02**: Telemetry metrics for bulk batch size, bulk duration, and rebuild progress

### MCP

- [x] **MCP-01**: `gen_es_projection` MCP tool scaffolds new ES projection modules
- [x] **MCP-02**: ES projections surfaced in `domain_map` and `ListProjections` introspection resources

## Future Requirements

Deferred to future release. Tracked but not in current roadmap.

### Extended Auth

- **AUTH-01**: AWS SigV4 authentication for Amazon OpenSearch Service

### Rebuild Resilience

- **RRES-01**: Persisted rebuild state (rebuild_status, target_index) in checkpoint for crash-recovery

### Query Helpers

- **QHLP-01**: Thin helper functions (search/2, get_by_id/2, count/1) wrapping Snap.Search

## Out of Scope

| Feature | Reason |
|---------|--------|
| MongoDB projection adapter | Separate milestone; different storage paradigm |
| Synchronous (write-path inline) projections | Rejected in v1.0 in favor of async + replay |
| Dead-letter drain/resume tooling | Deferred to v2 |
| Partial document updates | Breaks idempotency guarantee required for at-least-once checkpoint semantics |
| AWS SigV4 auth | Requires AWS SDK integration; documented as extension point for consumers |

## Traceability

Which phases cover which requirements. Updated during roadmap creation.

| Requirement | Phase | Status |
|-------------|-------|--------|
| ADPT-01 | Phase 6 | Complete |
| ADPT-02 | Phase 6 | Complete |
| ADPT-03 | Phase 6 | Complete |
| ADPT-04 | Phase 6 | Complete |
| ADPT-05 | Phase 8 | Complete |
| ADPT-06 | Phase 6 | Complete |
| ADPT-07 | Phase 8 | Complete |
| BULK-01 | Phase 7 | Complete |
| BULK-02 | Phase 7 | Complete |
| BULK-03 | Phase 7 | Complete |
| RBLD-01 | Phase 9 | Complete |
| RBLD-02 | Phase 9 | Complete |
| RBLD-03 | Phase 9 | Complete |
| QDSL-01 | Phase 10 | Complete |
| QDSL-02 | Phase 10 | Complete |
| OBSV-01 | Phase 7 | Complete |
| OBSV-02 | Phase 7 | Complete |
| MCP-01 | Phase 11 | Complete |
| MCP-02 | Phase 11 | Complete |

**Coverage:**
- v1.1 requirements: 19 total
- Mapped to phases: 19
- Unmapped: 0

---
*Requirements defined: 2026-06-25*
*Last updated: 2026-06-25 — traceability populated after roadmap creation*
