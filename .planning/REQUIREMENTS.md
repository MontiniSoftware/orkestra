# Requirements: Orkestra — Projection / Read-Model Subsystem

**Defined:** 2026-06-24
**Core Value:** A developer can define a projection that consumes domain events and maintains a queryable read model — with safe rebuilds, in-order error handling, and per-projection migrations — without writing the plumbing themselves.

## v1 Requirements

Requirements for this milestone. Each maps to roadmap phases.

### Projector Lifecycle

- [ ] **PROJ-01**: A developer can define a projector via a DSL (`use Orkestra.Projector`) that maps event types to read-model updates
- [ ] **PROJ-02**: A projector consumes events asynchronously via an EventStore catch-up subscription — replaying from its last checkpoint, then transitioning to live with no gap
- [ ] **PROJ-03**: A projector persists its last-processed position and resumes from it after a restart
- [ ] **PROJ-04**: A projector processes events strictly in order (single consumer per projector, no concurrent application to the same read model)
- [ ] **PROJ-05**: Projectors are supervised and isolated — one projector halting or crashing does not stop the others

### Storage Abstraction & PostgreSQL Adapter

- [ ] **STORE-01**: A storage-adapter behaviour defines the contract (write, reset) so backends are pluggable behind a shared lifecycle
- [ ] **STORE-02**: A PostgreSQL/Ecto storage adapter persists read-model updates
- [ ] **STORE-03**: The checkpoint update and the read-model write commit atomically in a single Ecto transaction (`Ecto.Multi`)
- [ ] **STORE-04**: A projection's storage is isolated in its own Ecto.Repo with a dedicated connection pool

### Migrations (per-projection, isolated)

- [ ] **MIG-01**: Each projection owns its tables and an isolated migration history, separate from the host app's migrations and from other projections
- [ ] **MIG-02**: A developer can migrate a single projection (`mix orkestra.projection.migrate <name>`)
- [ ] **MIG-03**: A developer can roll back a single projection's migrations independently (`mix orkestra.projection.rollback <name>`)
- [ ] **MIG-04**: A developer can drop a single projection's tables and checkpoint without affecting other projections (`mix orkestra.projection.drop <name>`)

### Rebuild / Replay

- [ ] **RBLD-01**: A developer can rebuild a projection from scratch — reset read model + checkpoint, replay the full event stream, transition to live (`mix orkestra.projection.rebuild <name>`)
- [ ] **RBLD-02**: Rebuild is gap-free and uses batched writes suitable for large event streams (single catch-up path; no dual replay/live path)

### Error Handling

