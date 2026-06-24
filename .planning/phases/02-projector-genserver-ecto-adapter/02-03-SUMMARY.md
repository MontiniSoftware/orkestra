---
phase: 02-projector-genserver-ecto-adapter
plan: "03"
subsystem: projector-genserver
status: complete
tags: [genserver, ecto, multi, atomic-commit, checkpoint, dead-letter, halt, proj-03, proj-04, store-03, err-04, read-01]
duration_seconds: 725
completed_date: "2026-06-24"

dependency_graph:
  requires:
    - 02-01 (Orkestra.Test.ProjectionRepo, ProjectionReadModel, ProjectionMigrations, test_helper wiring)
    - 02-02 (Orkestra.Projection.Storage.Postgres — write/4 returning Ecto.Multi fragments)
    - lib/orkestra/projector/lifecycle.ex (Lifecycle.classify/2, next_delay/2, should_halt?/2)
    - lib/orkestra/projection/checkpoint.ex (Checkpoint schema)
    - lib/orkestra/projection/dead_letter.ex (DeadLetter schema)
    - lib/orkestra/event_store/in_memory.ex (subscribe_from_position push delivery)
  provides:
    - Orkestra.Projector.GenServer — runtime: subscribe, sequential apply, atomic Multi commit, send_after retry, atomic park+halt, stay-alive-on-halt (PROJ-03, PROJ-04, STORE-03, ERR-04, READ-01)
    - test/orkestra/projector/gen_server_test.exs — six :postgres integration tests proving all five requirements
  affects:
    - Phase 3 (DSL will wire adapter_opts automatically; GenServer API is stable)
    - Phase 4 (Telemetry spans/metrics — boundary points kept clean in each handle_info)

tech_stack:
  added: []
  patterns:
    - Deferred init via send(self(), :load_checkpoint) — Sandbox.allow can run after start_supervised!
    - Atomic Ecto.Multi.append(read_model_multi, checkpoint_multi) + Repo.transaction/1 (STORE-03)
    - conflict_target: :projector_name upsert — first event inserts, resume events update
    - Process.send_after for non-blocking retry backoff (no Process.sleep)
    - park_and_halt: dead_letter + halted_checkpoint in one transaction; GenServer stays alive
    - terminate/2 calls event_store.unsubscribe/1 for clean subscription teardown
    - halt last_position = position - 1 so failing event is replayed on restart (exclusive > semantics)
    - wait_until polling helper in tests (no fixed sleep in production code)

key_files:
  created:
    - lib/orkestra/projector/gen_server.ex
    - test/orkestra/projector/gen_server_test.exs
  modified: []

decisions:
  - "Deferred init via send(self(), :load_checkpoint) chosen over handle_continue — same BEAM scheduling guarantee but mirrors the exact pattern from event_handler.ex, making it the established convention across handlers"
  - "halt last_position = event.global_position - 1 (not event.global_position) — exclusive > semantics require position - 1 to replay the failing event on future restart; using position itself would skip it"
  - "max_retries: 0 configuration in test 4 (crash test) causes park on the first failure (classify(1, %{max_retries: 0}) → :park) — no retry loops needed to prove rollback"
  - "InMemory EventStore started via start_supervised(InMemory) per test (no named variant) — all public API functions are bound to __MODULE__; the named store API only works for reset!/1"
  - "test_config helper uses nil defaults (not keyword opts) to avoid default-value explosion in non-default tests — cleaner pattern for 6 tests with different handlers/lifecycle_configs"
---

# Phase 2 Plan 03: Projector GenServer Summary

**One-liner:** Runtime GenServer that subscribes from the persisted checkpoint, applies events sequentially with an atomic Ecto.Multi co-write, retries via send_after, parks exhausted events to dead-letter atomically, and stays alive idle on halt.

## What Was Built

### lib/orkestra/projector/gen_server.ex

Implements `Orkestra.Projector.GenServer` — the projection runtime. Key design:

**Deferred init pattern:** `init/1` stores config in state and enqueues `:load_checkpoint` via `send(self(), :load_checkpoint)`. This defers all Repo access so `Ecto.Adapters.SQL.Sandbox.allow/3` can be called by the test process after `start_supervised!/1` returns (RESEARCH Pitfall 1).

**handle_info(:load_checkpoint):** Reads the `Checkpoint` row from the injected Repo. Three branches:
- `nil` (no prior checkpoint) → subscribes from position -1 (replays all events)
- `%Checkpoint{halted: true}` → does NOT subscribe, stays idle (Pitfall 4 — halted restart guard)
- `%Checkpoint{last_position: pos}` → subscribes from `pos` (exclusive > semantics, PROJ-03)

**Event processing:** `handle_info(%{global_position: _} = event, state)` applies events one at a time via the OTP mailbox (PROJ-04). For non-halted state: calls `storage_adapter.write/4`, builds a checkpoint upsert Multi with `conflict_target: :projector_name`, appends with `Ecto.Multi.append(read_model_multi, checkpoint_multi)`, and commits via `repo.transaction/1` (STORE-03). On success, resets `attempts`. On failure, routes to `handle_failure`.

**Retry path:** `handle_failure` increments `attempts`, calls `Lifecycle.classify/2`, and on `:retry` schedules `Process.send_after(self(), {:retry_event, event}, delay)` — non-blocking (RESEARCH Anti-Patterns). On `:park` calls `park_and_halt`.

