# Requirements: Orkestra

**Defined:** 2026-06-25
**Core Value:** A developer can define a projection that consumes domain events and maintains a queryable read model — with safe rebuilds, in-order error handling, and per-projection migrations — without writing the plumbing themselves.

## v1.1 Requirements

Requirements for Elasticsearch / OpenSearch Projection Adapter. Each maps to roadmap phases.

### Adapter

- [ ] **ADPT-01**: Storage adapter implements `Orkestra.Projection.Storage` behaviour (`write/4`, `reset/2`) for Elasticsearch/OpenSearch
- [ ] **ADPT-02**: Engine detection at runtime distinguishes ES 8.x from OpenSearch 2.x+ and handles API divergences
- [ ] **ADPT-03**: Authentication supports Basic Auth and API key auth via Snap.Auth behaviour
- [ ] **ADPT-04**: All writes use full-document `index` with deterministic `_id` for idempotency
- [ ] **ADPT-05**: Projector DSL supports `backend: :elasticsearch` option with `project_es/2` macro
- [ ] **ADPT-06**: Index mappings defined via `index_mapping/0` callback in projector module
- [ ] **ADPT-07**: Checkpoint writes follow ES-first, Postgres-second ordering (at-least-once semantics)

### Bulk Indexing

- [ ] **BULK-01**: During catch-up/rebuild, adapter buffers events and flushes via Snap.Bulk in configurable batch size
- [ ] **BULK-02**: In live mode, adapter writes single documents immediately via Snap.Document
- [ ] **BULK-03**: Bulk response body inspected per-item for partial failures with structured error reporting

### Rebuild

- [ ] **RBLD-01**: Zero-downtime rebuild creates new index, replays events, atomically swaps alias, cleans up old index
- [ ] **RBLD-02**: `mix orkestra.projection.es.rebuild` Mix task triggers full rebuild with alias swap
- [ ] **RBLD-03**: Live writes paused during alias swap to prevent race conditions

### Query DSL

- [ ] **QDSL-01**: Elixir query DSL module composes ES queries (bool, match, filter, range, aggs) with pipe syntax
- [ ] **QDSL-02**: Optional generated ES.Queries module scaffolded per projection (like gen_queries for Postgres)

### Observability

- [ ] **OBSV-01**: OTel spans emitted for ES operations (index, bulk, search, rebuild) with ES-specific attributes
- [ ] **OBSV-02**: Telemetry metrics for bulk batch size, bulk duration, and rebuild progress

### MCP

- [ ] **MCP-01**: `gen_es_projection` MCP tool scaffolds new ES projection modules
- [ ] **MCP-02**: ES projections surfaced in `domain_map` and `ListProjections` introspection resources

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
| ADPT-01 | — | Pending |
| ADPT-02 | — | Pending |
| ADPT-03 | — | Pending |
| ADPT-04 | — | Pending |
| ADPT-05 | — | Pending |
| ADPT-06 | — | Pending |
| ADPT-07 | — | Pending |
| BULK-01 | — | Pending |
| BULK-02 | — | Pending |
| BULK-03 | — | Pending |
| RBLD-01 | — | Pending |
| RBLD-02 | — | Pending |
| RBLD-03 | — | Pending |
| QDSL-01 | — | Pending |
| QDSL-02 | — | Pending |
| OBSV-01 | — | Pending |
| OBSV-02 | — | Pending |
| MCP-01 | — | Pending |
| MCP-02 | — | Pending |

**Coverage:**
- v1.1 requirements: 19 total
- Mapped to phases: 0
- Unmapped: 19

---
*Requirements defined: 2026-06-25*
*Last updated: 2026-06-25 after initial definition*
