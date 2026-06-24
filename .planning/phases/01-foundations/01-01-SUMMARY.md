---
phase: 01-foundations
plan: "01"
subsystem: projector/lifecycle + build-manifest
tags: [elixir, ecto, optional-deps, pure-functions, backoff, tdd]
dependency_graph:
  requires: []
  provides:
    - Orkestra.Projector.Lifecycle (ERR-01 retry/backoff, ERR-03 halt decision)
    - ecto/ecto_sql/postgrex optional deps in mix.exs (unblocks Plan 03 Ecto schemas)
  affects:
    - mix.exs (optional deps added)
    - mix.lock (ecto 3.13.6, ecto_sql 3.13.5, postgrex 0.22.2 fetched)
tech_stack:
  added:
    - ecto ~> 3.12 (optional: true) — Ecto.Schema, Ecto.Multi
    - ecto_sql ~> 3.12 (optional: true) — Ecto.Migration
    - postgrex ~> 0.18 (optional: true) — PostgreSQL driver
  patterns:
    - TDD RED/GREEN cycle for pure function module
    - Bitwise.bsl(1, attempt) integer backoff (not :math.pow float)
    - import Bitwise inside function body (not module level) per RESEARCH.md Pattern 5
key_files:
  created:
    - lib/orkestra/projector/lifecycle.ex
    - test/orkestra/projector/lifecycle_test.exs
  modified:
    - mix.exs
    - mix.lock
decisions:
  - "D-04 implemented: uniform exponential backoff, base*2^attempt capped at backoff_cap_ms; no transient/permanent classification in v1"
  - "D-05 honored: Lifecycle is pure (no I/O, no use/behaviour, no process); unit-testable with async: true"
  - "Overflow guard: shift clamped at 62 (RESEARCH.md Pitfall 5); BEAM big integers make this defensive rather than necessary for max_retries=5"
  - "application/0 untouched: optional deps not added to extra_applications (Elixir 1.8+ idiom)"
metrics:
  duration_minutes: 12
  completed_date: "2026-06-24"
  tasks_completed: 2
  tasks_total: 2
  tests_added: 16
  files_created: 2
  files_modified: 2
status: complete
---

# Phase 01 Plan 01: Optional Deps + Projector Lifecycle Summary

**One-liner:** Exponential backoff lifecycle module (Bitwise.bsl integer arithmetic, capped) with TDD and ecto/ecto_sql/postgrex optional dep declarations.

## What Was Built

### Task 1: Optional Deps in mix.exs
Added three `optional: true` entries to `mix.exs` deps, matching the existing `:amqp`/`:spear` alphabetical grouping:
- `{:ecto, "~> 3.12", optional: true}` — resolved to 3.13.6
- `{:ecto_sql, "~> 3.12", optional: true}` — resolved to 3.13.5
- `{:postgrex, "~> 0.18", optional: true}` — resolved to 0.22.2

The `application/0` function was not modified; optional deps are not listed in `extra_applications` per the Elixir 1.8+ idiom confirmed in RESEARCH.md.

### Task 2: Orkestra.Projector.Lifecycle (TDD)
Implemented a pure-function module with three public functions:

- **`next_delay/2`** — `base * 2^attempt` using `Bitwise.bsl(1, attempt)`, capped at `backoff_cap_ms`. Shift clamped to 62 as overflow guard.
- **`classify/2`** — returns `:retry` when `attempts < max_retries`, `:park` when exhausted. Strict `<` boundary (so attempt == max_retries parks immediately).
- **`should_halt?/2`** — returns `true` when `attempts >= max_retries`.

All three accept an optional `config` map (`%{max_retries, backoff_base_ms, backoff_cap_ms}`) with `@default_config` as the fallback (max_retries: 5, base: 500ms, cap: 30s).

## TDD Gate Compliance

| Gate | Commit | Status |
|------|--------|--------|
| RED — 16 failing tests | `6bd66b5` | PASS |
| GREEN — all 16 tests pass | `bf26a2e` | PASS |
| REFACTOR | skipped (no structural cleanup needed) | N/A |

## Commits

| Hash | Type | Description |
|------|------|-------------|
| `4717270` | chore(01-01) | add ecto, ecto_sql, postgrex as optional deps |
| `6bd66b5` | test(01-01) | add failing tests for Orkestra.Projector.Lifecycle (RED) |
| `bf26a2e` | feat(01-01) | implement Orkestra.Projector.Lifecycle pure functions (GREEN) |

## Verification Results

| Check | Result |
|-------|--------|
| `mix deps.get` | PASS — ecto 3.13.6, ecto_sql 3.13.5, postgrex 0.22.2 in mix.lock |
| `mix compile --warnings-as-errors` | PASS — only third-party dep warnings (connection, gpb protobufs), zero Orkestra warnings |
| `mix test test/orkestra/projector/lifecycle_test.exs --seed 0` | PASS — 16 tests, 0 failures |
| `mix test` (full suite) | PASS — 101 tests, 0 failures |
| `grep -c '@spec' lifecycle.ex` | 3 (requirement: >= 3) |
| `grep -c '@doc' lifecycle.ex` | 3 (requirement: >= 3) |
| `:math.pow` usage | 0 |
| `mix format --check-formatted` | PASS |

## Deviations from Plan

None — plan executed exactly as written. The only implementation choice was using `min(attempt, 62)` as the shift clamp (from RESEARCH.md Pitfall 5 guidance), which is explicitly called for in the plan's action block.

## Known Stubs

None — all three functions implement the full computation described in the plan.

## Threat Flags

None — this plan introduces no new network endpoints, auth paths, file access patterns, or trust boundaries. The only threat (T-01-01: DoS via unbounded backoff) is mitigated by the `min(cap, base * bsl(1, safe_shift))` formula with the 62-bit clamp.

## Self-Check: PASSED
<!-- verified below -->
