---
phase: 07-genserver-es-commit-path-and-batch-indexing
plan: "02"
subsystem: projector/gen_server
tags:
  - elasticsearch
  - bulk-indexing
  - genserver
  - otel
  - telemetry
  - testing
dependency_graph:
  requires:
    - 07-01 (ES commit path in GenServer: live single-doc, bulk flush, partial failure detection)
  provides:
    - Integration tests for BULK-01, BULK-02, BULK-03, OBSV-01, OBSV-02
    - Mox-based HTTP mock coverage for Snap.Document.index and Snap.Bulk.perform
    - Verified test patterns for ES projector with Sandbox + InMemory + ESCluster
  affects:
    - CI runs with --include elasticsearch will now execute these tests
tech_stack:
  added: []
  patterns:
    - Mox.stub/2 in setup for default HTTP responses + Mox.expect/4 per-test for strict assertions
    - Mox.allow(Snap.MockHTTPClient, self(), pid) after start_supervised! before event delivery
    - setup :verify_on_exit! for automatic Mox expectation enforcement
    - telemetry attach in setup + on_exit detach for assert_receive-based telemetry assertions
key_files:
  created:
    - test/orkestra/projector/gen_server_es_test.exs
  modified: []
decisions:
  - "ESHTTPAdapter alias removed (unused) — only ESCluster alias needed in ES tests"
  - "Snap.HTTPClient.Error requires both :reason and :origin fields (discovered during compilation)"
  - "Single commit for both tasks since file was created complete in one operation"
metrics:
  duration_seconds: 150
  completed_date: "2026-06-25"
  tasks_completed: 2
  files_modified: 1
---

# Phase 07 Plan 02: ES GenServer Integration Tests Summary

**One-liner:** ExUnit test suite for ES GenServer commit path using Mox HTTP mocks, covering live single-doc Snap.Document.index (BULK-02), catch-up bulk buffer flush at batch_size via Snap.Bulk.perform (BULK-01), partial bulk failure preventing checkpoint advance and triggering halt (BULK-03), OTel span attributes helper correctness (OBSV-01), and es_bulk_flush telemetry event with measurements (OBSV-02).

## Tasks Completed

| Task | Name | Commit | Files |
|------|------|--------|-------|
| 1 | ES GenServer test scaffold + live mode (BULK-02) and catch-up/bulk (BULK-01) tests | 84a1295 | test/orkestra/projector/gen_server_es_test.exs |
| 2 | Partial failure (BULK-03), OTel span (OBSV-01), and telemetry (OBSV-02) tests | 84a1295 | test/orkestra/projector/gen_server_es_test.exs |

## What Was Built

### `test/orkestra/projector/gen_server_es_test.exs` (470 lines)

**Module guard and structure:**
- Wrapped in `if Code.ensure_loaded?(Snap.Cluster)` so the file compiles even when Snap is not available
- `@moduletag :elasticsearch` so tests are excluded by default and opted-in via `--include elasticsearch`
- `import Mox` + `setup :verify_on_exit!` for automatic Mox expectation enforcement

**setup_all:** Runs only the checkpoint/dead_letter migration (`Orkestra.Projection.Migration`) — no read-model table needed since ES tests don't use Ecto read models.

**setup:** Per-test Ecto sandbox checkout in shared mode + fresh InMemory event store + telemetry handler attach for `[:orkestra, :projector, :es_bulk_flush]` + default Mox stub for PUT _doc and POST _bulk.

**Helpers:**
- `unique_projector_name/0` — unique per-test projector names
- `append_event/2` — appends a single event to InMemory store
- `wait_until/1,2` + `poll/2` — polling with deadline for async assertions
- `get_checkpoint/1` — queries Postgres checkpoint row
- `default_es_handler/3` — returns `{:ok, %{"data" => "test"}, "doc-#{position}"}` for all events
- `es_config/2` — builds ES GenServer config with optional `rebuild_total`, `es_batch_size`, `handler`, `index`

**Test cases (6 total):**

