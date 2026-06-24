---
phase: 05-mcp-integration-and-query-helpers
verified: 2026-06-24T22:00:00Z
status: gaps_found
score: 3/10
overrides_applied: 0
gaps:
  - truth: "GenProjection tool creates both a projector module file and a migration file in a single invocation"
    status: failed
    reason: "orkestra_mcp/lib/orkestra_mcp/tools/gen_projection.ex does not exist — Plan 02 was never executed"
    artifacts:
      - path: "orkestra_mcp/lib/orkestra_mcp/tools/gen_projection.ex"
        issue: "File missing — not created"
    missing:
      - "Create GenProjection tool module following the GenAggregate pattern"
      - "Tool must call Generator.gen_projection/3 + Generator.gen_projection_migration/2 and write both files"

  - truth: "GenReadModel tool creates both a schema module file and a migration file in a single invocation"
    status: failed
    reason: "orkestra_mcp/lib/orkestra_mcp/tools/gen_read_model.ex does not exist — Plan 02 was never executed"
    artifacts:
      - path: "orkestra_mcp/lib/orkestra_mcp/tools/gen_read_model.ex"
        issue: "File missing — not created"
    missing:
      - "Create GenReadModel tool module"
      - "Tool must call Generator.gen_read_model/2 + Generator.gen_read_model_migration/2 and write both files"

  - truth: "GenQueries tool creates a Queries module with list/2 and get_by/2 functions"
    status: failed
    reason: "orkestra_mcp/lib/orkestra_mcp/tools/gen_queries.ex does not exist — Plan 02 was never executed"
    artifacts:
      - path: "orkestra_mcp/lib/orkestra_mcp/tools/gen_queries.ex"
        issue: "File missing — not created"
    missing:
      - "Create GenQueries tool module"
      - "Tool must call Generator.gen_queries/2 and write the file"

  - truth: "All tool responses include the Created path(s) and the generated source code"
    status: failed
    reason: "No tool modules exist — Plan 02 was not executed"
    artifacts: []
    missing:
      - "Depends on creation of all three tool modules above"

  - truth: "Introspection.discover/1 returns a :projectors key containing detected projector modules with their repo and event info"
    status: failed
    reason: "introspection.ex has no :projectors key in discover/1 accumulator and no detect_projectors/2 function — Plan 03 was never executed"
    artifacts:
      - path: "orkestra_mcp/lib/orkestra_mcp/introspection.ex"
        issue: "discover/1 returns only 5 keys (commands, events, command_handlers, event_handlers, aggregates); :projectors key is absent"
    missing:
      - "Add :projectors to the discover/1 accumulator"
      - "Add detect_projectors/2 private function"
      - "Add extract_projected_events/1 helper"
      - "Pipe detect_projectors/2 through parse_file/2"

  - truth: "ListProjections resource returns JSON of all discovered projectors when read"
    status: failed
    reason: "orkestra_mcp/lib/orkestra_mcp/resources/list_projections.ex does not exist — Plan 03 was never executed"
    artifacts:
      - path: "orkestra_mcp/lib/orkestra_mcp/resources/list_projections.ex"
        issue: "File missing — not created"
    missing:
      - "Create ListProjections resource following the ListAggregates pattern"
      - "Resource URI: orkestra://projections"

  - truth: "build_domain_map/1 includes projector entries with the (projector) label"
    status: failed
    reason: "build_domain_map/1 does not include projectors — it only handles commands, events, aggregates, command_handlers, event_handlers"
    artifacts:
      - path: "orkestra_mcp/lib/orkestra_mcp/introspection.ex"
        issue: "build_domain_map/1 does not destructure :projectors and does not append projector lines"
    missing:
      - "Add :projectors destructuring in build_domain_map/1"
      - "Append projector lines with '(projector)' label and projected events with '(projected_event)' sub-lines"

  - truth: "Server registers all four new components (3 tools + 1 resource)"
    status: failed
    reason: "server.ex has not been updated — GenProjection, GenReadModel, GenQueries tools and ListProjections resource are absent from component registrations"
    artifacts:
      - path: "orkestra_mcp/lib/orkestra_mcp/server.ex"
        issue: "Only pre-existing components are registered; no new components from Phase 05 Plans 02/03"
    missing:
      - "Add component(OrkestraMcp.Tools.GenProjection)"
      - "Add component(OrkestraMcp.Tools.GenReadModel)"
      - "Add component(OrkestraMcp.Tools.GenQueries)"
      - "Add component(OrkestraMcp.Resources.ListProjections)"
