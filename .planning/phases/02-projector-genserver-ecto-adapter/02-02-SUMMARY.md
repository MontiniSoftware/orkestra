---
phase: 02-projector-genserver-ecto-adapter
plan: "02"
subsystem: projection-postgres-adapter
status: complete
tags: [postgres, ecto, storage-adapter, multi, tdd, store-02, store-04, mig-01]
duration_seconds: 382
completed_date: "2026-06-24"

dependency_graph:
  requires:
    - 02-01 (Orkestra.Test.ProjectionRepo, ProjectionReadModel, ProjectionMigrations, test_helper wiring)
    - lib/orkestra/projection/storage.ex (Storage behaviour)
  provides:
    - Orkestra.Projection.Storage.Postgres — PostgreSQL storage adapter returning Ecto.Multi fragments (STORE-02)
    - test/orkestra/projection/storage/postgres_test.exs — behaviour + real-DB integration tests (tagged :postgres)
    - test/orkestra/projection/storage/postgres_adapter_tdd_test.exs — pure-unit TDD tests (no DB required)
  affects:
    - Plan 02-03 (Projector GenServer) — consumes write/4 and appends to checkpoint Multi (STORE-03)

tech_stack:
  added: []
  patterns:
    - Code.ensure_loaded?(Ecto.Multi) guard — adapter compiles without Ecto
    - :read_model_-prefixed Multi step names — prevents Multi.append name clashes with :checkpoint/:halted_checkpoint/:dead_letter
    - Injected :handler opt — 3-arity fn (projector_name, event, position) -> {:ok, Ecto.Multi.t()} | {:error, term()}
    - Injected :repo/:schema opts in reset/2 — no compile-time Repo reference (STORE-03 boundary)
    - setup_all for DDL migration (Ecto.Migrator.run) + per-test SQL.Sandbox checkout for DML isolation

key_files:
  created:
    - lib/orkestra/projection/storage/postgres.ex
    - test/orkestra/projection/storage/postgres_test.exs
    - test/orkestra/projection/storage/postgres_adapter_tdd_test.exs

decisions:
  - "write/4 accepts :handler opt (3-arity fn) instead of building rows itself — the Phase-3 DSL will wire the handler automatically; this is the Phase-2/3 seam documented as a known evolution point"
  - ":read_model_- prefix convention for Multi step names — prevents Multi.append clashes with the GenServer's reserved :checkpoint/:halted_checkpoint/:dead_letter step names (Pitfall 2)"
  - "Repo never referenced at compile time — injected as :repo opt in reset/2; the adapter returns only a Multi fragment from write/4 (STORE-03 boundary enforcement)"
  - "Migration run in setup_all (DDL outside per-test sandbox transaction) — Ecto.Migrator.run creates table once; SQL.Sandbox rolls back DML per test"
  - "TDD RED/GREEN split across two commit phases — failing tests committed first (77c6652), implementation second (3dd6aa8)"
---

# Phase 2 Plan 02: Postgres Storage Adapter Summary

**One-liner:** PostgreSQL/Ecto storage adapter returning composable `Ecto.Multi.t()` fragments with `:read_model_`-prefixed step names, guarded by `Code.ensure_loaded?(Ecto.Multi)`, with real-DB integration tests tagged `:postgres` and skippable without a database.

## What Was Built

### lib/orkestra/projection/storage/postgres.ex

Implements `@behaviour Orkestra.Projection.Storage` with `@impl true` + `@spec` on both callbacks. Wrapped in `if Code.ensure_loaded?(Ecto.Multi) do` so the library compiles without Ecto.

**write/4** — accepts a `:handler` option (3-arity function: `(projector_name, event, position) -> {:ok, Ecto.Multi.t()} | {:error, term()}`). Returns `{:ok, multi}` when the handler returns a valid Multi struct, or `{:error, reason}` when the handler errors. The adapter validates the Multi struct type but does not construct read-model rows itself — that is the handler's responsibility.

