---
phase: 01-foundations
plan: "03"
subsystem: projection/schemas + migration
tags: [elixir, ecto, optional-deps, ecto-schema, ecto-migration, oban-pattern]
dependency_graph:
  requires:
    - 01-01 (ecto/ecto_sql/postgrex optional deps in mix.exs)
  provides:
    - Orkestra.Projection.Checkpoint (ERR-03 persisted halt status, D-02 integer position)
    - Orkestra.Projection.DeadLetter (ERR-02 parked-event six fields)
    - Orkestra.Projection.Migration (up/0 creates both tables, down/0 drops both)
  affects:
    - lib/orkestra/projection/checkpoint.ex (created)
    - lib/orkestra/projection/dead_letter.ex (created)
    - lib/orkestra/projection/migration.ex (created)
    - test/orkestra/projection/schemas_test.exs (created)
tech_stack:
  added: []
  patterns:
    - Code.ensure_loaded?(Ecto.Schema) full-module wrap (RESEARCH.md Pattern 3 / Pitfall 2)
    - Code.ensure_loaded?(Ecto.Migration) full-module wrap (RESEARCH.md Pattern 4 / Assumption A2)
    - Oban-style library-owned migration — up/0 and down/0 delegated by consumer wrapper migration
    - Ecto schema reflection tests via __schema__/1 (no Repo required)
key_files:
  created:
    - lib/orkestra/projection/checkpoint.ex
    - lib/orkestra/projection/dead_letter.ex
    - lib/orkestra/projection/migration.ex
    - test/orkestra/projection/schemas_test.exs
  modified: []
decisions:
  - "RESEARCH Pitfall 2 honored: entire defmodule wrapped in Code.ensure_loaded? guard (not just use Ecto.Schema)"
  - "RESEARCH Assumption A2 confirmed: Code.ensure_loaded?(Ecto.Migration) full-module wrap works identically for Migration module"
  - "Oban migration pattern: Orkestra.Projection.Migration.up/0 and down/0 delegate DDL; consumer generates thin wrapper migration"
  - "T-01-05 mitigated: event_data uses :map (JSON/jsonb) not :erlang.binary_to_term — no unsafe atom deserialization"
  - "Schema reflection test guard: entire test defmodule wrapped in Code.ensure_loaded?(Ecto.Schema) so test file compiles without ecto"
metrics:
  duration_minutes: 6
  completed_date: "2026-06-24"
  tasks_completed: 2
  tasks_total: 2
  tests_added: 17
  files_created: 4
  files_modified: 0
status: complete
---

# Phase 01 Plan 03: Checkpoint, DeadLetter Schemas, and Migration Summary

**One-liner:** Checkpoint/DeadLetter Ecto schemas (ERR-02/ERR-03 fields) and an Oban-style library-owned Migration module, all behind full-module `Code.ensure_loaded?` guards so the library compiles without ecto.

## What Was Built

### Task 1: Checkpoint and DeadLetter Schemas

Created two Ecto schema modules, each wrapping its entire `defmodule ... end` block inside `if Code.ensure_loaded?(Ecto.Schema) do`.

**`Orkestra.Projection.Checkpoint`** (`lib/orkestra/projection/checkpoint.ex`):
- Table: `projection_checkpoints`
- PK: `:id` as `:binary_id` (autogenerate: true)
- Fields: `projector_name` (string), `last_position` (integer, default: -1), `halted` (boolean, default: false), `halted_at` (utc_datetime_usec), `updated_at` (auto-managed timestamp)
- Satisfies D-02 (single integer position column for lag arithmetic) and ERR-03 (persisted halt status survives process restart)

**`Orkestra.Projection.DeadLetter`** (`lib/orkestra/projection/dead_letter.ex`):
- Table: `projection_dead_letters`
- PK: `:id` as `:binary_id` (autogenerate: true)
- Fields: `projector_name` (string), `position` (integer), `event_data` (:map / jsonb), `error` (string), `attempts` (integer, default: 0), `occurred_at` (utc_datetime_usec)
- No `timestamps` macro — `occurred_at` is set explicitly by the caller
- Satisfies ERR-02 (all six parked-event fields) and T-01-05 (JSON not term deserialization for event_data)

