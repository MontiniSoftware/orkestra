---
phase: 04-telemetry-observability
verified: 2026-06-24T20:40:00Z
status: human_needed
score: 4/4 must-haves verified
overrides_applied: 0
human_verification:
  - test: "Run mix test test/orkestra/projector/telemetry_test.exs --include postgres against a live Postgres instance"
    expected: "All 6 tests pass: lag, lag-zero, halted, retry, rebuild_progress, no-rebuild-in-live-mode"
    why_human: "Telemetry acceptance tests require a live Postgres database via Ecto sandbox; they cannot run in the CI non-postgres baseline and were not executed in this verification environment"
---

# Phase 4: Telemetry & Observability Verification Report

**Phase Goal:** Every event processed by a projector emits an OTel span; lag, rebuild progress, errors, and halts are exposed as metrics so operators can alert on and diagnose projection health
**Verified:** 2026-06-24T20:40:00Z
**Status:** human_needed
**Re-verification:** No — initial verification

## Goal Achievement

### Observable Truths

| # | Truth | Status | Evidence |
|---|-------|--------|----------|
| 1 | Each event processed by a projector emits an OpenTelemetry span consistent with existing Orkestra.Telemetry conventions | VERIFIED | `Tracer.with_span "orkestra.projector.apply_event"` at line 230 of gen_server.ex; attributes supplied by `OTel.projector_span_attrs/3` (line 231); follows exact pattern from aggregate/root.ex. Error branches call `Tracer.set_status(:error, inspect(reason))` at lines 295, 310. `Tracer.add_event("projector.halted", ...)` at line 430. |
| 2 | A positional lag metric (head position minus checkpoint position) is emitted per projector; zero when caught up | VERIFIED | `:telemetry.execute([:orkestra, :projector, :lag], %{lag: lag}, %{projector_name: projector_name})` at line 265 of gen_server.ex. Lag formula: `(state.last_seen_position \|\| position) - position`. `last_seen_position` updated in both normal-delivery (line 191) and halted-discard (line 184) handle_info clauses. Two tests verify: lag >= 0 on normal event; lag = 0 when projector processes the only pending event. |
| 3 | A rebuild progress metric is emitted during rebuild reflecting percentage of total events replayed | VERIFIED | `:telemetry.execute([:orkestra, :projector, :rebuild_progress], %{events_replayed: replayed, total_events: state.rebuild_total}, %{projector_name: projector_name, percent: Float.round(...)})` at lines 277-284 of gen_server.ex. Guarded by `if state.rebuild_total && state.rebuild_total > 0`. State fields `rebuild_total` (read from config) and `rebuild_events_replayed` (counter) both present in `@type state` and `init/1`. Test 5 verifies 3 sequential rebuild_progress events with correct events_replayed/total_events; Test 6 verifies no rebuild_progress in live (non-rebuild) mode. |
| 4 | A halted projector emits a telemetry event/counter on halt; halt status is persisted | VERIFIED | `:telemetry.execute([:orkestra, :projector, :halted], %{attempts: attempts}, %{projector_name: projector_name, position: event.global_position, reason: inspect(reason)})` at lines 420-428 of gen_server.ex, emitted after the DB transaction block regardless of DB success/failure. `Checkpoint` with `halted: true` is written to DB in `park_and_halt/4` (lines 376-396). Test 3 asserts both the telemetry event shape and `cp.halted == true` from the DB. |

**Score:** 4/4 truths verified

### Required Artifacts