---

# Phase 05: MCP Integration and Query Helpers — Verification Report

**Phase Goal:** Developers using orkestra_mcp can scaffold new projections with a generator command, inspect existing projections via MCP resources, and optionally use a generated Queries module for common read patterns
**Verified:** 2026-06-24T22:00:00Z
**Status:** gaps_found
**Re-verification:** No — initial verification

## Goal Achievement

### Observable Truths

| # | Truth | Status | Evidence |
|---|-------|--------|----------|
| 1 | Generator.gen_projection/3 returns valid Elixir source with `use Orkestra.Projector` and project clauses | VERIFIED | Function exists in generator.ex (L181-215); 2 tests pass in generator_test.exs |
| 2 | Generator.gen_projection_migration/2 returns valid Elixir migration source with path under priv/projections/ | VERIFIED | Function exists in generator.ex (L226-266); test at L159-171 passes |
| 3 | Generator.gen_read_model/2 returns valid Elixir source with `use Ecto.Schema` and schema block | VERIFIED | Function exists in generator.ex (L273-296); test at L174-189 passes |
| 4 | Generator.gen_read_model_migration/2 returns valid Elixir migration source for the read model table | PASSED (partial) | Function exists in generator.ex (L304-333); test at L193-204 passes. Classified VERIFIED at generator level — the MCP tool wiring is what's missing. |
| 5 | Generator.gen_queries/2 returns valid Elixir source with list/2 (paged) and get_by/2 functions | VERIFIED | Function exists in generator.ex (L342-386); test at L207-219 passes; list/2 has page/page_size/offset; get_by/2 has keyword filter |
| 6 | Naming.module_to_table_name/1 converts a module name to a pluralised table name | VERIFIED | Function exists in naming.ex (L25-31); 2 tests pass |
| 7 | GenProjection tool creates both a projector module file and a migration file in a single invocation | FAILED | orkestra_mcp/lib/orkestra_mcp/tools/gen_projection.ex does not exist |
| 8 | GenReadModel tool creates both a schema module file and a migration file in a single invocation | FAILED | orkestra_mcp/lib/orkestra_mcp/tools/gen_read_model.ex does not exist |
| 9 | GenQueries tool creates a Queries module with list/2 and get_by/2 functions | FAILED | orkestra_mcp/lib/orkestra_mcp/tools/gen_queries.ex does not exist |
| 10 | Introspection.discover/1 returns a :projectors key with detected projector modules, repo, and event info | FAILED | introspection.ex discover/1 returns 5 keys; no :projectors, no detect_projectors/2 |
| 11 | ListProjections resource returns JSON of all discovered projectors when read | FAILED | orkestra_mcp/lib/orkestra_mcp/resources/list_projections.ex does not exist |
| 12 | build_domain_map/1 includes projector entries with the (projector) label | FAILED | build_domain_map/1 handles only commands/events/handlers/aggregates; no projector lines |
| 13 | Server registers all four new components (3 tools + 1 resource) | FAILED | server.ex registers only 5 pre-existing tools and 5 pre-existing resources; no Phase 05 components |

**Score:** 3/10 truths verified (generator layer complete; tool and introspection layers absent)

Note: Truths 1-6 map to Plan 01 (pure generator functions). Truths 7-13 map to Plans 02 and 03, neither of which was executed.

### Required Artifacts

