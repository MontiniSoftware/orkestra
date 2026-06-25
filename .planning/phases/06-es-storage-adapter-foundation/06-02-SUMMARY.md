---
phase: 06-es-storage-adapter-foundation
plan: "02"
subsystem: es-adapter
tags:
  - elasticsearch
  - opensearch
  - snap
  - storage-adapter
  - tdd
  - mox
dependency_graph:
  requires:
    - "Orkestra.Projection.Storage behaviour (lib/orkestra/projection/storage.ex)"
    - "Snap 0.16.0 optional dep (Phase 06-01)"
    - "Snap.MockHTTPClient Mox mock (Phase 06-01)"
    - "Orkestra.Test.ESCluster (Phase 06-01)"
  provides:
    - "Orkestra.Projection.Storage.Elasticsearch (Storage behaviour implementation)"
    - "Orkestra.Test.ESHTTPAdapter (test HTTP adapter that bridges Snap.Cluster and Mox)"
  affects:
    - "test/support/es_cluster_mock.ex (added ESHTTPAdapter)"
    - "test/test_helper.exs (ESCluster started with ESHTTPAdapter)"
tech_stack:
  added:
    - "Snap.HTTPClient.request/5 called directly for GET / (bypasses Snap path validation)"
    - "Orkestra.Test.ESHTTPAdapter — real Snap.HTTPClient impl that delegates request/6 to Mox mock"
  patterns:
    - "Code.ensure_loaded?(Snap.Cluster) conditional compilation guard"
    - "@behaviour Orkestra.Projection.Storage with @impl true callbacks"
    - "Snap.HTTPClient.request direct call for root path (bypasses validate_path)"
    - "Snap.Indexes.create with dynamic:strict injected via Map.update/Map.put"
    - "Mox delegate adapter pattern: real child_spec/:skip + Mox-delegating request/6"
key_files:
  created:
    - "lib/orkestra/projection/storage/elasticsearch.ex"
    - "test/orkestra/projection/storage/elasticsearch_test.exs"
  modified:
    - "test/support/es_cluster_mock.ex (added Orkestra.Test.ESHTTPAdapter)"
    - "test/test_helper.exs (ESCluster startup + ESHTTPAdapter config)"
decisions:
  - "detect_engine calls Snap.HTTPClient.request with full URL (not Snap.get('/')) — Snap path validator rejects '/' as empty segment"
  - "Orkestra.Test.ESHTTPAdapter wraps Snap.MockHTTPClient: real child_spec returns :skip to avoid Mox inter-process ownership error in Snap.Cluster.Supervisor.init"
  - "ensure_index enforces dynamic:strict via Map.put (not Map.put_new) — always overrides to prevent user accidentally setting dynamic:true"
  - "reset/2 error pattern wraps raw reason: {:error, {:reset_failed, %Snap.HTTPClient.Error{}}} — tests assert on struct pattern, not atom"
metrics:
  duration_seconds: 688
  completed_date: "2026-06-25"
  tasks_completed: 1
  files_created: 2
  files_modified: 2
---

# Phase 06 Plan 02: ES Storage Adapter — Summary

**One-liner:** `Orkestra.Projection.Storage.Elasticsearch` implementing the Storage behaviour with purely-functional `write/4` descriptor returns, `_delete_by_query` reset, runtime engine detection (ES 8.x vs OpenSearch 2.x), and `dynamic:strict` index management — 15 tests passing via Mox HTTP mocks.

## Tasks Completed

| # | Task | Commit | Files |
|---|------|--------|-------|
| 1 (RED) | Failing tests for ES adapter | `d32582e` | test/orkestra/projection/storage/elasticsearch_test.exs |
| 1 (GREEN) | ES adapter implementation | `a6cf7bc` | lib/orkestra/projection/storage/elasticsearch.ex, test/support/es_cluster_mock.ex, test/test_helper.exs |

## Verification Results

All plan-level verifications passed:

1. `mix compile --warnings-as-errors` — 0 warnings, 0 errors
2. `mix test test/orkestra/projection/storage/elasticsearch_test.exs --include elasticsearch` — 15/15 pass
3. `mix test test/orkestra/auth/api_key_test.exs` — 6/6 pass (no regression)
4. `mix test` — 214 tests, 0 failures, 46 excluded
5. `grep -c "Snap.Document" lib/orkestra/projection/storage/elasticsearch.ex` — 2 (both in @moduledoc, not in executable code)

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 1 - Bug] Snap.get(cluster, "/") fails path validation**