| Artifact | Expected | Status | Details |
|----------|----------|--------|---------|
| `lib/orkestra/telemetry.ex` | `projector_span_attrs/3` helper | VERIFIED | Function defined at lines 53-62 with `@doc`, `@spec`, and correct attribute keys. Uses `event[:id] \|\| ""` (bracket access for plain map). Follows exact pattern of `command_attrs/1` and `event_attrs/1`. |
| `lib/orkestra/projector/gen_server.ex` | OTel span wrapping + telemetry.execute calls + state extensions | VERIFIED | 349-line file. `Tracer.with_span` at line 230. Four `:telemetry.execute` sites at lines 265, 277, 342, 420. State `@type` and `init/1` extended with `last_seen_position`, `rebuild_total`, `rebuild_events_replayed`. |
| `test/orkestra/projector/telemetry_test.exs` | 6 ExUnit tests for TEL-01 through TEL-04 | VERIFIED | 349 lines (exceeds min_lines: 100). 6 test cases confirmed by `grep -c`. Tests use `:telemetry.attach/4` + `assert_receive`. No OTel span attribute assertions. |

### Key Link Verification

| From | To | Via | Status | Details |
|------|----|-----|--------|---------|
| `lib/orkestra/projector/gen_server.ex` | `lib/orkestra/telemetry.ex` | `OTel.projector_span_attrs/3` called in apply_event span attributes | WIRED | `alias Orkestra.Telemetry, as: OTel` at line 56; `OTel.projector_span_attrs(projector_name, event, position)` at line 231 |
| `lib/orkestra/projector/gen_server.ex` | `:telemetry` | `:telemetry.execute/3` calls for lag, rebuild_progress, halted, retry | WIRED | Four distinct call sites at lines 265, 277, 342, 420, each with correct event name, measurements map, and metadata map |
| `test/orkestra/projector/telemetry_test.exs` | `lib/orkestra/projector/gen_server.ex` | starts ProjectorGenServer, appends events via InMemory, asserts :telemetry events | WIRED | `start_supervised!({ProjectorGenServer, ...})` at lines 192, 213, 238, 292, 316, 339; `:telemetry.attach` in setup block; `assert_receive {:telemetry, tag, ...}` in each test |

### Data-Flow Trace (Level 4)

| Artifact | Data Variable | Source | Produces Real Data | Status |
|----------|---------------|--------|--------------------|--------|
| `gen_server.ex` `apply_event/2` | `lag` measurement | `(state.last_seen_position \|\| position) - position` after `repo.transaction/1` succeeds | Yes — derived from live GenServer state updated on every event delivery | FLOWING |
| `gen_server.ex` `apply_event/2` | `rebuild_events_replayed` counter | Incremented from `state.rebuild_events_replayed` on each successful commit | Yes — counter initialized to 0 in `init/1`, incremented in success branch | FLOWING |
| `gen_server.ex` `handle_failure/3` | `new_attempts` | `state.attempts + 1` | Yes — `attempts` initialized to 0 in `init/1`, incremented on each failure | FLOWING |
| `gen_server.ex` `park_and_halt/4` | halt `attempts` | `new_attempts` passed from `handle_failure/3` | Yes — passed through the call chain from the `state.attempts` counter | FLOWING |

### Behavioral Spot-Checks

| Behavior | Command | Result | Status |
|----------|---------|--------|--------|
| Compile with zero warnings | `mix compile --warnings-as-errors` | "Generated orkestra app" — zero warnings | PASS |
| Non-postgres test suite | `mix test --exclude postgres` | 193 tests, 0 failures, 31 excluded | PASS |
| `projector_span_attrs/3` exported | `grep -n "def projector_span_attrs" lib/orkestra/telemetry.ex` | Line 55 — found | PASS |
| Four `:telemetry.execute` sites | `grep -n ":telemetry.execute" lib/orkestra/projector/gen_server.ex` | Lines 265, 277, 342, 420 — four sites | PASS |
| All three state fields present in init/1 | `grep -n "last_seen_position\|rebuild_total\|rebuild_events_replayed" gen_server.ex` | All three found in `@type state` and `init/1` | PASS |
| Commit hashes from SUMMARY exist | `git show 1929ca5 00f429f 04723e9 --stat` | All three commits found in git history | PASS |
| Postgres telemetry tests | Requires live Postgres — not run | N/A | SKIP (human) |

### Requirements Coverage

