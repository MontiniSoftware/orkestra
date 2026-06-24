# Phase 4: Telemetry & Observability - Context

**Gathered:** 2026-06-24
**Status:** Ready for planning
**Mode:** Auto-generated (infrastructure phase — discuss skipped)

<domain>
## Phase Boundary

Phase 4 adds OpenTelemetry instrumentation and `:telemetry` metrics to the projection
subsystem. Each event processed by a projector emits an OTel span consistent with existing
`Orkestra.Telemetry` conventions. Positional lag, rebuild progress, and halt status are
exposed as metrics for operator alerting and diagnostics.

</domain>

<decisions>
## Implementation Decisions

### Claude's Discretion
All implementation choices are at Claude's discretion — pure infrastructure phase. Use ROADMAP phase goal, success criteria, existing `Orkestra.Telemetry` module conventions, and codebase patterns to guide decisions.

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
