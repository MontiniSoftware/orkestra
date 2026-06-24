---
phase: 03-dsl-supervisor-mix-tasks-and-config
verified: 2026-06-24T18:00:00Z
status: human_needed
score: 5/5
overrides_applied: 0
human_verification:
  - test: "Run `mix test test/mix/tasks/projection_tasks_test.exs --include postgres` against a live Postgres database"
    expected: "All 12 integration tests pass — migrate creates read-model table, rollback/drop round-trips clean up the table and checkpoint row, rebuild raises a clear error when supervisor not found"
    why_human: "Tests require a running PostgreSQL instance with the configured credentials; cannot verify programmatically in this environment"
---

# Phase 3: DSL, Supervisor, Mix Tasks, and Config — Verification Report

**Phase Goal:** A developer can define a projector with `use Orkestra.Projector`, start it under the Projection Supervisor, run per-projection migrations independently, and trigger a full rebuild — and the `:orkestra` config key is correct throughout

**Verified:** 2026-06-24T18:00:00Z
**Status:** human_needed
**Re-verification:** No — initial verification

---

## Goal Achievement

### Observable Truths

| # | Truth | Status | Evidence |
|---|-------|--------|----------|
| 1 | A developer defines a projector with `use Orkestra.Projector` and `project EventType, fn event, multi -> ... end`; the projector starts, subscribes, and processes events without additional boilerplate | VERIFIED | `lib/orkestra/projector.ex` implements full DSL: `__using__`, `project/2`, `__before_compile__`. Generated functions `__dispatch__/3`, `__handle__/3`, `__projection_config__/0`, `child_spec/1` are all substantive. 19/19 DSL unit tests pass without DB. |
| 2 | `Orkestra.Projection.Supervisor` starts all configured projectors under a one_for_one strategy; one projector crashing or halting does not affect others | VERIFIED | `lib/orkestra/projection/supervisor.ex` uses `Supervisor.init(children, strategy: :one_for_one)`. Supervisor tests pass: isolation test confirms `FakeProjectorB` stays alive after `FakeProjectorA` is terminated. |
| 3 | `mix orkestra.projection.migrate`, `mix orkestra.projection.rollback`, and `mix orkestra.projection.drop` each operate exclusively on the named projection's isolated migration history and tables, leaving all other projections untouched | VERIFIED (code) / UNCERTAIN (runtime) | All three tasks call `module.__projection_config__()` to get per-projection `migrations_path` and `migration_source`, then pass them to `Ecto.Migrator.run/4`. Isolation is guaranteed by `migration_source` — each projection's migration tracking is in a separate table. Drop task filters checkpoint/dead_letter deletes by `projector_name`. However, full end-to-end runtime verification requires Postgres (see Human Verification). |
| 4 | `mix orkestra.projection.rebuild` resets the read model and checkpoint, replays the full event stream from position zero in a single gap-free catch-up pass, and transitions to live | VERIFIED (code) | Rebuild task implements the 5-step sequence: `Supervisor.terminate_child` → rollback-all migrations → re-migrate → delete checkpoint+dead_letter → `Supervisor.restart_child`. GenServer on restart finds no checkpoint row, calls `subscribe_from_position(:all, -1, self())` which delivers all events from position 0 upward in the same handle_info path used for live events — no special rebuild mode. RBLD-02 gap-free guarantee is structural. |
| 5 | The `:ultimus` config key bug is fixed (→ `:orkestra`); optional Ecto/Postgrex deps are declared following the existing `:amqp`/`:spear` optional-dep pattern; per-projection Repo config is documented | VERIFIED | `grep -r ultimus lib/` returns no matches. `mix.exs` declares `{:ecto, "~> 3.12", optional: true}`, `{:ecto_sql, "~> 3.12", optional: true}`, `{:postgrex, "~> 0.18", optional: true}` alongside `{:amqp, "~> 4.1", optional: true}` and `{:spear, "~> 1.4", optional: true}`. `@moduledoc` in `projector.ex` contains a "Per-Projection Repo Configuration" section with `config.exs` example showing `migration_source` and `priv`. |

**Score:** 5/5 truths verified (1 with pending human confirmation for runtime behavior)

---

### Required Artifacts

