# Phase 11: MCP Generator and Introspection - Context

**Gathered:** 2026-06-25
**Status:** Ready for planning
**Mode:** Auto-generated (infrastructure phase — discuss skipped)

<domain>
## Phase Boundary

Add `gen_es_projection` MCP tool that scaffolds a complete ES projector module (with `use Orkestra.Projector, backend: :elasticsearch`, `project_es/2` handlers, and `index_mapping/0`). Update `domain_map` and `ListProjections` introspection resources to surface ES projections alongside Postgres projections.

Requirements covered: MCP-01, MCP-02.

</domain>

<decisions>
## Implementation Decisions

### Claude's Discretion
All implementation choices are at Claude's discretion — pure infrastructure phase. Key guidelines:

- **`gen_es_projection` tool:** Follow existing `gen_projection` pattern in orkestra_mcp — same structure, adapted for ES backend options (cluster, index, events)
- **`domain_map` resource:** Update to detect and display ES projectors alongside Postgres ones
- **`ListProjections` resource:** Update to include ES projections with their backend type, cluster, and index info
- **Detection pattern:** Use `__projection_config__/0` which now includes `:backend`, `:cluster`, `:index` fields (added in Phase 8)

</decisions>

<code_context>
## Existing Code Insights

### Reusable Assets
- `OrkestraMcp.Tools.GenProjection` — existing Postgres projection generator
- `OrkestraMcp.Generator.gen_projection/2` — existing generator function
- `OrkestraMcp.Resources.ListProjections` — existing introspection resource
- `OrkestraMcp.Resources.DomainMap` — existing domain map resource

### Integration Points
- `orkestra_mcp/lib/orkestra_mcp/server.ex` — tool and resource registration
- `orkestra_mcp/lib/orkestra_mcp/generator.ex` — generator functions
- `orkestra_mcp/lib/orkestra_mcp/tools/` — tool implementations
- `orkestra_mcp/lib/orkestra_mcp/resources/` — resource implementations

</code_context>

<specifics>
## Specific Ideas

No specific requirements — infrastructure phase.

</specifics>

<deferred>
## Deferred Ideas

None.

</deferred>
