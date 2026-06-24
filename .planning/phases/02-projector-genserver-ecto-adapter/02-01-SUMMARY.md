---
phase: 02-projector-genserver-ecto-adapter
plan: "01"
subsystem: projection-test-harness
status: complete
tags: [postgres, ecto, test-harness, migration, sandbox]
duration_seconds: 239
completed_date: "2026-06-24"

dependency_graph:
  requires: []
  provides:
    - Orkestra.Test.ProjectionRepo — per-projection isolated test Ecto.Repo with Sandbox pool
    - Orkestra.Test.ProjectionReadModel — example read-model schema with changeset
    - Orkestra.Test.ProjectionMigrations — in-code migration creating projection_read_models table
    - elixirc_paths/1 in mix.exs — compiles test/support in :test env
    - test_helper.exs Postgres conditional block — guarded Repo start + Sandbox manual mode
  affects:
    - mix test --exclude postgres (excludes :postgres by default)
    - Plans 02-02 and 02-03 (use this harness for Postgres integration tests)

tech_stack:
  added: []
  patterns:
    - per-projection isolated Ecto.Repo with migration_source (STORE-04, MIG-01)
    - Code.ensure_loaded? guard for conditional Repo start in test_helper
    - Ecto.Migrator tuple list for programmatic in-code migrations

key_files:
  created:
    - test/support/projection_test_repo.ex
    - test/support/projection_read_model.ex
    - test/support/projection_migrations.ex
  modified:
    - mix.exs
    - test/test_helper.exs
    - lib/orkestra/message_bus/rabbit_mq.ex (pre-existing formatter drift, fixed)
    - lib/orkestra/event_handler.ex (pre-existing formatter drift, fixed)
    - lib/orkestra/message_bus/pub_sub.ex (pre-existing formatter drift, fixed)
    - lib/orkestra/event_store/snapshot.ex (pre-existing formatter drift, fixed)
    - test/orkestra/event_test.exs (pre-existing formatter drift, fixed)
    - test/orkestra/command_envelope_test.exs (pre-existing formatter drift, fixed)
    - test/orkestra/message_bus/pub_sub_test.exs (pre-existing formatter drift, fixed)
    - test/orkestra/event_handler_test.exs (pre-existing formatter drift, fixed)
    - test/orkestra/command_test.exs (pre-existing formatter drift, fixed)
    - test/orkestra/command_handler_test.exs (pre-existing formatter drift, fixed)
    - test/orkestra/event_envelope_test.exs (pre-existing formatter drift, fixed)
    - test/orkestra/message_bus_test.exs (pre-existing formatter drift, fixed)

decisions:
  - migration_source set to "orkestra_test_projection_schema_migrations" — gives the test Repo
    a completely isolated migration history table separate from any host app or other Repo
  - In-code migration version constant exposed via version/0 function so Ecto.Migrator tuple
    lists in tests are unambiguous and not magic literals
  - @spec changeset(%__MODULE__{}, map()) instead of t() — Ecto schema t() forward reference
    caused Kernel.TypespecError before module was fully defined; %__MODULE__{} is equivalent
    and avoids the compiler error
  - ExUnit.start(exclude: [:postgres]) as default — CI opts in with --include postgres;
    no Postgres required for the core fast async suite
---

# Phase 2 Plan 01: Postgres Test Harness Summary

**One-liner:** Per-projection isolated Ecto.Repo with SQL.Sandbox manual mode, in-code migration, and conditional test_helper wiring excluding :postgres by default.

## What Was Built

This plan establishes the Postgres test infrastructure for Phase 2. No projector runtime code was written — only the harness that Plans 02-02 and 02-03 build their integration tests on.

### mix.exs — elixirc_paths

Added `elixirc_paths: elixirc_paths(Mix.env())` to `project/0` and a private `elixirc_paths/1` function that returns `["lib", "test/support"]` in `:test` and `["lib"]` otherwise. This is the standard Elixir convention; no such function previously existed.

### test/support/projection_test_repo.ex

Defines `Orkestra.Test.ProjectionRepo` with `use Ecto.Repo, otp_app: :orkestra, adapter: Ecto.Adapters.Postgres`. No `Code.ensure_loaded?` guard — this file is only compiled in the `:test` env via `elixirc_paths`. The Repo's `migration_source`, `pool`, and `url` are supplied at runtime via `Application.put_env` in `test_helper.exs`, keeping the module itself free of hardcoded config.

