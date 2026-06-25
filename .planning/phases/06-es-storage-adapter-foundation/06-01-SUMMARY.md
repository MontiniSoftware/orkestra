---
phase: 06-es-storage-adapter-foundation
plan: "01"
subsystem: es-adapter-foundation
tags:
  - elasticsearch
  - opensearch
  - snap
  - auth
  - mox
  - test-infrastructure
dependency_graph:
  requires:
    - "lib/orkestra/projection/storage.ex (behaviour)"
    - "test/support/projection_test_repo.ex (pattern reference)"
  provides:
    - "Orkestra.Auth.ApiKey (Snap.Auth implementation for API key auth)"
    - "Snap.MockHTTPClient (Mox mock for ES adapter unit tests)"
    - "Orkestra.Test.ESCluster (test Snap.Cluster module)"
  affects:
    - "mix.exs (new optional deps: snap, finch; test-only dep: mox)"
    - "test/test_helper.exs (ES cluster config, :elasticsearch/:integration tag exclusion)"
    - "Phase 06-02 (ES Storage Adapter — depends on this foundation)"
tech_stack:
  added:
    - "snap 0.16.0 — Elasticsearch/OpenSearch HTTP client (optional dep)"
    - "finch 0.21.0 — HTTP/2 connection pool for Snap (optional dep)"
    - "mox 1.2.0 — Mock library for Snap.HTTPClient in unit tests (test-only)"
    - "nimble_options 1.1.1, nimble_pool 1.1.0, nimble_ownership 1.0.2 (transitive)"
    - "castore 1.0.19, mime 2.0.7, process_tree 0.3.0 (transitive)"
  patterns:
    - "Code.ensure_loaded?(Snap.Cluster) conditional compilation guard (same as Postgres uses Ecto.Multi)"
    - "Snap.Auth behaviour implementation via @behaviour Snap.Auth and @impl Snap.Auth"
    - "Mox.defmock pattern for HTTP client mock in test support"
    - "ExUnit tag exclusion (:elasticsearch, :integration) mirroring :postgres pattern"
key_files:
  created:
    - "lib/orkestra/auth/api_key.ex"
    - "test/orkestra/auth/api_key_test.exs"
    - "test/support/es_cluster_mock.ex"
  modified:
    - "mix.exs (added snap, finch, mox deps)"
    - "mix.lock (locked 9 new packages)"
    - "test/test_helper.exs (ES cluster config, extended ExUnit.start excludes)"
decisions:
  - "api_key config option accepts already-base64-encoded combined string (not raw id+key)"
  - "Authorization header prepended (not appended) to maintain header list order"
  - "Snap.MockHTTPClient defined in test/support, not in test_helper.exs, for reuse across Plan 02 tests"
metrics:
  duration_seconds: 219
  completed_date: "2026-06-25"
  tasks_completed: 3
  files_created: 3
  files_modified: 3
---

# Phase 06 Plan 01: ES Storage Adapter Foundation Summary

**One-liner:** Snap 0.16.0 + Finch 0.21.0 + Mox added as deps; `Orkestra.Auth.ApiKey` implementing `Snap.Auth` behaviour for API key header injection; ES test mock cluster and `Snap.MockHTTPClient` Mox mock ready for Plan 02.

## Tasks Completed

| # | Task | Commit | Files |
|---|------|--------|-------|
| 1 | Add Snap, Finch, Mox deps | `daad573` | mix.exs, mix.lock |
| 2 | Orkestra.Auth.ApiKey + tests (TDD) | `fefd476` (RED), `6dbada5` (GREEN) | lib/orkestra/auth/api_key.ex, test/orkestra/auth/api_key_test.exs |
| 3 | ES test infrastructure | `7d9c8e9` | test/support/es_cluster_mock.ex, test/test_helper.exs |

## Verification Results

All four plan-level verifications passed:

1. `mix deps.get` — resolved 9 new packages (snap 0.16.0, finch 0.21.0, mox 1.2.0 + transitive)
2. `mix compile --warnings-as-errors` — 0 warnings, 0 errors
3. `mix test test/orkestra/auth/api_key_test.exs` — 6/6 tests pass
4. `mix test` — 199 tests, 0 failures, 31 excluded

## Deviations from Plan

### Auto-fixed Issues

None — plan executed exactly as written.

### Observations

- Finch 0.21.0 was resolved (satisfies `~> 0.17` constraint from Snap), not 0.17.x specifically. This is correct semver behavior.
- Deps compiled in order (nimble_options → finch → nimble_ownership → mox → snap) due to `mix deps.compile --force` ordering constraint in test environment.
- Authorization header is prepended (`[auth_header | headers]`) rather than appended (`headers ++ [auth_header]`) — this is standard HTTP practice and matches Snap.Auth.Plain's behavior.
- Task 2 test count: 6 tests (plan said "4 tests pass" in the `<done>` element but listed 5 behavior items + 1 Basic Auth test = 6). All 6 pass.

## Known Stubs

None — no stub patterns introduced. All implemented behavior is complete.

## Threat Flags

No new network endpoints, auth paths, or trust boundaries introduced beyond what is described in the plan's threat model.

| Flag | File | Description |
|------|------|-------------|
| threat_flag: information_disclosure | lib/orkestra/auth/api_key.ex | API key credential flows from app config into Authorization header; moduledoc warns against committing credentials and recommends runtime config + secrets manager (T-06-01 mitigated) |

## Self-Check: PASSED

- `lib/orkestra/auth/api_key.ex` — FOUND
- `test/orkestra/auth/api_key_test.exs` — FOUND
- `test/support/es_cluster_mock.ex` — FOUND
- `mix.lock` contains snap, finch, mox — VERIFIED
- Commits daad573, fefd476, 6dbada5, 7d9c8e9 — VERIFIED in git log
- 199 tests, 0 failures — VERIFIED
