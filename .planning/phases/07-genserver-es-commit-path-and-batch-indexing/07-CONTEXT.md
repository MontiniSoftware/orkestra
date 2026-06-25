# Phase 7: GenServer ES Commit Path and Batch Indexing - Context

**Gathered:** 2026-06-25
**Status:** Ready for planning
**Mode:** Auto-generated (infrastructure phase — discuss skipped)

<domain>
## Phase Boundary

Extend the existing `Orkestra.Projector.GenServer` to execute ES write operations from Phase 6's descriptor maps: single-document `index` calls in live mode via `Snap.Document.index/6`, and batched bulk indexing during catch-up/rebuild via `Snap.Bulk.perform/4`. Add per-item partial failure detection for bulk responses, OTel spans for every ES operation, and telemetry metrics for batch throughput and rebuild progress.

Requirements covered: BULK-01, BULK-02, BULK-03, OBSV-01, OBSV-02.

</domain>

<decisions>
## Implementation Decisions

### Claude's Discretion
All implementation choices are at Claude's discretion — pure infrastructure phase. Key constraints from STATE.md and Phase 6:

- **Checkpoint ordering:** ES-first, Postgres-second (at-least-once semantics). Write ES document first, then update Postgres checkpoint atomically.
- **Live mode:** Single-document write per event via `Snap.Document.index(cluster, index, doc, id)` — uses the `es_op` descriptor from `Storage.Elasticsearch.write/4`
- **Catch-up/rebuild mode:** Accumulate `es_op` descriptors in GenServer state, flush via `Snap.Bulk.perform/4` at configurable batch_size (default 500)
- **Mode transition:** `:catching_up` → `:live` when caught up to head of stream (needs verification against GenServer state machine)
- **Partial failure detection:** Parse bulk response body for per-item errors; do NOT advance checkpoint past failed items
- **OTel spans:** Follow existing `Tracer.with_span` pattern from `gen_server.ex` — add ES-specific attributes (index name, doc count, engine)
- **Telemetry metrics:** Follow existing `[:orkestra, :projector, ...]` event pattern — add bulk batch size, bulk flush duration, rebuild progress

### GenServer Integration
- The existing `Projector.GenServer` handles Ecto/Postgres checkpoint writes via `Ecto.Multi` transaction
- For ES, the commit path diverges: ES write first (HTTP), then checkpoint update (Postgres)
- The `storage_adapter` field in GenServer state determines which path to take
- `adapter_opts` carries `:cluster`, `:index`, `:handler` from child_spec

</decisions>

<code_context>
## Existing Code Insights

### Reusable Assets
- `Orkestra.Projector.GenServer` at `lib/orkestra/projector/gen_server.ex` — existing event processing loop, checkpoint management, retry/halt lifecycle
- `Orkestra.Projection.Storage.Elasticsearch` at `lib/orkestra/projection/storage/elasticsearch.ex` — `write/4` returns `%{action: :index, id: id, doc: doc}`, `init/1` returns `%{cluster: _, index: _, engine: _}`
- `Orkestra.Projector.Lifecycle` at `lib/orkestra/projector/lifecycle.ex` — pure retry/backoff/park functions
- `Orkestra.Telemetry` at `lib/orkestra/telemetry.ex` — `projector_span_attrs/3`, telemetry emit helpers

### Established Patterns
- GenServer `apply_event/2` calls `storage_adapter.write/4` then builds Ecto.Multi for checkpoint — need to branch for ES adapter
- Telemetry events: `[:orkestra, :projector, :lag]`, `[:orkestra, :projector, :rebuild_progress]`, `[:orkestra, :projector, :retry]`, `[:orkestra, :projector, :halted]`
- OTel spans: `Tracer.with_span "orkestra.projector.apply_event"` with structured attributes
- Snap APIs: `Snap.Document.index/6` for single doc, `Snap.Bulk.perform/4` for batch

### Integration Points
- `gen_server.ex` `apply_event/2` — branch on storage_adapter type (Postgres vs ES)
- `gen_server.ex` state — add `:es_buffer`, `:es_batch_size`, `:es_mode` fields for batch accumulation
- `telemetry.ex` — add new event types for ES operations
- `child_spec/1` in projector macro — needs to pass batch_size config to GenServer

</code_context>

<specifics>
## Specific Ideas

No specific requirements — infrastructure phase. Refer to ROADMAP phase description and success criteria.

</specifics>

<deferred>
## Deferred Ideas

None — infrastructure phase.

</deferred>
