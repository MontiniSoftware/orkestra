# Phase 6: ES Storage Adapter Foundation - Context

**Gathered:** 2026-06-25
**Status:** Ready for planning
**Mode:** Auto-generated (infrastructure phase — discuss skipped)

<domain>
## Phase Boundary

Implement an Elasticsearch/OpenSearch storage adapter (`Orkestra.Projection.Storage.Elasticsearch`) that correctly implements the `Storage` behaviour (`write/4`, `reset/2`), detects the engine at runtime, authenticates via Basic Auth or API key, creates indexes with explicit mappings and `dynamic: strict`, and writes full-document upserts with deterministic IDs.

Requirements covered: ADPT-01, ADPT-02, ADPT-03, ADPT-04, ADPT-06.

</domain>

<decisions>
## Implementation Decisions

### Claude's Discretion
All implementation choices are at Claude's discretion — pure infrastructure phase. Key constraints from STATE.md decisions:

- **ES client:** Snap ~> 0.16 chosen as the only maintained Elixir ES client; ships hotswap, bulk, auth extension
- **Checkpoints stay in Postgres:** ES projectors still require `:checkpoint_repo`; checkpoints always stay in Postgres regardless of backend
- **`dynamic: strict`** enforced on all managed indexes to prevent mapping footguns
- **Finch named pool:** Dedicated to ES adapter to prevent connection exhaustion during bulk rebuild
- **Deterministic `_id`:** Full-document `index` operations with deterministic IDs for idempotency (at-least-once semantics)

### Storage Behaviour Contract
- `write/4` must return `{:ok, es_op}` where `es_op` is a descriptor map with `:action`, `:id`, and `:doc` keys (analogous to Postgres returning `Ecto.Multi.t()`)
- `reset/2` must delete all documents in the projection's index
- Adapter is purely functional — returns data structures, not closures; GenServer controls execution
- Conditional loading via `Code.ensure_loaded?/1` pattern (same as Postgres adapter uses `Ecto.Multi`)

### Engine Detection
- Runtime detection at startup: call cluster info endpoint, parse version/distribution
- Handle API divergences between ES 8.x and OpenSearch 2.x transparently
- Store detected engine in adapter state for downstream use

### Authentication
- Support Basic Auth and API key auth via Snap's auth mechanisms
- No code changes required in projector module to switch auth methods — configuration only

### Index Management
- Create index with explicit mapping from `index_mapping/0` callback on first start
- Enforce `dynamic: strict` on all managed indexes
- Index name derived from projector name (slugified)

</decisions>

<code_context>
## Existing Code Insights

### Reusable Assets
- `Orkestra.Projection.Storage` behaviour at `lib/orkestra/projection/storage.ex` — defines `write/4` and `reset/2` callbacks
- `Orkestra.Projection.Storage.Postgres` at `lib/orkestra/projection/storage/postgres.ex` — reference implementation; conditional on `Code.ensure_loaded?(Ecto.Multi)`
- `Orkestra.Projector` macro at `lib/orkestra/projector.ex` — generates `child_spec/1`, `__dispatch__/3`, `__handle__/3`, `__projection_config__/0`
- `Orkestra.Projector.GenServer` at `lib/orkestra/projector/gen_server.ex` — subscribes, applies events, manages lifecycle
- `Orkestra.Telemetry` at `lib/orkestra/telemetry.ex` — `projector_span_attrs/3` for OTel span attributes

### Established Patterns
- Optional deps declared in `mix.exs` with `optional: true` — Ecto, Postgrex, AMQP, Spear all follow this pattern
- Conditional module compilation: `if Code.ensure_loaded?(SomeDep) do defmodule ... end`
- Adapter returns data structures (Ecto.Multi for Postgres); GenServer owns transaction/execution
- `child_spec/1` in projector macro injects `storage_adapter:` and `adapter_opts:` into GenServer config
- Structured logging with `orkestra: :projector` tag; OTel spans via `Tracer.with_span`

### Integration Points
- `Storage` behaviour at `lib/orkestra/projection/storage.ex` — new adapter implements this
- `Projector` macro `child_spec/1` — will need to wire `storage_adapter: Orkestra.Projection.Storage.Elasticsearch` when `backend: :elasticsearch`
- `mix.exs` deps — add `{:snap, "~> 0.16", optional: true}` as optional dependency
- GenServer `apply_event/2` — calls `storage_adapter.write/4`; ES adapter must return compatible ops descriptor

</code_context>

<specifics>
## Specific Ideas

No specific requirements — infrastructure phase. Refer to ROADMAP phase description and success criteria.

</specifics>

<deferred>
## Deferred Ideas

None — infrastructure phase.

</deferred>