**reset/2** — accepts `:repo` and `:schema` opts; calls `repo.delete_all(from s in schema, where: s.projector_name == ^projector_name)` and returns `:ok`. No compile-time Repo module is referenced — the Repo is fully injected at call time.

The module's `@moduledoc` explains:
- The `:read_model_` step-naming convention to prevent `Multi.append` clashes
- The STORE-03 boundary (Repo injected by GenServer, never owned here)
- The Phase-2/3 evolution seam for the `:handler` opt

### test/orkestra/projection/storage/postgres_test.exs

Seven tests tagged `@moduletag :postgres`, `async: false`:

1. **Behaviour contract** — `Postgres.__info__(:attributes)` confirms `Orkestra.Projection.Storage` in the behaviours list
2. **write/4 returns Multi** — handler returning `{:ok, multi}` causes write/4 to return `{:ok, %Ecto.Multi{}}`
3. **write/4 propagates errors** — handler returning `{:error, reason}` propagates unchanged
4. **Multi.append without clash** — `Ecto.Multi.append(write_multi, checkpoint_multi)` where checkpoint uses `:checkpoint` step name does not raise
5. **Real-DB persistence** (STORE-02) — commits `Multi.append(write_multi, checkpoint_multi)` via `ProjectionRepo.transaction/1` and asserts the row is queryable via `ProjectionRepo.get_by/2`
6. **reset/2 clears rows** (STORE-04) — inserts 3 rows, calls `reset/2`, asserts zero rows remain
7. **reset/2 no-op** — reset on a projector with no rows returns `:ok`

Migration setup uses `setup_all` to run `Ecto.Migrator.run` (DDL outside per-test sandbox) and per-test `SQL.Sandbox.checkout` for DML isolation.

### test/orkestra/projection/storage/postgres_adapter_tdd_test.exs

Six unit tests (no DB required, `async: true`, not tagged `:postgres`):
- Behaviour conformance via `__info__(:attributes)`
- write/4 returns `{:ok, %Ecto.Multi{}}`
- Step names are `:read_model_`-prefixed
- `Multi.append` with `:checkpoint` step does not raise
- `{:error, reason}` propagation
- `reset/2` exported with correct arity

## Deviations from Plan

### Auto-fixed Issues

None. The implementation matched the plan's specification exactly.

**TDD Gate Compliance:** RED gate commit exists (77c6652 — `test(02-02)`), GREEN gate commit exists (3dd6aa8 — `feat(02-02)`), no REFACTOR phase was needed.

## Known Stubs

None. The adapter is fully functional:
- `write/4` delegates to the injected `:handler` (no placeholder logic)
- `reset/2` performs a real delete via the injected Repo
- All tests cover concrete behavior

## Threat Flags

No new network endpoints or auth paths introduced. Threat model items addressed:

- **T-02-03** (Tampering — event_data via Ecto changeset): Write operations go through the injected handler's Ecto changeset/Multi — no raw SQL or `:erlang.binary_to_term`
- **T-02-04** (SQL injection): `reset/2` uses `Ecto.Query` parameterized `where` with pinned `^projector_name` — no string-built SQL
- **T-02-05** (Repudiation — adapter binding Repo): Adapter returns Multi fragment only, never commits; transaction boundary owned by the GenServer (STORE-03) — enforced by design

## Self-Check: PASSED

Files created:
- FOUND: lib/orkestra/projection/storage/postgres.ex
- FOUND: test/orkestra/projection/storage/postgres_test.exs
- FOUND: test/orkestra/projection/storage/postgres_adapter_tdd_test.exs

Commits verified:
- 77c6652 — test(02-02): add failing tests for Postgres storage adapter (TDD RED)
- 3dd6aa8 — feat(02-02): implement Orkestra.Projection.Storage.Postgres adapter (TDD GREEN)
- 74dea07 — feat(02-02): add Postgres adapter integration tests (behaviour + real-DB persistence + reset)

Verification commands:
- `mix compile --warnings-as-errors` — clean
- `mix format --check-formatted` — clean
- `mix test --exclude postgres` — 150 tests, 0 failures, 7 excluded (7 new :postgres tests skipped without DB)