| Requirement | Source Plan | Description | Status | Evidence |
|-------------|------------|-------------|--------|----------|
| TEL-01 | 04-01, 04-02 | Each processed event emits an OTel span consistent with Orkestra.Telemetry conventions | SATISFIED | `Tracer.with_span "orkestra.projector.apply_event"` with `OTel.projector_span_attrs/3` attributes; `Tracer.set_status(:error, ...)` on both error paths; `Tracer.add_event("projector.halted", ...)` on halt |
| TEL-02 | 04-01, 04-02 | Projection lag is exposed as a positional metric (head − checkpoint); zero when caught up | SATISFIED | `:telemetry.execute([:orkestra, :projector, :lag], %{lag: lag}, ...)` after every successful commit; lag formula handles nil `last_seen_position`; two tests verify lag >= 0 and lag == 0 when caught up |
| TEL-03 | 04-01, 04-02 | Rebuild progress is a separate metric from live lag | SATISFIED | `:telemetry.execute([:orkestra, :projector, :rebuild_progress], %{events_replayed: ..., total_events: ..., percent: ...}, ...)` guarded by `rebuild_total > 0`; counter incremented per commit during rebuild; test verifies 3 sequential progress events and absence in live mode |
| TEL-04 | 04-01, 04-02 | Projector errors and halts emit telemetry events/counters for alerting | SATISFIED | `:telemetry.execute([:orkestra, :projector, :retry], ...)` in retry branch; `:telemetry.execute([:orkestra, :projector, :halted], ...)` in `park_and_halt/4`; halt status persisted to `projection_checkpoints` with `halted: true` |

### Anti-Patterns Found

| File | Line | Pattern | Severity | Impact |
|------|------|---------|----------|--------|
| None found | — | — | — | — |

Scanned: `lib/orkestra/telemetry.ex`, `lib/orkestra/projector/gen_server.ex`, `test/orkestra/projector/telemetry_test.exs`
No TODO/FIXME/PLACEHOLDER, no empty return stubs, no hardcoded empty data passed to rendering paths, no unconnected state variables.

### Human Verification Required

#### 1. Postgres Telemetry Acceptance Tests

**Test:** Run `mix test test/orkestra/projector/telemetry_test.exs --include postgres` against a Postgres instance configured for the test environment.
**Expected:** 6 tests pass. Specifically:
- Test 1 (TEL-02): `assert_receive {:telemetry, :lag, %{lag: lag}, %{projector_name: ...}}` fires within 3000ms after appending "LagEvent"
- Test 2 (TEL-02): `assert_receive {:telemetry, :lag, %{lag: 0}, ...}` fires when the only pending event is processed
- Test 3 (TEL-04): `assert_receive {:telemetry, :halted, %{attempts: attempts}, meta}` fires after retry exhaustion; `cp.halted == true` is confirmed in DB
- Test 4 (TEL-04): `assert_receive {:telemetry, :retry, %{attempts: 1, delay_ms: delay}, meta}` fires on first failure with max_retries: 2
- Test 5 (TEL-03): Three sequential `{:telemetry, :rebuild, measurements, meta}` messages received with `events_replayed` 1, 2, 3 and `total_events == 3`
- Test 6 (TEL-03): `assert_receive {:telemetry, :lag, _, _}` fires; `refute_receive {:telemetry, :rebuild, _, _}` passes
**Why human:** The telemetry tests require a live Postgres database. The non-postgres baseline (`mix test --exclude postgres`) passes (193 tests, 0 failures), but the 6 telemetry tests in `telemetry_test.exs` are tagged `@moduletag :postgres` and cannot run without a Postgres connection. The SUMMARY reports all 6 pass, but this cannot be confirmed programmatically without Postgres.

### Gaps Summary

No gaps found. All four roadmap Success Criteria are implemented with substantive code, properly wired, and with data flowing through the instrumentation paths. The only outstanding item is running the Postgres-tagged telemetry acceptance tests against a live database instance, which requires human execution.

---

_Verified: 2026-06-24T20:40:00Z_
_Verifier: Claude (gsd-verifier)_