### Task 2: Migration Module and Schema-Fields Test

**`Orkestra.Projection.Migration`** (`lib/orkestra/projection/migration.ex`):
- Wrapped in `if Code.ensure_loaded?(Ecto.Migration) do` (full-module guard confirms Assumption A2)
- `up/0`: creates `projection_checkpoints` with `unique_index([:projector_name])`; creates `projection_dead_letters` with `index([:projector_name])` and `index([:projector_name, :position])`; column types match the schemas exactly (`:bigint` for positions, `:map` for event_data, `:text` for error)
- `down/0`: drops `projection_dead_letters` then `projection_checkpoints` (reverse order for FK safety)
- `@moduledoc` includes a Usage section with the Oban-style consumer wrapper migration example

**`Orkestra.Projection.SchemasTest`** (`test/orkestra/projection/schemas_test.exs`):
- 17 reflection tests using `Ecto.Schema.__schema__/1` — no Repo required
- Confirms Checkpoint has `halted`, `halted_at`, `last_position` (ERR-03) and source `"projection_checkpoints"`
- Confirms DeadLetter has all six ERR-02 fields and source `"projection_dead_letters"`
- Tests field types and PK configuration
- Entire `defmodule` wrapped in `Code.ensure_loaded?(Ecto.Schema)` guard so the test file compiles without ecto

## Verification Results

| Check | Result |
|-------|--------|
| `mix compile --warnings-as-errors` | PASS |
| `mix compile --no-optional-deps --warnings-as-errors` | PASS — guards hold without ecto |
| `mix test test/orkestra/projection/schemas_test.exs --seed 0` | PASS — 17 tests, 0 failures |
| `mix test` (full suite) | PASS — 137 tests, 0 failures |
| `mix format --check-formatted` on all 4 files | PASS |
| Checkpoint guard check | `grep -B1 'defmodule Orkestra.Projection.Checkpoint'` shows `if Code.ensure_loaded?(Ecto.Schema) do` |
| DeadLetter guard check | Same pattern confirmed |
| Migration guard check | `grep -B1 'defmodule Orkestra.Projection.Migration'` shows `if Code.ensure_loaded?(Ecto.Migration) do` |
| ERR-02 six fields in DeadLetter | projector_name, position, event_data, error, attempts, occurred_at — all present |
| ERR-03 halt fields in Checkpoint | halted, halted_at, last_position — all present |
| Usage section in Migration @moduledoc | Present |

## Commits

| Hash | Type | Description |
|------|------|-------------|
| `c7b7daf` | feat(01-03) | Define Checkpoint and DeadLetter Ecto schemas behind optional-dep guards |
| `0f9381c` | feat(01-03) | Implement Migration.up/0 down/0 and schema-fields reflection test |

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 1 - Bug] `Ecto.Schema.__schema__(:primary_key)` API mismatch in test**
- **Found during:** Task 2 — first test run
- **Issue:** Test assumed `Checkpoint.__schema__(:primary_key)` returns a list of `{field, type, opts}` tuples; actual Ecto API returns `[:id]` (a list of field name atoms). The type is queried via `__schema__(:type, :id)` separately.
- **Fix:** Changed primary key tests to `assert :id in pk_fields` and `assert __schema__(:type, :id) == :binary_id`
- **Files modified:** `test/orkestra/projection/schemas_test.exs`
- **Commit:** `0f9381c` (included in same task commit)

## Known Stubs

None — both schemas define complete field sets matching the ERR-02/ERR-03 requirements. The Migration module provides complete DDL for both tables. No placeholder values, no TODOs, no missing data sources.

## Threat Flags

None — this plan introduces no new network endpoints, auth paths, or external input surfaces. The one substantive threat (T-01-05: unsafe deserialization of `event_data`) is mitigated by using `:map` (JSON/jsonb) instead of `:erlang.binary_to_term`.

## Self-Check: PASSED