| Artifact | Expected | Status | Details |
|----------|----------|--------|---------|
| `lib/orkestra/projector.ex` | DSL macro: `__using__`, `project/2`, `__before_compile__` generating `__dispatch__/3`, `__projection_config__/0`, `child_spec/1` | VERIFIED | File exists, 280 lines, substantive. All four generated functions present. `child_spec/1` wires to `Orkestra.Projector.GenServer.start_link/1`. |
| `lib/orkestra/projection/supervisor.ex` | one_for_one Supervisor wrapping projector modules | VERIFIED | File exists, 62 lines. `strategy: :one_for_one` confirmed. Both bare module and `{module, opts}` tuple forms handled in `init/1`. |
| `lib/mix/tasks/orkestra.projection.migrate.ex` | `Mix.Tasks.Orkestra.Projection.Migrate` with `Ecto.Migrator` | VERIFIED | File exists, 45 lines. Guarded by `Code.ensure_loaded?(Ecto.Migrator)`. Uses `Ecto.Migrator.with_repo/3` + `Ecto.Migrator.run(:up, all: true)`. Has `@shortdoc`. |
| `lib/mix/tasks/orkestra.projection.rollback.ex` | `Mix.Tasks.Orkestra.Projection.Rollback` with `Ecto.Migrator` | VERIFIED | File exists, 62 lines. Accepts `--step N` and `--all` flags. Uses `Ecto.Migrator.run(:down)`. Has `@shortdoc`. |
| `lib/mix/tasks/orkestra.projection.drop.ex` | `Mix.Tasks.Orkestra.Projection.Drop` with `delete_all` | VERIFIED | File exists, 72 lines. Rollback-all + `repo.delete_all` for both Checkpoint and DeadLetter filtered by `projector_name`. Has `@shortdoc`. |
| `lib/mix/tasks/orkestra.projection.rebuild.ex` | `Mix.Tasks.Orkestra.Projection.Rebuild` with `Supervisor.terminate_child` | VERIFIED | File exists, 145 lines. Full 5-step sequence implemented. `Supervisor.terminate_child` and `Supervisor.restart_child` present. Has `@shortdoc`. Includes confirmation prompt with `--yes` skip. |
| `test/orkestra/projector/projector_dsl_test.exs` | Unit tests for DSL macro expansion | VERIFIED | File exists, 197 lines. 19 tests, all pass. Covers `__projection_config__/0`, `__dispatch__/3`, `__handle__/3`, `child_spec/1`. |
| `test/orkestra/projection/supervisor_test.exs` | OTP supervisor isolation tests | VERIFIED | File exists, 100 lines. 4 tests, all pass. Covers startup, one_for_one isolation, tuple override form, missing `:projectors` key error. |
| `test/mix/tasks/projection_tasks_test.exs` | Integration tests for Mix tasks with `@moduletag :postgres` | VERIFIED (structure) | File exists, 180 lines. 12 tests tagged `:postgres`. Tests error paths (all four tasks raise on missing args), migrate/rollback round-trip, drop cleans checkpoint rows, rebuild error when supervisor not found, shortdoc verification. |
| `test/support/task_test_migrations/20260101000000_create_task_test_table.exs` | Real migration file for path-form Ecto.Migrator | VERIFIED | File exists. Standard `use Ecto.Migration` with `up/0` (create table) and `down/0` (drop table). |

---

### Key Link Verification

| From | To | Via | Status | Details |
|------|----|-----|--------|---------|
| `lib/orkestra/projector.ex` | `lib/orkestra/projector/gen_server.ex` | `child_spec/1` references `Orkestra.Projector.GenServer.start_link/1` | WIRED | Line 275: `%{id: __MODULE__, start: {Orkestra.Projector.GenServer, :start_link, [config]}}` |
| `lib/orkestra/projection/supervisor.ex` | `lib/orkestra/projector.ex` | `init/1` calls `module.child_spec/1` on each projector | WIRED | Lines 55-58: pattern match on bare module calls `module.child_spec([])`, tuple form calls `module.child_spec(override_opts)` |
| `lib/mix/tasks/orkestra.projection.migrate.ex` | `lib/orkestra/projector.ex` | `__projection_config__/0` provides repo, migrations_path, migration_source | WIRED | Line 25: `config = module.__projection_config__()`, then `config.repo`, `config.migrations_path`, `config.migration_source` used in Ecto.Migrator call |
| `lib/mix/tasks/orkestra.projection.rebuild.ex` | `lib/orkestra/projection/supervisor.ex` | `Supervisor.terminate_child` and `restart_child` for GenServer lifecycle | WIRED | Lines 75 and 127: `Supervisor.terminate_child(supervisor_name, module)` and `Supervisor.restart_child(supervisor_name, module)` |
| `lib/mix/tasks/orkestra.projection.drop.ex` | `lib/orkestra/projection/checkpoint.ex` | `repo.delete_all` filtering by projector_name | WIRED | Lines 52-59: `repo.delete_all(from(c in Checkpoint, where: c.projector_name == ^config.projector_name))` and same for DeadLetter |