| Artifact | Expected | Status | Details |
|----------|----------|--------|---------|
| `orkestra_mcp/lib/orkestra_mcp/generator.ex` | Five new generator functions | VERIFIED | All 5 functions present and substantive: gen_projection, gen_projection_migration, gen_read_model, gen_read_model_migration, gen_queries |
| `orkestra_mcp/lib/orkestra_mcp/naming.ex` | module_to_table_name/1 helper | VERIFIED | Function present at L25-31 |
| `orkestra_mcp/test/orkestra_mcp/generator_test.exs` | Unit tests for all 5 generator functions + naming | VERIFIED | 17 total tests, 0 failures; 10 new tests with Code.string_to_quoted assertions |
| `orkestra_mcp/lib/orkestra_mcp/tools/gen_projection.ex` | MCP tool scaffolding projector + migration | MISSING | File does not exist — Plan 02 not executed |
| `orkestra_mcp/lib/orkestra_mcp/tools/gen_read_model.ex` | MCP tool scaffolding Ecto schema + migration | MISSING | File does not exist — Plan 02 not executed |
| `orkestra_mcp/lib/orkestra_mcp/tools/gen_queries.ex` | MCP tool scaffolding Queries module | MISSING | File does not exist — Plan 02 not executed |
| `orkestra_mcp/test/orkestra_mcp/tools/gen_projection_test.exs` | Tool-level test for GenProjection | MISSING | File does not exist — Plan 02 not executed |
| `orkestra_mcp/test/orkestra_mcp/tools/gen_read_model_test.exs` | Tool-level test for GenReadModel | MISSING | File does not exist — Plan 02 not executed |
| `orkestra_mcp/test/orkestra_mcp/tools/gen_queries_test.exs` | Tool-level test for GenQueries | MISSING | File does not exist — Plan 02 not executed |
| `orkestra_mcp/lib/orkestra_mcp/resources/list_projections.ex` | ListProjections resource module | MISSING | File does not exist — Plan 03 not executed |
| `orkestra_mcp/lib/orkestra_mcp/introspection.ex` | detect_projectors/2, extract_projected_events/1, extended build_domain_map/1 | STUB | File exists but is missing all projector-related additions from Plan 03 |
| `orkestra_mcp/lib/orkestra_mcp/server.ex` | Registration of 3 new tools + 1 resource | STUB | File exists but registers only pre-existing components — no Phase 05 additions |
| `orkestra_mcp/test/fixtures/sample_project/lib/my_app/orders/projectors/order_projector.ex` | Fixture projector file for introspection tests | MISSING | Directory does not exist — Plan 03 not executed |

### Key Link Verification

