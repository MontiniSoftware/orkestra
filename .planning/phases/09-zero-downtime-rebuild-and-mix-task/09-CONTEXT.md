# Phase 9: Zero-Downtime Rebuild and Mix Task - Context

**Gathered:** 2026-06-25
**Status:** Ready for planning
**Mode:** Auto-generated (infrastructure phase — discuss skipped)

<domain>
## Phase Boundary

Implement `mix orkestra.projection.es.rebuild` Mix task that creates a versioned index, replays all events through the projector, atomically swaps the alias using `Snap.Indexes.hotswap/5`, and cleans up the old index — without any search downtime. Live writes must be paused during alias swap to prevent race conditions.

Requirements covered: RBLD-01, RBLD-02, RBLD-03.

</domain>

<decisions>
## Implementation Decisions

### Claude's Discretion
All implementation choices are at Claude's discretion — pure infrastructure phase. Key constraints from STATE.md:

- **Zero-downtime:** Use ES/OpenSearch index alias pattern — write to versioned index, swap alias atomically
- **`Snap.Indexes.hotswap/5`:** Snap provides atomic alias swap out of the box (verified in Phase 6 research)
- **Versioned index naming:** `{base_index}_v{timestamp}` or similar scheme
- **Live write pause (RBLD-03):** During alias swap, live writes must be paused to prevent race. Strategy: Postgres advisory lock or GenServer-level pause
- **Event replay:** Use EventStore catch-up subscription from position 0 with `rebuild_total` set
- **Cleanup:** Delete old versioned index after successful swap

### Mix Task Pattern
- Follow existing `mix orkestra.projection.*` task pattern from v1.0
- Task discovers ES projectors via `__projection_config__/0` (already extended in Phase 8)
- Accepts projector module as argument

</decisions>

<code_context>
## Existing Code Insights

### Reusable Assets
- Existing Mix tasks: `lib/mix/tasks/orkestra.projection.*.ex` — migrate, rollback, drop, rebuild
- `Snap.Indexes.hotswap/5` — atomic alias swap
- `Orkestra.Projector.GenServer` — catch-up mode with `rebuild_total` and bulk buffering
- `Orkestra.Projection.Storage.Elasticsearch` — `init/1`, `write/4`, `reset/2`

### Integration Points
- Mix task → GenServer (start rebuild, monitor progress)
- GenServer rebuild mode → bulk flush → alias swap → cleanup
- Telemetry: rebuild progress already emitted by GenServer

</code_context>

<specifics>
## Specific Ideas

No specific requirements — infrastructure phase.

</specifics>

<deferred>
## Deferred Ideas

- Rebuild crash recovery (persisted state) — deferred to future (RRES-01)

</deferred>