---

### Data-Flow Trace (Level 4)

The phase artifacts are mix tasks and DSL macros, not components that render dynamic data — Level 4 data-flow trace applies only to the `child_spec/1` config map flow to verify it reaches the GenServer.

| Artifact | Data Variable | Source | Produces Real Data | Status |
|----------|---------------|--------|--------------------|--------|
| `projector.ex` `child_spec/1` | `config.adapter_opts[:handler]` | `&__MODULE__.__handle__/3` (compile-time capture) | Yes — function reference to real dispatch logic | FLOWING |
| `projector.ex` `__projection_config__/0` | `repo`, `projector_name`, `migrations_path`, `migration_source` | Module attributes set by `__using__` at compile time | Yes — real atom, derived strings | FLOWING |
| Mix tasks | `config` from `module.__projection_config__()` | Runtime call to DSL-generated function | Yes — real Repo module, real paths | FLOWING |

---

### Behavioral Spot-Checks

| Behavior | Command | Result | Status |
|----------|---------|--------|--------|
| DSL macro generates all required functions | `mix test test/orkestra/projector/projector_dsl_test.exs --exclude postgres` | 19 tests, 0 failures | PASS |
| Supervisor OTP isolation | `mix test test/orkestra/projection/supervisor_test.exs --exclude postgres` | 4 tests, 0 failures (via combined run) | PASS |
| All phase files compile clean | `mix compile --no-deps-check` | Generated orkestra app, no errors | PASS |
| All phase files pass formatter | `mix format --check-formatted lib/orkestra/projector.ex lib/orkestra/projection/supervisor.ex lib/mix/tasks/orkestra.projection.*.ex` | No output (formatted) | PASS |
| No `:ultimus` references in lib/ | `grep -r ultimus lib/` | No matches | PASS |
| Optional Ecto/Postgrex deps follow amqp/spear pattern | Check `mix.exs` deps | `{:ecto, optional: true}`, `{:ecto_sql, optional: true}`, `{:postgrex, optional: true}` all present | PASS |
| Mix task integration tests (Postgres) | `mix test test/mix/tasks/projection_tasks_test.exs --include postgres` | Cannot verify — requires running Postgres | SKIP (human needed) |

---

### Requirements Coverage

