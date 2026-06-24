# Phase 5: MCP Integration and Query Helpers - Context

**Gathered:** 2026-06-24
**Status:** Ready for planning
**Mode:** Auto-generated (infrastructure phase — discuss skipped)

<domain>
## Phase Boundary

Phase 5 extends orkestra_mcp with projection-aware generators and introspection, and
adds an optional generated Queries module per read model. Concretely:
1. `gen_projection` MCP tool — scaffolds a projector module + its isolated migration file
2. `gen_read_model` MCP tool — scaffolds the Ecto schema and migration
3. MCP resources (`list_projections`, `domain_map`) — surface all defined projectors and
   their read models alongside existing aggregates and event handlers
4. Optional `Queries` module per read model — exposes `list/1` (paged) and `get_by/2`

</domain>

<decisions>
## Implementation Decisions

### Claude's Discretion
All implementation choices are at Claude's discretion — infrastructure phase with well-established
patterns in the existing codebase. Follow the existing `gen_*` tool and `list_*` resource patterns
in `orkestra_mcp/` exactly. Use ROADMAP phase goal, success criteria, and codebase conventions to
guide decisions.

</decisions>

<code_context>
## Existing Code Insights

Codebase context will be gathered during plan-phase research.

</code_context>

<specifics>
## Specific Ideas

No specific requirements — infrastructure phase. Refer to ROADMAP phase description and success criteria.

</specifics>

<deferred>
## Deferred Ideas

None — discuss phase skipped.

</deferred>