| Test | Requirement | Description |
|------|-------------|-------------|
| BULK-02: live mode single doc write | BULK-02 | Mox.expect PUT _doc called exactly once; checkpoint advances to 0 |
| BULK-01: catch-up mode bulk flush at batch_size | BULK-01 | Mox.expect POST _bulk called once after 3 events; checkpoint advances to 2 |
| BULK-01: partial buffer no flush | BULK-01 | After first flush, 2 more events don't trigger second flush (buffer < batch_size) |
| BULK-03: partial bulk failure | BULK-03 | POST _bulk returns `{"errors":true,...}`; checkpoint NOT advanced; projector halts; dead_letter row exists |
| OBSV-02: es_bulk_flush telemetry | OBSV-02 | `assert_receive {:telemetry, :es_bulk_flush, ...}` with batch_size==2, duration_ms integer, projector_name, index, engine |
| OBSV-01: es_span_attrs/4 unit test | OBSV-01 | `Orkestra.Telemetry.es_span_attrs/4` returns correct map with all keys; doc_count included only when non-nil |

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 1 - Bug] Snap.HTTPClient.Error struct requires both :reason and :origin fields**
- **Found during:** Task 1 compilation
- **Issue:** `%Snap.HTTPClient.Error{reason: :unexpected_call}` raised `(ArgumentError) the following keys must also be given when building struct Snap.HTTPClient.Error: [:origin]`
- **Fix:** Added `origin: nil` to the struct literal in the default Mox stub: `%Snap.HTTPClient.Error{reason: :unexpected_call, origin: nil}`
- **Files modified:** test/orkestra/projector/gen_server_es_test.exs
- **Commit:** 84a1295 (part of creation)

**2. [Rule 1 - Bug] Unused alias ESHTTPAdapter caused compilation warning**
- **Found during:** Task 1 compilation (`mix compile --warnings-as-errors`)
- **Issue:** `alias Orkestra.Test.{ESCluster, ESHTTPAdapter}` — `ESHTTPAdapter` is not referenced in test code (it is configured in test_helper.exs, not used directly in test modules)
- **Fix:** Removed `ESHTTPAdapter` from alias, keeping only `alias Orkestra.Test.ESCluster`
- **Files modified:** test/orkestra/projector/gen_server_es_test.exs
- **Commit:** 84a1295 (part of creation)

## Verification Results

| Check | Result |
|-------|--------|
| `mix compile --warnings-as-errors` | PASS — 0 warnings |
| File exists with >= 150 lines | PASS — 470 lines |
| 6 test cases cover all requirements | PASS |
| `grep -c "Snap.MockHTTPClient"` >= 1 | PASS — 11 occurrences |
| `grep -c "es_bulk_flush"` >= 1 | PASS — 6 occurrences |
| Module guard `Code.ensure_loaded?(Snap.Cluster)` | PASS |
| `@moduletag :elasticsearch` | PASS |
| `import Mox` + `setup :verify_on_exit!` | PASS |
| `Mox.allow(Snap.MockHTTPClient, self(), pid)` after start_supervised! | PASS — in tests 1, 2, 3, 4, 5 |
| `mix test --include elasticsearch` (DB not available in env) | Tests tagged :elasticsearch are excluded by test_helper.exs when DB unavailable — behavior matches existing pattern from prior phases |

Note on test execution: Tests require a running PostgreSQL instance (for checkpoint storage) and Elasticsearch is mocked via Mox. In CI with `--include postgres --include elasticsearch`, all 6 tests should pass.

## Known Stubs

None. The test file uses intentional Mox stubs for HTTP simulation — these are correct test infrastructure, not product code stubs.

## Threat Flags

None. No new network endpoints, auth paths, file access patterns, or schema changes introduced. Test file only references existing modules and established mock patterns.

## Self-Check: PASSED

- `test/orkestra/projector/gen_server_es_test.exs` exists (470 lines)
- Commit 84a1295 exists: `test(07-02): create ES GenServer integration tests (BULK-01, BULK-02, BULK-03, OBSV-01, OBSV-02)`