| Requirement | Source Plan | Description | Status | Evidence |
|-------------|------------|-------------|--------|----------|
| PROJ-01 | 03-01 | Developer can define projector via `use Orkestra.Projector` DSL | SATISFIED | `lib/orkestra/projector.ex` implements full DSL; 19 tests pass |
| PROJ-05 | 03-01 | Projectors supervised and isolated — one halting/crashing doesn't stop others | SATISFIED | one_for_one strategy in Supervisor; isolation test passes |
| MIG-02 | 03-02 | `mix orkestra.projection.migrate <name>` | SATISFIED (code) | Migrate task uses `Ecto.Migrator.run(:up, all: true)` with per-projection `migration_source`; runtime DB test pending |
| MIG-03 | 03-02 | `mix orkestra.projection.rollback <name>` | SATISFIED (code) | Rollback task uses `Ecto.Migrator.run(:down, step:)` or `all: true`; runtime DB test pending |
| MIG-04 | 03-02 | `mix orkestra.projection.drop <name>` | SATISFIED (code) | Drop task rollback-all + filtered checkpoint/dead_letter deletes; runtime DB test pending |
| RBLD-01 | 03-02 | `mix orkestra.projection.rebuild <name>` | SATISFIED (code) | 5-step rebuild sequence fully implemented; runtime DB test pending |
| RBLD-02 | 03-02 | Rebuild is gap-free, single catch-up path | SATISFIED | GenServer starts from position -1 when no checkpoint exists; same `subscribe_from_position` path used for catch-up and live — no dual-mode code |
| CFG-01 | 03-01/03-02 | `:ultimus` config key bug fixed → `:orkestra` | SATISFIED | Fixed in Phase 1 code review (commit `1de9868`); `grep -r ultimus lib/` returns no matches; `lib/orkestra/event_store.ex` uses `config :orkestra, ...` in moduledoc |
| CFG-02 | 03-01 | Per-projection Repo config has documented config story | SATISFIED | `@moduledoc` in `projector.ex` contains "Per-Projection Repo Configuration" section with `config.exs` example, `migration_source`, `priv` key, and Repo definition pattern |
| CFG-03 | 03-01/03-02 | Optional Ecto/Postgrex deps follow amqp/spear pattern | SATISFIED | `mix.exs` confirms all three as `optional: true` matching amqp/spear pattern |

---

### Anti-Patterns Found

| File | Line | Pattern | Severity | Impact |
|------|------|---------|----------|--------|
| `lib/orkestra/projector.ex` | 87–88 | `@moduledoc` example shows `myapp_order_projector` (underscore between camelCase words) but actual slug derivation at line 193 produces `myapp_orderprojector` (only dots replaced, not word boundaries) | Warning | Documentation misleads developers about the actual path/table name format; functional behavior is self-consistent |

**Note on the slug discrepancy:** The `@moduledoc` example claims `migrations_path: "priv/projections/myapp_order_projector/migrations"` for `"MyApp.OrderProjector"`. The actual implementation at line 192-193 produces `myapp_orderprojector` (no underscore between `myapp` and `orderprojector`). The tests pass because they only assert `String.contains?` for path segments, not the exact slug. This is a documentation inconsistency — not a blocker — but developers who trust the docs will have a different path than what's actually created. Recommend fixing the `@moduledoc` example or the slug derivation logic (adding a camelCase split) in a follow-up.

---

### Human Verification Required

#### 1. Mix Task Integration Tests Against Postgres

**Test:** Run `mix test test/mix/tasks/projection_tasks_test.exs --include postgres` against a running PostgreSQL instance configured with the Orkestra test credentials.

**Expected:**
- All 12 tests pass
- `migrate` test: creates `task_test_read_model` table successfully (INSERT returns `{:ok, _}`)
- `rollback` test: table is gone after rollback (raises `Postgrex.Error` on query)
- `drop` test: checkpoint row is nil after drop
- `rebuild` test: raises `Mix.Error` with message matching `~r/not found under/` when no supervisor running
- All four `@shortdoc` tests pass

**Why human:** Requires a running PostgreSQL instance. The test environment in this session does not have Postgres available with test credentials. The code structure is correct — this is purely an infrastructure availability issue.

---

### Gaps Summary

No code gaps found. The phase goal is fully achieved in the codebase:

1. `use Orkestra.Projector` DSL is implemented and tested (19 passing unit tests without DB).
2. `Orkestra.Projection.Supervisor` is implemented with one_for_one isolation (4 passing tests).
3. All four mix tasks (migrate/rollback/drop/rebuild) are implemented with real `Ecto.Migrator` calls, proper `migration_source` isolation, and correct error handling.
4. The `:ultimus` bug is fixed (done in Phase 1, confirmed no occurrences in lib/).
5. Optional deps pattern is correct in mix.exs.
6. Per-projection Repo config is documented in `@moduledoc`.

The only pending item is runtime confirmation that the mix tasks work correctly against Postgres — the code paths are correct but the integration tests (`@moduletag :postgres`) cannot be executed without a database instance.

**Minor quality note:** The `@moduledoc` example shows an incorrect slug format (`myapp_order_projector` vs actual `myapp_orderprojector`). This is a documentation inconsistency, not a functional gap.

---

_Verified: 2026-06-24T18:00:00Z_
_Verifier: Claude (gsd-verifier)_