- **Found during:** Task 1 (GREEN phase), detect_engine implementation
- **Issue:** `Snap.Request.validate_path("/")` splits `""` by `"/"` producing `[""]`, which contains an empty segment and is rejected as a path traversal risk
- **Fix:** Changed `detect_engine/1` to call `Snap.HTTPClient.request(cluster, :get, base_url, [], nil)` with the full URL directly, bypassing Snap's path validator. `base_url` is extracted from `cluster.config()` via `Keyword.fetch!(config, :url)`. The response is JSON-decoded manually using `cluster.json_library()`.
- **Files modified:** `lib/orkestra/projection/storage/elasticsearch.ex`
- **Commit:** `a6cf7bc`

**2. [Rule 3 - Blocker] Mox inter-process ownership error for child_spec/1**

- **Found during:** Task 1 (GREEN phase), test execution
- **Issue:** `Snap.Cluster.Supervisor.init/1` runs in a spawned child process. `Mox.stub(Snap.MockHTTPClient, :child_spec, ...)` in `setup_all` or `test_helper.exs` is owned by the calling process, not the supervisor process. Result: `Mox.UnexpectedCallError` when the supervisor calls `child_spec/1`.
- **Fix:** Created `Orkestra.Test.ESHTTPAdapter` in `test/support/es_cluster_mock.ex` — a real `Snap.HTTPClient` implementation that returns `:skip` from `child_spec/1` and delegates all `request/6` calls to `Snap.MockHTTPClient`. The test cluster is configured with `http_client_adapter: Orkestra.Test.ESHTTPAdapter`. The supervisor now calls real code for `child_spec` and Mox for HTTP requests.
- **Files modified:** `test/support/es_cluster_mock.ex`, `test/test_helper.exs`
- **Commit:** `a6cf7bc`

**3. [Rule 1 - Bug] reset/2 error wraps Snap.HTTPClient.Error struct, not plain atom**

- **Found during:** Task 1 (GREEN phase), test assertion for reset failure
- **Issue:** Test asserted `{:error, {:reset_failed, :econnrefused}}` but Snap returns `%Snap.HTTPClient.Error{reason: :econnrefused, origin: nil}` and adapter wraps it as `{:error, {:reset_failed, %Snap.HTTPClient.Error{}}}`.
- **Fix:** Updated test assertion to match struct pattern `{:error, {:reset_failed, %Snap.HTTPClient.Error{reason: :econnrefused}}}`. The adapter behavior is correct — it wraps whatever Snap returns, which is a struct.
- **Files modified:** `test/orkestra/projection/storage/elasticsearch_test.exs`
- **Commit:** `a6cf7bc`

## Known Stubs

None — all implemented behavior is complete. `write/4` returns real descriptor maps, `reset/2` calls real HTTP (mocked), `init/1` performs real engine detection and index creation logic.

## Threat Flags

| Flag | File | Description |
|------|------|-------------|
| threat_flag: tampering | lib/orkestra/projection/storage/elasticsearch.ex | T-06-03 mitigated: `ensure_index` always injects `dynamic: "strict"` via `Map.put` (overrides any user setting), preventing mapping explosion |
| threat_flag: denial_of_service | lib/orkestra/projection/storage/elasticsearch.ex | T-06-05 mitigated: `detect_engine` defaults to `:elasticsearch` with Logger.warning on connection failure — supervisor tree does not crash |
| threat_flag: information_disclosure | lib/orkestra/projection/storage/elasticsearch.ex | T-06-07 mitigated: moduledoc warns to use runtime config and secrets manager, never commit credentials, always use https:// in production |

## TDD Gate Compliance

- RED gate: `test(06-02)` commit `d32582e` — 15 tests, all failing (module undefined)
- GREEN gate: `feat(06-02)` commit `a6cf7bc` — 15 tests, all passing

## Self-Check: PASSED

- `lib/orkestra/projection/storage/elasticsearch.ex` — FOUND
- `test/orkestra/projection/storage/elasticsearch_test.exs` — FOUND
- `test/support/es_cluster_mock.ex` — FOUND (modified with ESHTTPAdapter)
- `test/test_helper.exs` — FOUND (modified with ESCluster startup)
- Commits d32582e, a6cf7bc — VERIFIED in git log
- 15 ES adapter tests, 0 failures — VERIFIED
- 214 total suite tests, 0 failures — VERIFIED
- `grep -c "Snap.Document" elasticsearch.ex` returns 2 (both in @moduledoc) — VERIFIED