| From | To | Via | Status | Details |
|------|----|-----|--------|---------|
| generator.ex | naming.ex | Naming.module_to_table_name/1 call | WIRED | gen_read_model/2 at L278 calls Naming.module_to_table_name; Naming is aliased at L4 |
| generator.ex | naming.ex | Naming.module_to_file_path/1 calls | WIRED | All generator functions call Naming.module_to_file_path; Naming aliased at L4 |
| tools/gen_projection.ex | generator.ex | Generator.gen_projection/3 + gen_projection_migration/2 + write!/3 | NOT_WIRED | gen_projection.ex does not exist |
| tools/gen_read_model.ex | generator.ex | Generator.gen_read_model/2 + gen_read_model_migration/2 + write!/3 | NOT_WIRED | gen_read_model.ex does not exist |
| tools/gen_queries.ex | generator.ex | Generator.gen_queries/2 + write!/3 | NOT_WIRED | gen_queries.ex does not exist |
| resources/list_projections.ex | introspection.ex | Introspection.discover/1 extracting :projectors | NOT_WIRED | list_projections.ex does not exist; :projectors key absent from discover/1 |
| server.ex | tools/*.ex and resources/list_projections.ex | component() macro registrations | NOT_WIRED | server.ex not updated; no Phase 05 component registrations |

### Data-Flow Trace (Level 4)

| Artifact | Data Variable | Source | Produces Real Data | Status |
|----------|---------------|--------|--------------------|--------|
| tools/gen_projection.ex | projector source + migration source | Generator.gen_projection/3 + Generator.gen_projection_migration/2 | N/A | DISCONNECTED — tool file does not exist |
| resources/list_projections.ex | projectors list | Introspection.discover/1 :projectors key | N/A | DISCONNECTED — resource file does not exist; source key absent |

### Behavioral Spot-Checks

| Behavior | Command | Result | Status |
|----------|---------|--------|--------|
| Generator.gen_projection/3 returns valid source | mix test test/orkestra_mcp/generator_test.exs (17 tests, 0 failures) | All 17 tests pass | PASS |
| GenProjection tool creates files | tools/gen_projection.ex exists | File not found | FAIL |
| ListProjections resource returns projectors | resources/list_projections.ex exists | File not found | FAIL |
| Server registers Phase 05 components | component(OrkestraMcp.Tools.GenProjection) in server.ex | Not present in server.ex | FAIL |
| Introspection.discover/1 has :projectors key | grep ":projectors" introspection.ex | No match | FAIL |

### Requirements Coverage

| Requirement | Source Plan | Description | Status | Evidence |
|-------------|------------|-------------|--------|----------|
| READ-02 | 05-01 | Optional generated Queries module with list/1 (paged) and get_by/2 | PARTIAL | Generator.gen_queries/2 produces valid source (Plan 01 complete); GenQueries MCP tool missing (Plan 02 not executed) — developer cannot invoke scaffolding through MCP |
| MCP-01 | 05-01, 05-02 | MCP server provides gen_projection generator scaffolding projector + migration | BLOCKED | Generator functions exist (Plan 01); MCP tool modules missing (Plan 02 not executed); server.ex not updated |
| MCP-02 | 05-01, 05-02 | MCP server provides gen_read_model generator (schema + migration scaffolding) | BLOCKED | Generator functions exist (Plan 01); MCP tool modules missing (Plan 02 not executed); server.ex not updated |
| MCP-03 | 05-03 | Projections surfaced in MCP introspection resources | BLOCKED | Plan 03 not executed; introspection.ex has no projector detection; list_projections.ex missing; server.ex not updated |

### Anti-Patterns Found

| File | Line | Pattern | Severity | Impact |
|------|------|---------|----------|--------|
| orkestra_mcp/lib/orkestra_mcp/generator.ex | 184-188 | TODO comment in gen_projection empty-events branch | Info | Expected — placeholder for developer to fill in; consistent with gen_command_handler pattern |
| orkestra_mcp/lib/orkestra_mcp/generator.ex | 251-258 | TODO comments in gen_projection_migration up/down | Info | Expected — migration scaffold requires developer customization; the scaffold intent is to show example code |
| orkestra_mcp/lib/orkestra_mcp/generator.ex | 323-325 | TODO comment in gen_read_model_migration change/0 | Info | Expected — same scaffold pattern as above |

No blockers found in Plan 01 artifacts. The TODO patterns are intentional scaffold placeholders, not implementation stubs — they are the generated output developers are meant to customize.

### Human Verification Required

None identified. All gaps are programmatically observable (missing files, absent function definitions, unregistered components).

### Gaps Summary

**Root cause:** Plans 02 and 03 were planned but not executed. The phase has no SUMMARY.md for Plan 02 or Plan 03. The only commit activity for Phase 05 is commits `1359537` and `419a6e2` (Plan 01 only).

**Plan 01 (generator foundation) — COMPLETE:**
Plan 01 is fully complete. Five pure generator functions and the `module_to_table_name/1` naming helper are implemented, tested with 10 new tests (17 total passing), and committed. This is the foundation layer.

**Plan 02 (MCP tool modules) — NOT EXECUTED:**
Three tool modules (`gen_projection.ex`, `gen_read_model.ex`, `gen_queries.ex`) and their six test files are entirely absent. These modules bridge the generator functions to the MCP interface, making the scaffold commands invokable by developers. Without them, the generators exist as library code with no MCP exposure.

**Plan 03 (introspection + server wiring) — NOT EXECUTED:**
`introspection.ex` has no projector detection (`detect_projectors/2`, `:projectors` key, `extract_projected_events/1`). `build_domain_map/1` does not include projectors. `list_projections.ex` does not exist. `server.ex` does not register any Phase 05 components. The fixture projector file and updated introspection tests are also absent.

**Impact on phase goal:**
The stated phase goal — "developers using orkestra_mcp can scaffold new projections with a generator command" — is not achievable. The generator functions exist but are not wired into any MCP tool. A developer using an MCP client has no `gen_projection`, `gen_read_model`, or `gen_queries` tool to invoke. Similarly, `list_projections` and projector entries in `domain_map` are absent.

**Gap grouping:**
Both Plan 02 and Plan 03 gaps share a single root cause: neither plan was executed. Plans 02 and 03 are largely independent (Plan 03 depends only on Plan 01 for introspection; Plan 02 depends only on Plan 01 for generator calls). They can be replanned and executed separately. The structured gaps above map directly to the must-haves in their respective PLAN.md frontmatters, enabling `/gsd-plan-phase --gaps` to target them precisely.

---

_Verified: 2026-06-24T22:00:00Z_
_Verifier: Claude (gsd-verifier)_