- [ ] **ERR-01**: On a projection error, the event is retried with backoff (reusing orkestra's existing retry semantics), configurable per projector
- [ ] **ERR-02**: When retries are exhausted, the failing event is parked to a dead-letter store (projector, position, event, error, attempts, timestamp)
- [ ] **ERR-03**: After parking, the projector halts rather than skipping ahead, preserving read-model integrity and requiring operator action to resume
- [ ] **ERR-04**: A halted projector's status is persisted and observable (no silent stall)

### Reads / Queries

- [ ] **READ-01**: A developer can query a read model directly with Ecto (orkestra owns the write/lifecycle side, not the query shape)
- [ ] **READ-02**: An optional generated `Queries` module exposes generic helpers per read model — paged `list/1`, `get_by/2` (exploratory; refine the surface during the milestone)

### Telemetry & Observability

- [ ] **TEL-01**: Each processed event emits an OpenTelemetry span consistent with the existing `Orkestra.Telemetry` conventions
- [ ] **TEL-02**: Projection lag is exposed as a metric — positional (head position − checkpoint position), not wall-clock
- [ ] **TEL-03**: Rebuild progress is exposed as a separate metric from live lag
- [ ] **TEL-04**: Projector errors and halts emit telemetry events/counters for alerting

### MCP Integration

- [ ] **MCP-01**: The MCP server provides a `gen_projection` generator that scaffolds a projector plus its migration
- [ ] **MCP-02**: The MCP server provides a `gen_read_model` generator (schema + migration scaffolding)
- [ ] **MCP-03**: Projections and their read models are surfaced in MCP introspection resources (e.g. `list_projections`, `domain_map`)

### Configuration

- [ ] **CFG-01**: The `:ultimus` app-key bug in event-store config is fixed (→ `:orkestra`)
- [ ] **CFG-02**: Per-projection repo/storage configuration has a clean, documented config story
- [ ] **CFG-03**: New storage dependencies (`ecto`, `ecto_sql`, `postgrex`) are declared as optional deps — the consuming app opts in, consistent with the existing `:amqp`/`:spear` pattern

## v2 Requirements

Deferred to future milestones. Tracked but not in the current roadmap.

### MongoDB Adapter

- **MONGO-01**: A MongoDB storage adapter implements the storage-adapter behaviour for document read models (via `mongodb_driver`)
- **MONGO-02**: MongoDB projections support idempotent writes (two-phase, no single-transaction checkpoint co-write)

### Elasticsearch Adapter ("full" support)

- **ES-01**: An Elasticsearch storage adapter implements the storage-adapter behaviour (via `snap`)
- **ES-02**: Index mappings are managed with versioning (the ES analog of migrations)
- **ES-03**: Zero-downtime rebuild via shadow index + atomic alias swap
- **ES-04**: Search query helpers (full-text + structured) for the `Queries` layer
- **ES-05**: Bulk indexing for live-projection and rebuild throughput

### Operational Tooling

- **ERR-05**: Dead-letter drain/resume tooling to replay parked events and un-halt a projector after a fix

## Out of Scope

Explicitly excluded. Documented to prevent scope creep.

| Feature | Reason |
|---------|--------|
| Synchronous (write-path inline) projections | Couples writes to projection success/latency; async + replay chosen for decoupling |
| Skip-on-error as default behavior | Silently corrupts read models by leaving gaps; park-and-halt is the safe default |
| Uniform write-once query API across all backends | Leaky over SQL vs document vs search differences; storage write/query APIs stay adapter-specific |
| Shared migration repo for all projections | Defeats the per-projection isolated-migration goal (independent rollback/drop/rebuild) |
| In-memory projections for production | Not durable; InMemory is for tests only |

## Traceability

Which phases cover which requirements. Populated during roadmap creation.

| Requirement | Phase | Status |
|-------------|-------|--------|
| PROJ-02 | Phase 1 | Pending |
| STORE-01 | Phase 1 | Pending |
| ERR-01 | Phase 1 | Pending |
| ERR-02 | Phase 1 | Pending |
| ERR-03 | Phase 1 | Pending |
| PROJ-03 | Phase 2 | Pending |
| PROJ-04 | Phase 2 | Pending |
| STORE-02 | Phase 2 | Pending |
| STORE-03 | Phase 2 | Pending |
| STORE-04 | Phase 2 | Pending |
| MIG-01 | Phase 2 | Pending |
| ERR-04 | Phase 2 | Pending |
| READ-01 | Phase 2 | Pending |
| PROJ-01 | Phase 3 | Pending |
| PROJ-05 | Phase 3 | Pending |
| MIG-02 | Phase 3 | Pending |
| MIG-03 | Phase 3 | Pending |
| MIG-04 | Phase 3 | Pending |
| RBLD-01 | Phase 3 | Pending |
| RBLD-02 | Phase 3 | Pending |
| CFG-01 | Phase 3 | Pending |
| CFG-02 | Phase 3 | Pending |
| CFG-03 | Phase 3 | Pending |
| TEL-01 | Phase 4 | Pending |
| TEL-02 | Phase 4 | Pending |
| TEL-03 | Phase 4 | Pending |
| TEL-04 | Phase 4 | Pending |
| READ-02 | Phase 5 | Pending |
| MCP-01 | Phase 5 | Pending |
| MCP-02 | Phase 5 | Pending |
| MCP-03 | Phase 5 | Pending |

**Coverage:**
- v1 requirements: 31 total
- Mapped to phases: 31 ✓
- Unmapped: 0

---
*Requirements defined: 2026-06-24*
*Last updated: 2026-06-24 after roadmap creation — traceability table populated*
