# Phase 8: Projector Macro DSL for Elasticsearch - Context

**Gathered:** 2026-06-25
**Status:** Ready for planning
**Mode:** Auto-generated (infrastructure phase — discuss skipped)

<domain>
## Phase Boundary

Extend the existing `Orkestra.Projector` macro to support `backend: :elasticsearch` option with a `project_es/2` macro for ES-specific event handlers. The generated `child_spec/1` must wire the ES storage adapter (`Orkestra.Projection.Storage.Elasticsearch`) automatically. Existing Postgres projectors must continue working unchanged. Checkpoint writes follow ES-first, Postgres-second ordering (ADPT-07).

Requirements covered: ADPT-05, ADPT-07.

</domain>

<decisions>
## Implementation Decisions

### Claude's Discretion
All implementation choices are at Claude's discretion — pure infrastructure phase. Key constraints:

- **`backend: :elasticsearch`** option on `use Orkestra.Projector` — selects ES adapter
- **`project_es/2` macro** — analogous to existing `project/2` but for ES handlers; handler returns `{:ok, doc, id} | :skip | {:error, reason}` instead of `{:ok, Ecto.Multi.t()}`
- **`index_mapping/0` callback** — ES projector defines its index mapping (ADPT-06, already in adapter from Phase 6)
- **`child_spec/1` wiring** — when `backend: :elasticsearch`, inject `storage_adapter: Orkestra.Projection.Storage.Elasticsearch` and `adapter_opts: [cluster: ..., index: ..., handler: &__MODULE__.__handle_es__/3]`
- **Checkpoint ordering (ADPT-07):** ES-first, Postgres-second — already implemented in Phase 7 GenServer; DSL just needs to wire it correctly
- **Backward compatibility:** Existing `project/2` macro and Postgres `child_spec/1` must work identically — no breaking changes

### Handler Function
- ES handler: `__handle_es__/3` takes `(projector_name, event, position)` and returns `{:ok, doc, id} | :skip | {:error, reason}`
- This matches the `:handler` option pattern from the Postgres adapter (Phase 6)
- `project_es/2` macro accumulates handler functions and generates `__dispatch_es__/3` + `__handle_es__/3` (mirroring `__dispatch__/3` + `__handle__/3`)

</decisions>

<code_context>
## Existing Code Insights

### Reusable Assets
- `Orkestra.Projector` at `lib/orkestra/projector.ex` — existing `project/2` macro, `__dispatch__/3`, `__handle__/3`, `child_spec/1`, `__projection_config__/0`
- `Orkestra.Projection.Storage.Elasticsearch` at `lib/orkestra/projection/storage/elasticsearch.ex` — `write/4`, `reset/2`, `init/1`
- `Orkestra.Projector.GenServer` at `lib/orkestra/projector/gen_server.ex` — handles both Postgres and ES commit paths

### Established Patterns
- `project/2` macro collects handler defs via `Module.register_attribute(__MODULE__, :es_project_defs, accumulate: true)`
- `__before_compile__` callback generates dispatch functions from accumulated defs
- `child_spec/1` injects `storage_adapter`, `adapter_opts` into GenServer config

### Integration Points
- `projector.ex` — add `backend:` option parsing, `project_es/2` macro, ES-specific `child_spec/1` branch
- Existing tests for projector macro must pass unchanged

</code_context>

<specifics>
## Specific Ideas

No specific requirements — infrastructure phase.

</specifics>

<deferred>
## Deferred Ideas

None.

</deferred>
