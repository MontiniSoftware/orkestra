# Phase 10: ES Query DSL Builder - Context

**Gathered:** 2026-06-25
**Status:** Ready for planning
**Mode:** Auto-generated (infrastructure phase — discuss skipped)

<domain>
## Phase Boundary

Create an Elixir module `Orkestra.Projection.ES.Query` that provides a pipe-based DSL for composing Elasticsearch queries (bool, match, filter, range, aggs). The DSL should produce the JSON query map that Snap.Search.search/4 accepts. Optionally scaffold a generated `ES.Queries` module per projection with common search operations (similar to the existing Postgres gen_queries pattern).

Requirements covered: QDSL-01, QDSL-02.

</domain>

<decisions>
## Implementation Decisions

### Claude's Discretion
All implementation choices are at Claude's discretion — pure infrastructure phase. Key guidelines:

- **Pipe-based DSL:** `Query.new() |> Query.must(match: %{"field" => "value"}) |> Query.filter(range: %{"date" => %{"gte" => "2024-01-01"}}) |> Query.build()` → produces ES JSON query map
- **Composable:** Each function returns the query struct for piping
- **Output:** `build/1` returns the final `%{"query" => %{"bool" => ...}}` map ready for `Snap.Search.search/4`
- **Aggregations:** Support `aggs/2` for adding aggregation clauses
- **Generated Queries module:** `Orkestra.Projection.ES.Queries` template similar to Postgres `gen_queries` — list/get_by/search helpers wrapping the DSL

</decisions>

<code_context>
## Existing Code Insights

### Reusable Assets
- Existing Postgres Queries generator pattern in orkestra_mcp
- `Snap.Search.search/4` — executes search queries against ES
- `Orkestra.Projection.Storage.Elasticsearch` — has cluster and index info

### Integration Points
- Query DSL is standalone — no dependencies on GenServer or projector macro
- Generated Queries module would use the DSL internally
- MCP generator (Phase 11) will scaffold ES.Queries modules

</code_context>

<specifics>
## Specific Ideas

No specific requirements — infrastructure phase.

</specifics>

<deferred>
## Deferred Ideas

- Search/count/get_by_id helpers (QHLP-01) — deferred to future

</deferred>
