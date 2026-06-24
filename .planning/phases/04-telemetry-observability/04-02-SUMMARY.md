---
phase: 04-telemetry-observability
plan: "02"
subsystem: projector-observability
tags:
  - telemetry
  - testing
  - projector
  - sandbox
  - ecto

dependency_graph:
  requires:
    - "04-01: GenServer telemetry instrumentation (gen_server.ex, telemetry.ex)"
    - "03-01: Projector GenServer base implementation"
  provides:
    - "ExUnit acceptance tests for TEL-01 through TEL-04"
    - "Fixed Ecto Sandbox migration setup pattern for all postgres test modules"
  affects:
    - "test/orkestra/projector/telemetry_test.exs"
    - "test/orkestra/projector/gen_server_test.exs"
    - "test/orkestra/projection/storage/postgres_test.exs"
    - "test/mix/tasks/projection_tasks_test.exs"

tech_stack:
  added: []
  patterns:
    - "Ecto.Adapters.SQL.Sandbox.unboxed_run for migrations in setup_all (avoids sandbox transaction-task race)"
    - "Application.put_env patch for separate migration_source tables (resolves version 1 collision)"
    - "Sandbox.mode({:shared, self()}) in setup to eliminate GenServer allow/race condition"
    - ":telemetry.attach/4 with tag dispatch via send/2 for assertion-based telemetry testing"

key_files:
  created:
    - "test/orkestra/projector/telemetry_test.exs"
  modified:
    - "test/orkestra/projector/gen_server_test.exs"
    - "test/orkestra/projection/storage/postgres_test.exs"
    - "test/mix/tasks/projection_tasks_test.exs"

key-decisions:
  - "Sandbox.mode({:shared, self()}) in setup instead of per-test Sandbox.allow to eliminate race with GenServer :load_checkpoint processing"
  - "unboxed_run + migration_lock: false to avoid Ecto.Migrator internal Task spawning against a sandboxed connection"
  - "Application.put_env patch with migration_source override to resolve version 1 collision between Orkestra.Projection.Migration and ProjectionMigrations"
  - "Kept Sandbox.allow calls in tests as defensive no-ops (harmless with shared mode, documents intent)"

requirements-completed:
  - TEL-01
  - TEL-02
  - TEL-03
  - TEL-04

duration: ~19min
completed: "2026-06-24"
---

# Phase 04 Plan 02: Projector Telemetry Tests Summary

ExUnit acceptance tests for all four telemetry requirements plus three pre-existing Ecto Sandbox migration bugs fixed across the test suite.

## Performance

- **Duration:** ~19 min
- **Started:** 2026-06-24T18:13:53Z
- **Completed:** 2026-06-24T18:33:52Z
- **Tasks:** 1
- **Files modified:** 4 (1 created, 3 fixed)

## Accomplishments

- Created `telemetry_test.exs` with 6 tests covering lag, rebuild progress, retry, and halt telemetry events
- All 6 telemetry tests pass (`mix test test/orkestra/projector/telemetry_test.exs --include postgres`)
- All existing gen_server_test.exs tests now pass with the same Sandbox fix
- Non-postgres suite unchanged: 193 tests, 0 failures, 31 excluded

## Task Commits

1. **Task 1: Create telemetry test file + fix sandbox setup** - `04723e9` (test)

## Files Created/Modified

- `test/orkestra/projector/telemetry_test.exs` — 6 telemetry acceptance tests (TEL-01 through TEL-04)
- `test/orkestra/projector/gen_server_test.exs` — Fixed Sandbox setup_all and setup
- `test/orkestra/projection/storage/postgres_test.exs` — Fixed Sandbox setup_all
- `test/mix/tasks/projection_tasks_test.exs` — Fixed Sandbox setup_all

## Decisions Made

- **Shared sandbox mode over explicit allow:** `Sandbox.mode({:shared, self()})` in per-test `setup` eliminates the race condition where GenServer processes `:load_checkpoint` before `Sandbox.allow` is called. This is safer and cleaner than relying on scheduler timing.
- **unboxed_run + migration_lock: false:** Ecto.Migrator spawns a Task for advisory locking when `migration_lock` is true. That Task can't inherit the sandbox connection. Disabling the lock inside `unboxed_run` avoids both the sandbox restriction and the Task spawning.
- **Application.put_env migration_source patch:** `Orkestra.Projection.Migration` and `Orkestra.Test.ProjectionMigrations` both use version 1. The Ecto.Migrator always reads `migration_source` from `repo.config()` (ignoring opts), so we temporarily patch the Application env to use a separate tracking table (`test_read_model_schema_migrations`).

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 1 - Bug] Fixed Ecto Sandbox setup_all migration failure (pre-existing)**
- **Found during:** Task 1 (attempting to run `mix test --include postgres`)
- **Issue:** All postgres test modules (`gen_server_test`, `postgres_test`, `tasks_test`) called `Ecto.Migrator.run` directly in `setup_all` without a sandbox connection, causing `DBConnection.OwnershipError` before any tests ran
- **Fix:** Replaced bare `Ecto.Migrator.run` calls with `Ecto.Adapters.SQL.Sandbox.unboxed_run` + `migration_lock: false` + Application env patching for the version-1 collision
- **Files modified:** `gen_server_test.exs`, `postgres_test.exs`, `tasks_test.exs`
- **Verification:** `mix test test/orkestra/projector/gen_server_test.exs --include postgres` passes (6 tests)
- **Committed in:** `04723e9` (included in task commit)

**2. [Rule 1 - Bug] Fixed GenServer sandbox ownership race (pre-existing)**
- **Found during:** Task 1 (tests still failing after migration fix)
- **Issue:** GenServer processes `:load_checkpoint` (and DB queries) before `Sandbox.allow` is called by the test process — a genuine race on multi-core schedulers
- **Fix:** Added `Sandbox.mode(ProjectionRepo, {:shared, self()})` in `setup` so all child processes automatically inherit the sandbox connection
- **Files modified:** `telemetry_test.exs`, `gen_server_test.exs`
- **Verification:** 6 telemetry tests + 6 gen_server_test tests pass
- **Committed in:** `04723e9`

---

**Total deviations:** 2 auto-fixed (both Rule 1 - pre-existing bugs in test setup)
**Impact on plan:** The fixes were required to make tests runnable. No scope creep. The telemetry tests themselves are exactly as specified in the plan.

## Known Stubs

None.

## Threat Model Compliance

| Threat ID | Mitigation | Status |
|-----------|------------|--------|
| T-04-04 | Test-only handler captures measurements via send/2; not production surface | Accepted as designed |

## Verification Results

- `mix test test/orkestra/projector/telemetry_test.exs --include postgres`: 6 tests, 0 failures
- `mix test test/orkestra/projector/gen_server_test.exs --include postgres`: 6 tests, 0 failures
- `mix test --include postgres`: 193 tests, 4 failures (only pre-existing TasksTest migration failures remain)
- `mix test` (no postgres): 193 tests, 0 failures, 31 excluded
- `mix compile --warnings-as-errors`: clean

**Remaining postgres failures (pre-existing, out of scope):**
- `TasksTest`: 4 tests fail due to migration_lock Task-connection race in the mix tasks themselves (not fixable without changing the mix task implementation)

## Self-Check: PASSED

- `test/orkestra/projector/telemetry_test.exs` — FOUND (6 tests)
- `test/orkestra/projector/gen_server_test.exs` — FOUND, contains `unboxed_run`, `shared mode`
- Commit `04723e9` — FOUND

---
*Phase: 04-telemetry-observability*
*Completed: 2026-06-24*