### test/support/projection_read_model.ex

Defines `Orkestra.Test.ProjectionReadModel` with a `binary_id` primary key, `projector_name :: :string`, `position :: :integer`, `payload :: :map`, and timestamps. Includes `changeset/2` accepting both fields. Used by Plans 02-02 and 02-03 integration tests to write and query read-model rows via Ecto (READ-01 surface).

### test/support/projection_migrations.ex

Defines `Orkestra.Test.ProjectionMigrations` with `use Ecto.Migration` and in-code `up/0`/`down/0`. `up/0` creates `projection_read_models` (binary_id PK, three data columns, timestamps) plus a `unique_index` on `[:projector_name, :position]`. Exposes `version/0 :: pos_integer()` returning `@version 1` for use in `Ecto.Migrator.run(repo, [{version(), Module}], :up, all: true)`. Not a `priv/` file — never auto-discovered by `mix ecto.migrate` (MIG-01).

### test/test_helper.exs

Original MessageBus/PubSub `Application.put_env` calls and `Phoenix.PubSub.Supervisor.start_link` are unchanged. Added a `Code.ensure_loaded?(Ecto.Adapters.SQL.Sandbox)` guard block that:
1. Puts `Application.put_env` for `Orkestra.Test.ProjectionRepo` with `url`, `migration_source: "orkestra_test_projection_schema_migrations"`, `pool: Ecto.Adapters.SQL.Sandbox`, and `pool_size: 5`.
2. Calls `Orkestra.Test.ProjectionRepo.start_link()` inside a `case`: `{:ok, _}` → sets Sandbox to `:manual` mode; `{:error, _}` → prints skip notice and calls `ExUnit.configure(exclude: [:postgres])`.
3. Changed final line to `ExUnit.start(exclude: [:postgres])` — DB-tagged tests skipped by default.

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 1 - Bug] Pre-existing formatter drift across 10 source/test files**

- **Found during:** Task 1 verification (`mix format --check-formatted`)
- **Issue:** 10 files had unformatted code before this plan ran. The verification step mandated by the plan requires `mix format --check-formatted` to pass. These failures were pre-existing (confirmed by stashing this plan's changes and re-running the check).
- **Fix:** Ran `mix format` to normalize all files. Changes included long-line wrapping in `rabbit_mq.ex`, `pub_sub.ex`, `snapshot.ex`, and cond-clause formatting in `event_handler.ex`. Test files had `param`/`field` macro calls formatted from `param :x, :y` to `param(:x, :y)` style.
- **Files modified:** `lib/orkestra/message_bus/rabbit_mq.ex`, `lib/orkestra/event_handler.ex`, `lib/orkestra/message_bus/pub_sub.ex`, `lib/orkestra/event_store/snapshot.ex`, and 6 test files
- **Commit:** c58fbfd

**2. [Rule 1 - Bug] `@spec changeset(t(), map())` caused Kernel.TypespecError**

- **Found during:** Task 3 verification (`mix test --exclude postgres`)
- **Issue:** Using the self-referential `t()` type in `@spec changeset(t(), map())` inside `Orkestra.Test.ProjectionReadModel` triggered `type t/0 undefined` — `Ecto.Schema`'s `t()` type was not yet resolvable at that point in compilation.
- **Fix:** Changed spec to `@spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()`. This is semantically equivalent and avoids the forward reference issue.
- **Files modified:** `test/support/projection_read_model.ex`
- **Commit:** 82dea75

## Known Stubs

None. All modules have concrete, functional implementations. No placeholder data flows to UI or test output.

## Threat Flags

No new network endpoints, auth paths, file access patterns, or schema changes at trust boundaries were introduced by this plan. `T-02-01` (jsonb payload) and `T-02-02` (conditional Repo start) were addressed as designed.

## Self-Check: PASSED

All created files exist. All three task commits exist:
- c58fbfd — Task 1: elixirc_paths + test Repo
- 914c6e7 — Task 2: read-model schema + migration
- 82dea75 — Task 3: test_helper wiring

Verification commands pass:
- `mix compile --warnings-as-errors` — clean
- `mix format --check-formatted` — clean
- `mix test --exclude postgres` — 137 tests, 0 failures