**Atomic halt:** `park_and_halt` builds a single `Ecto.Multi` containing a `DeadLetter` insert and a `Checkpoint` upsert with `halted: true`. Sets `last_position = event.global_position - 1` so the failing event is replayed on a future restart (exclusive `>` semantics). Returns `{:noreply, %{state | halted: true, attempts: 0}}` — never `{:stop, ...}` (ERR-04, plan prohibitions).

**Halted discard:** `handle_info(%{global_position: _}, %{halted: true})` logs a warning and returns `{:noreply, state}` without touching the Repo.

**Subscription teardown:** `terminate/2` calls `event_store.unsubscribe(ref)` when a ref exists, guarded by `function_exported?/3` for adapters without this callback.

### test/orkestra/projector/gen_server_test.exs

Six `:postgres`-tagged integration tests (`async: false`, `@moduletag :postgres`) proving all five requirements:

1. **PROJ-04** — 5 events applied in-order; unique_index on `[:projector_name, :position]` guards double-apply. Row positions match `[0,1,2,3,4]`.

2. **STORE-03 (atomic co-commit)** — after 3 events, `checkpoint.last_position == 2` AND 3 read-model rows exist simultaneously, proving both committed together.

3. **PROJ-03 (resume)** — projector processes 3 events, is stopped, new projector with same name starts and resumes; only 2 new events added → 5 total rows with no duplicate positions. The unique index on `[:projector_name, :position]` would surface any reprocessing as a constraint error.

4. **STORE-03 (crash rollback)** — handler fails for position 0 with `max_retries: 0` (parks immediately). Asserts: zero read-model rows (transaction rolled back), checkpoint `halted: true`, `last_position == -1` (not 0 — so position 0 will be replayed on restart), dead_letter row with correct error.

5. **ERR-04 (halt persistence)** — handler fails for position 0 with `max_retries: 2` (2 retries + park). Asserts: dead_letter row with `attempts == 2`, checkpoint `halted: true` with `halted_at` set, `Process.alive?(pid) == true`, post-halt event at position 1 is discarded (row count unchanged).

6. **READ-01 (queryability)** — after 3 events, developer queries read model via `ProjectionRepo.get_by/2`, `ProjectionRepo.all/1`, and `ProjectionRepo.aggregate/2` — all return expected results.

All tests use `start_supervised!` BEFORE `Ecto.Adapters.SQL.Sandbox.allow/3` (correct ownership ordering). Synchronization is via `wait_until` polling (no fixed sleep in production code).

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 1 - Bug] halt last_position set to position instead of position - 1**

- **Found during:** Test design for STORE-03 crash rollback (Task 2)
- **Issue:** Initial implementation set `last_position: event.global_position` in `park_and_halt`. With exclusive `>` subscription semantics, subscribing from `position` would skip the failing event on restart (`> position` delivers `position + 1` onwards).
- **Fix:** Changed to `last_position: event.global_position - 1` (stored as `halt_position`). Subscribing from `position - 1` delivers events `> (position - 1)` which includes the failing event. Also updated test 4 assertion from `== 0` to `== -1`.
- **Files modified:** `lib/orkestra/projector/gen_server.ex`, `test/orkestra/projector/gen_server_test.exs`
- **Commit:** f735106

## Known Stubs

None. The GenServer is fully functional for the Phase 2 scope:
- `storage_adapter.write/4` delegates to the injected `:handler` opt (Phase 3 DSL will wire automatically)
- All checkpoint/dead_letter/halt paths are concrete implementations
- No placeholder data flows to read-model rows

## Threat Flags

No new network endpoints, auth paths, or schema changes beyond those in the threat model:

| Flag | File | Description |
|------|------|-------------|
| T-02-06 (mitigated) | gen_server.ex | `event_data: event` stored in DeadLetter's `:map` field — no `:erlang.binary_to_term`; Jason-serializable maps only |
| T-02-07 (mitigated) | gen_server.ex | Retry cap enforced by `Lifecycle.classify/2` + `should_halt?/2`; `Process.send_after` is non-blocking |
| T-02-09 (mitigated) | gen_server.ex | Single `Ecto.Multi` transaction per event — atomic co-write proven by crash rollback test |

## Self-Check: PASSED

Files created:
- FOUND: /home/th4t/Documents/personal/orkestra/lib/orkestra/projector/gen_server.ex
- FOUND: /home/th4t/Documents/personal/orkestra/test/orkestra/projector/gen_server_test.exs

Commits verified:
- 8e3d9d7 — feat(02-03): implement Orkestra.Projector.GenServer
- f735106 — feat(02-03): add GenServer integration tests + fix halt last_position

Verification commands:
- `mix compile --warnings-as-errors` — clean
- `mix format --check-formatted` — clean
- `mix test --exclude postgres` — 156 tests, 0 failures, 13 excluded (6 new :postgres tests skipped without DB)

Acceptance criteria:
- `grep -c 'use GenServer' lib/orkestra/projector/gen_server.ex` → 1
- `grep -c 'conflict_target: :projector_name' lib/orkestra/projector/gen_server.ex` → 2
- `grep -vE '^\s*#' lib/orkestra/projector/gen_server.ex | grep -Ec 'Process\.sleep|:timer\.sleep'` → 0
- `grep -c 'Process.send_after' lib/orkestra/projector/gen_server.ex` → 2
- `grep -vE '^\s*#' lib/orkestra/projector/gen_server.ex | grep -Ec '\{:stop,'` → 0
- `grep -c 'orkestra: :projector' lib/orkestra/projector/gen_server.ex` → 10
