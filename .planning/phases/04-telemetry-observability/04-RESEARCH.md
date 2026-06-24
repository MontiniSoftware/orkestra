# Phase 4: Telemetry & Observability - Research

**Researched:** 2026-06-24
**Domain:** OpenTelemetry spans + `:telemetry` events for the projection subsystem
**Confidence:** HIGH

---

## Summary

Phase 4 instruments the projection subsystem so that operators can observe projection
health without needing to query the database directly. There are two distinct
observability channels already established in the codebase: OTel spans via
`OpenTelemetry.Tracer` for tracing individual operations, and `:telemetry` (the
`beam-telemetry/telemetry` hex package) for metrics-style counters/gauges. The
projection subsystem currently has neither.

All four requirements (TEL-01 through TEL-04) map directly to existing conventions
already used in `Orkestra.Aggregate.Root` and `Orkestra.CommandHandler`. The span
wrapping pattern is `Tracer.with_span name, %{attributes: attrs} do ... end` with
`"orkestra.projector.*"` naming. Lag and rebuild metrics are emitted via
`:telemetry.execute/3` — the `:telemetry` package is already a transitive dep
(via `:ecto` and `:ecto_sql`) and does not require adding a new dep. Halt events are
also emitted via `:telemetry.execute/3` so operators can attach a handler to alert.

The primary implementation site is `Orkestra.Projector.GenServer`. The `Telemetry`
module gains new projector-specific attribute helpers. Lag is computable from the
GenServer's internal state — the last event's `global_position` minus the
`checkpoint.last_position` — no new EventStore callback is needed.

**Primary recommendation:** Add span instrumentation to `apply_event/2` and
`park_and_halt/4` inside `Projector.GenServer` using the existing `Tracer.with_span`
pattern, and emit `:telemetry.execute/3` events for lag (after each successful
commit), rebuild progress (during replay), and halt (at park_and_halt). Extend
`Orkestra.Telemetry` with `projector_attrs/2` and `projector_span_attrs/3` helpers
following the `command_attrs/1` / `event_attrs/1` pattern.

---

<user_constraints>
## User Constraints (from CONTEXT.md)

### Locked Decisions
None — pure infrastructure phase.

### Claude's Discretion
All implementation choices are at Claude's discretion. Use ROADMAP phase goal, success
criteria, existing `Orkestra.Telemetry` module conventions, and codebase patterns to
guide decisions.

### Deferred Ideas (OUT OF SCOPE)
None — discuss phase was skipped.
</user_constraints>

---

<phase_requirements>
## Phase Requirements

| ID | Description | Research Support |
|----|-------------|------------------|
| TEL-01 | Each processed event emits an OTel span consistent with existing `Orkestra.Telemetry` conventions | Span wrapping pattern from `Aggregate.Root`; span name `"orkestra.projector.apply_event"` |
| TEL-02 | Projection lag exposed as a metric — positional (`head_position - checkpoint_position`) | `:telemetry.execute/3` after each successful commit; lag derivable from GenServer state |
| TEL-03 | Rebuild progress exposed as a separate metric from live lag | `:telemetry.execute/3` during replay; GenServer tracks `rebuild_mode: boolean()` in state |
| TEL-04 | Projector errors and halts emit telemetry events/counters for alerting | `:telemetry.execute/3` at `handle_failure` (retry) and `park_and_halt` (halt) |
</phase_requirements>

---

## Architectural Responsibility Map

| Capability | Primary Tier | Secondary Tier | Rationale |
|------------|-------------|----------------|-----------|
| Per-event OTel span (TEL-01) | Projector GenServer | Orkestra.Telemetry (helpers) | GenServer drives apply_event; span wraps the transaction block |
| Lag metric (TEL-02) | Projector GenServer | — | GenServer holds `last_seen_position` and checkpoint position after each commit |
| Rebuild progress metric (TEL-03) | Projector GenServer | — | GenServer knows replay total and current offset during catch-up |
| Halt counter/event (TEL-04) | Projector GenServer | — | park_and_halt is already isolated in GenServer; emit from there |
| Span attribute helpers | Orkestra.Telemetry | — | Follows `command_attrs/1` pattern; keeps GenServer clean of attribute construction |

---

## Standard Stack

### Core (already in the project — no new deps required)

| Library | Version | Purpose | Why Standard |
|---------|---------|---------|--------------|
| `opentelemetry_api` | 1.5.0 | OTel span API — `Tracer.with_span`, `Tracer.set_attribute`, `Tracer.set_status` | Already the codebase standard; all existing instrumentation uses it [VERIFIED: mix.lock] |
| `:telemetry` | 1.4.2 | Lightweight event dispatch for metrics (lag, progress, halt counters) | Transitive dep via `:ecto` / `:ecto_sql`; already available at runtime [VERIFIED: mix.lock] |

### No new dependencies required

The `:telemetry` hex package is already a runtime-available transitive dep
(`ecto ~> 3.12` and `ecto_sql ~> 3.12` both list `{:telemetry, "~> 0.4 or ~> 1.0"}`
as a required dep). Adding an explicit dep in `mix.exs` is optional but recommended
for clarity; however it can also simply be used without declaration. [VERIFIED: mix.lock]

The OTel experimental metrics API (`opentelemetry_api_experimental`) is **not**
recommended — it is a separate `0.x`-versioned package that requires an experimental
SDK to avoid no-ops and is not part of the stable 1.x OTel API. Using `:telemetry`
for metrics is the correct Elixir ecosystem pattern.
[CITED: https://github.com/open-telemetry/opentelemetry-erlang/blob/main/VERSIONING.md]

---

## Architecture Patterns

### System Architecture Diagram

```
                ┌─────────────────────────────────────────────────┐
                │  Projector.GenServer                             │
                │                                                  │
  EventStore ──▶│  handle_info(event)                             │
  push delivery │      │                                           │
                │      ▼                                           │
                │  apply_event/2                                   │
                │  ┌────────────────────────────────────────────┐ │
                │  │  Tracer.with_span                          │ │
                │  │  "orkestra.projector.apply_event"          │ │
                │  │         │                                  │ │
                │  │   storage_adapter.write + repo.transaction │ │
                │  │         │                                  │ │
                │  │   on success ──▶ :telemetry.execute lag    │ │──▶ operator tooling
                │  │   on error  ──▶ handle_failure             │ │   (Prometheus, LiveDashboard)
                │  └────────────────────────────────────────────┘ │
                │                                                  │
                │  handle_failure/3                                │
                │      ├── :retry  ──▶ :telemetry.execute retry   │
                │      └── :park   ──▶ park_and_halt              │
                │                           │                      │
                │                     :telemetry.execute halt ─────┼──▶ operator alert
                │                     Tracer.set_status(:error)    │
                └─────────────────────────────────────────────────┘

                ┌─────────────────────────────────────────────────┐
                │  Orkestra.Telemetry (extended)                   │
                │  projector_span_attrs/3 ← used by GenServer     │
                └─────────────────────────────────────────────────┘
```

### Recommended Project Structure

No new files except additions to existing modules:

```
lib/orkestra/
├── telemetry.ex              # Add projector_span_attrs/3, projector_attrs/1
├── projector/
│   └── gen_server.ex         # Add span wrapping + :telemetry.execute calls
└── (no new files needed)
```

---

## Pattern 1: OTel Span — apply_event (TEL-01)

**What:** Wrap the `apply_event/2` body in `Tracer.with_span`, setting standard
projector attributes and error status on failure.

**When to use:** Every event processed — successful, retried, and ultimately failed
events all get a span.

**Existing pattern to follow (from `Aggregate.Root`):**

```elixir
# Source: lib/orkestra/aggregate/root.ex
Tracer.with_span "orkestra.aggregate.execute",
  attributes: %{
    "orkestra.aggregate.module" => inspect(aggregate_module),
    "orkestra.aggregate.stream_id" => stream_id,
    "orkestra.command.type" => command.type,
    "orkestra.command.id" => command.id
  } do
  # ...
  {:error, reason} ->
    Tracer.set_status(:error, inspect(reason))
    Tracer.add_event("error", %{"error.reason" => inspect(reason)})
end
```

**Projector equivalent (TEL-01):**

```elixir
# Source: design derived from [VERIFIED: lib/orkestra/aggregate/root.ex]
require OpenTelemetry.Tracer, as: Tracer

defp apply_event(event, state) do
  position = event.global_position

  Tracer.with_span "orkestra.projector.apply_event",
    attributes: %{
      "orkestra.projector.name"     => state.projector_name,
      "orkestra.projector.position" => position,
      "orkestra.event.type"         => event.type,
      "orkestra.event.id"           => event[:id] || ""
    } do
    # ... existing apply_event body ...
    # On {:ok, _} → emit lag telemetry (see Pattern 2)
    # On {:error, ...} → Tracer.set_status(:error, ...)
  end
end
```

### Pattern 2: `:telemetry` Lag Metric (TEL-02)

**What:** After each successful checkpoint commit, emit a `:telemetry` event with
`lag = last_seen_position - checkpoint_last_position`. Since the GenServer commits
the checkpoint in the same transaction as the read model, the lag after a successful
commit is `0` (it caught up to this event). The _actual_ lag observable by an operator
is the difference between the event store's current head (last-seen global position) and
the projector's checkpoint.

**Lag derivation from GenServer state:**

The GenServer receives events in order via `handle_info`. Each event carries
`global_position`. The GenServer must track `last_seen_position` (the `global_position`
of the most recently _received_ event, even if not yet committed) alongside the
already-persisted `checkpoint_position`. After each successful commit:

```
lag = last_seen_position - committed_position
```

When fully caught up, `lag == 0`.

**State extension needed:**

```elixir
# Add to GenServer state:
%{
  # existing fields ...
  last_seen_position: integer() | nil,  # tracks head of what's been delivered
}
```

**Telemetry event name and shape:**

```elixir
# Source: [VERIFIED: beam-telemetry/telemetry README pattern]
:telemetry.execute(
  [:orkestra, :projector, :lag],
  %{lag: lag},
  %{projector_name: state.projector_name}
)
```

### Pattern 3: `:telemetry` Rebuild Progress (TEL-03)

**What:** During a rebuild (replay from position 0), emit progress as a fraction
`{events_replayed, total_events}`. The GenServer must know it is in rebuild mode
versus live processing.

**Rebuild mode tracking:**

Phase 3 introduces the rebuild Mix task (`mix orkestra.projection.rebuild`). The
GenServer needs a way to know it started in rebuild mode so it can emit the separate
progress metric instead of the live lag metric. The simplest approach:

- The supervisor/mix task starts the GenServer with a `rebuild_total: non_neg_integer()`
  key in config; its presence signals rebuild mode.
- GenServer tracks `rebuild_events_replayed` counter, incremented on each successful
  commit during rebuild.
- Once `rebuild_events_replayed >= rebuild_total`, transition to live mode.

**Note on Phase 3 dependency:** If Phase 3 is not complete when Phase 4 runs, this
metric implementation becomes a "stub with correct API" — the GenServer adds the
state fields and emits the telemetry event shape, but the mix task that sets
`rebuild_total` comes in Phase 3. The telemetry event must be defined now for
TEL-03 to be testable independently.

**Telemetry event shape:**

```elixir
# Source: [ASSUMED] — derived from codebase pattern; no prior example to verify
:telemetry.execute(
  [:orkestra, :projector, :rebuild_progress],
  %{events_replayed: replayed, total_events: total},
  %{projector_name: state.projector_name, percent: Float.round(replayed / total * 100, 1)}
)
```

### Pattern 4: `:telemetry` Halt Event (TEL-04)

**What:** When `park_and_halt/4` completes (successfully or not), emit a `:telemetry`
event so operators can wire an alert.

```elixir
# Source: [VERIFIED: beam-telemetry/telemetry README pattern]
:telemetry.execute(
  [:orkestra, :projector, :halted],
  %{attempts: attempts},
  %{
    projector_name: projector_name,
    position: event.global_position,
    reason: inspect(reason)
  }
)
```

This emit happens inside `park_and_halt/4`, after the DB transaction (success or
failure). The `halted: true` row in `projection_checkpoints` is the persistence
mechanism (already implemented); this `:telemetry` event is the in-process
signal for real-time alerting.

Also emit a span event on the OTel side:

```elixir
# Source: [VERIFIED: lib/orkestra/aggregate/root.ex:119 pattern]
Tracer.add_event("projector.halted", %{
  "orkestra.projector.name"     => projector_name,
  "orkestra.projector.position" => event.global_position,
  "error.attempts"              => attempts
})
```

### Anti-Patterns to Avoid

- **Using OTel experimental metrics API for lag/progress:** The `opentelemetry_api_experimental`
  package is `0.x`, requires a separate SDK, and has no-op behavior without it. Use
  `:telemetry.execute/3` instead — it dispatches to attached handlers synchronously
  and is the Elixir ecosystem standard for metrics.
  [CITED: https://github.com/open-telemetry/opentelemetry-erlang/blob/main/VERSIONING.md]

- **Adding a `head_position/0` callback to EventStore behaviour for lag:** Not needed.
  The GenServer tracks `last_seen_position` from incoming event messages. The EventStore
  push-subscription model already delivers every event; the maximum delivered position
  is the head the projector knows about.

- **Wrapping `:load_checkpoint` in a span:** This message is administrative init, not
  event processing. Spanning it would create noise with no value for operators.

- **Emitting lag metric on every incoming `handle_info` (before commit):** Lag should
  reflect committed position, not arrival position. Emit _after_ `repo.transaction`
  succeeds so lag reflects durable state.

---

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| Metric counters/gauges | Custom GenServer accumulator | `:telemetry.execute/3` | `:telemetry` is already available; consumers attach their own handlers; no accumulation needed in library |
| Span lifecycle | Manual start/end/status | `Tracer.with_span` | Handles exception-safe cleanup, status propagation automatically |
| Trace context propagation | Manual span linking | `Tracer.with_span` (nesting) | Spans auto-nest via OTel context stored in process dict |

**Key insight:** `:telemetry` is a _dispatch_ mechanism, not an accumulation one. A
library emits events; the consuming application attaches handlers (e.g., Prometheus
scraper, LiveDashboard). Orkestra should only emit; never accumulate.

---

## Common Pitfalls

### Pitfall 1: OTel span wraps retry loop, not individual attempt
**What goes wrong:** Wrapping `apply_event/2` at the retry-dispatch level (in
`handle_info`) creates a long-running span that encompasses all retries. Operators
see a single span with a long duration rather than per-attempt spans.

**Why it happens:** Trying to minimize span count.

**How to avoid:** Wrap `apply_event/2` itself (the per-attempt function), not the
`handle_info` dispatch. Each retry creates a new span. The retry delay
(`Process.send_after`) happens outside the span.

**Warning signs:** Span durations that include retry backoff sleep time.

### Pitfall 2: Lag metric emitted before DB transaction commits
**What goes wrong:** Emitting the lag metric optimistically (before
`repo.transaction` returns `{:ok, _}`) means lag appears lower than actual in case
of a transaction failure followed by retry.

**Why it happens:** Putting the `:telemetry.execute` call before the `case`.

**How to avoid:** Emit lag only inside the `{:ok, _changes}` branch of
`repo.transaction`.

### Pitfall 3: `:telemetry.execute` inside `Tracer.with_span` vs outside
**What goes wrong:** No actual issue either way; both are synchronous. However, emitting
`:telemetry` inside the OTel span means any slow handler blocks span completion. For
latency-sensitive code, emit after the span closes. For correctness, placement before or
after makes no semantic difference for the metric consumer.

**How to avoid:** Emit `:telemetry` after the `Tracer.with_span` block returns (emit
outside the span) for cleaner separation. This is a style preference, not a correctness
concern.

### Pitfall 4: Testing OTel spans without the SDK
**What goes wrong:** Tests that `assert` on OTel span attributes will fail because the
OTel SDK is not loaded in test env — `Tracer.with_span` is a no-op macro that still
executes the body.

**How to avoid:** Do not test OTel span attributes directly. Test the observable
_side effects_ of the instrumented code (DB state, `:telemetry` events, log messages).
Test `:telemetry` events by attaching a handler in test setup with
`:telemetry.attach/4`. This is the established pattern in the existing test suite
(no OTel assertions anywhere in the test files). [VERIFIED: grep of test/ directory]

### Pitfall 5: TEL-03 rebuild progress without Phase 3 rebuild_total
**What goes wrong:** Dividing `events_replayed / 0` when `rebuild_total` is not set,
or emitting nonsense percentages.

**How to avoid:** Guard with `if state.rebuild_total && state.rebuild_total > 0`.
If not in rebuild mode, do not emit `[:orkestra, :projector, :rebuild_progress]`.

---

## Code Examples

### Attaching a `:telemetry` handler in test (verified pattern)

```elixir
# Source: [CITED: https://github.com/beam-telemetry/telemetry/blob/main/README.md]
# Standard pattern for asserting on :telemetry events in ExUnit

setup do
  test_pid = self()

  :telemetry.attach(
    "test-lag-handler",
    [:orkestra, :projector, :lag],
    fn _event, measurements, metadata, _config ->
      send(test_pid, {:telemetry, measurements, metadata})
    end,
    nil
  )

  on_exit(fn -> :telemetry.detach("test-lag-handler") end)
  :ok
end

test "emits lag telemetry after successful commit" do
  # ... trigger event processing ...
  assert_receive {:telemetry, %{lag: lag}, %{projector_name: _}}, 1000
  assert lag >= 0
end
```

### Span attribute helper addition to Orkestra.Telemetry

```elixir
# Source: [VERIFIED: lib/orkestra/telemetry.ex — command_attrs/1 and event_attrs/1 pattern]
@doc "Creates span attributes for a projector event-processing span."
def projector_span_attrs(projector_name, event, position) do
  %{
    "orkestra.projector.name"     => projector_name,
    "orkestra.projector.position" => position,
    "orkestra.event.type"         => event.type,
    "orkestra.event.id"           => event[:id] || ""
  }
end
```

### Telemetry event name conventions

```elixir
# TEL-02 — lag after successful commit
:telemetry.execute(
  [:orkestra, :projector, :lag],
  %{lag: lag},
  %{projector_name: projector_name}
)

# TEL-03 — rebuild progress during replay
:telemetry.execute(
  [:orkestra, :projector, :rebuild_progress],
  %{events_replayed: replayed, total_events: total},
  %{projector_name: projector_name}
)

# TEL-04 — halt event
:telemetry.execute(
  [:orkestra, :projector, :halted],
  %{attempts: attempts},
  %{projector_name: projector_name, position: position}
)

# TEL-04 — retry event (operator can count retry rate)
:telemetry.execute(
  [:orkestra, :projector, :retry],
  %{attempts: attempts, delay_ms: delay},
  %{projector_name: projector_name, position: position}
)
```

---

## State of the Art

| Old Approach | Current Approach | When Changed | Impact |
|--------------|------------------|--------------|--------|
| OTel experimental metrics API for Elixir | `:telemetry.execute/3` for metrics | OTel erlang was always experimental for metrics; `:telemetry` is the community standard | Use `:telemetry` not OTel metrics |
| Checking for OTel availability at runtime | OTel API is always a no-op without SDK; spans still compile and execute body | Current state | No runtime guard needed; SDK absence is silent |

**Deprecated/outdated:**
- `opentelemetry_api_experimental` for production metrics: still `0.x`, not recommended for stable use in library code.

---

## Assumptions Log

| # | Claim | Section | Risk if Wrong |
|---|-------|---------|---------------|
| A1 | `rebuild_total` is supplied via GenServer config by the Phase 3 rebuild task | Phase Requirements (TEL-03), Pattern 3 | If Phase 3 uses a different mechanism, the GenServer state extension for rebuild_total needs adjustment |
| A2 | `:telemetry` (beam-telemetry) is available at runtime without adding an explicit dep in mix.exs (transitive via ecto) | Standard Stack | If a future ecto version drops :telemetry dep, need explicit dep — low risk given Erlang/Elixir ecosystem dependency on it |
| A3 | The lag metric uses `last_seen_position - checkpoint_last_position` where `last_seen_position` is tracked in GenServer state from incoming event messages | Architecture Patterns (Pattern 2) | If EventStore push delivery gaps (events arrive out of order), last_seen_position might not reflect true head; InMemory is gap-free, EventStoreDB commit_position is monotonic but not gap-free |

**If this table is empty:** N/A — three assumptions documented.

---

## Open Questions

1. **Should TEL-03 rebuild_total be available during Phase 4 or only Phase 3?**
   - What we know: Phase 4 depends on Phase 3 (ROADMAP dependency stated). If Phase 3 is not complete, rebuild mode state tracking can still be wired up — the metric just won't fire until Phase 3's mix task passes the `rebuild_total` config key.
   - What's unclear: Whether Phase 4 should be mergeable before Phase 3 completes or only after.
   - Recommendation: Implement TEL-03 instrumentation in Phase 4 (GenServer state + telemetry execute call). The integration with Phase 3's mix task is deferred but the contract is defined here. Tests can exercise TEL-03 by manually setting `rebuild_total` in the GenServer config.

2. **Where exactly does `last_seen_position` update — on receive or on commit?**
   - What we know: `last_seen_position` tracks the head of events the projector is aware of. Updating on receive (in `handle_info` pattern match) is simpler and gives a tighter lag window.
   - What's unclear: Whether halted projectors should update `last_seen_position` while discarding events (lag would grow visibly).
   - Recommendation: Update `last_seen_position` even in the halted discard path. This makes lag metrics for halted projectors _honest_ — an operator can see the lag is growing even though the projector is stuck.

---

## Environment Availability

No new external dependencies. All required tools are available.

| Dependency | Required By | Available | Version | Fallback |
|------------|------------|-----------|---------|----------|
| `opentelemetry_api` | TEL-01 (OTel spans) | Yes | 1.5.0 | — |
| `:telemetry` | TEL-02, TEL-03, TEL-04 | Yes (transitive) | 1.4.2 | — |
| Elixir/Mix | All | Yes | 1.18.2 / OTP 27 | — |

---

## Validation Architecture

### Test Framework

| Property | Value |
|----------|-------|
| Framework | ExUnit (built-in Elixir) |
| Config file | `test/test_helper.exs` |
| Quick run command | `mix test --exclude postgres` |
| Full suite command | `mix test --include postgres` |

### Phase Requirements → Test Map

| Req ID | Behavior | Test Type | Automated Command | File Exists? |
|--------|----------|-----------|-------------------|-------------|
| TEL-01 | `apply_event/2` wraps processing in OTel span; error sets span status | unit (side-effect via Logger/process result) | `mix test test/orkestra/projector/telemetry_test.exs --exclude postgres` | Wave 0 |
| TEL-02 | Successful commit emits `[:orkestra, :projector, :lag]` telemetry event | unit (`:telemetry.attach` in test) | `mix test test/orkestra/projector/telemetry_test.exs --exclude postgres` | Wave 0 |
| TEL-03 | Rebuild mode emits `[:orkestra, :projector, :rebuild_progress]` telemetry event | unit (`:telemetry.attach` in test, manual `rebuild_total` in config) | `mix test test/orkestra/projector/telemetry_test.exs --exclude postgres` | Wave 0 |
| TEL-04 | park_and_halt emits `[:orkestra, :projector, :halted]` telemetry event; persisted halt survives restart | unit (`:telemetry.attach`) + postgres integration | `mix test test/orkestra/projector/telemetry_test.exs`; `mix test test/orkestra/projector/gen_server_test.exs --include postgres` | Wave 0 (new test file) |

### Sampling Rate

- **Per task commit:** `mix test test/orkestra/projector/telemetry_test.exs --exclude postgres`
- **Per wave merge:** `mix test --exclude postgres`
- **Phase gate:** `mix test --include postgres` (full suite green before `/gsd-verify-work`)

### Wave 0 Gaps

- `test/orkestra/projector/telemetry_test.exs` — new file covering TEL-01 through TEL-04 without Postgres (unit-level `:telemetry.attach` assertions)
- No new fixtures needed — reuse `InMemory` event store; `:telemetry.attach/4` / `:telemetry.detach/1` in setup/on_exit

---

## Security Domain

Security enforcement is enabled at ASVS level 1.

### Applicable ASVS Categories

| ASVS Category | Applies | Standard Control |
|---------------|---------|-----------------|
| V2 Authentication | no | — |
| V3 Session Management | no | — |
| V4 Access Control | no | — |
| V5 Input Validation | yes (low risk) | Telemetry event attributes come from internal GenServer state — no external input; no validation needed beyond existing type specs |
| V6 Cryptography | no | — |

### Known Threat Patterns for this stack

| Pattern | STRIDE | Standard Mitigation |
|---------|--------|---------------------|
| Leaking sensitive event payload data in span attributes | Information Disclosure | Span attributes include only `event.type`, `event.id`, `projector.name`, and `position` — no event payload data (data lives in `event.data` which is not included in spans) |
| Metric injection via projector_name string | Tampering | projector_name is a compile-time constant from `inspect(__MODULE__)` — not user-controlled input |

No security concerns block this phase. Observability data is internal operational
telemetry, not exposed to external callers.

---

## Sources

### Primary (HIGH confidence)

- `lib/orkestra/telemetry.ex` — existing `with_span`, `command_attrs/1`, `event_attrs/1`, `set_logger_metadata/1` patterns [VERIFIED: file read]
- `lib/orkestra/aggregate/root.ex` — `Tracer.with_span`, `Tracer.set_status`, `Tracer.add_event`, `Tracer.set_attribute` usage patterns [VERIFIED: file read]
- `lib/orkestra/command_handler.ex`, `lib/orkestra/event_handler.ex` — span wrapping + `record_exception` pattern [VERIFIED: file read]
- `lib/orkestra/projector/gen_server.ex` — all hook points for instrumentation (apply_event, handle_failure, park_and_halt) [VERIFIED: file read]
- `mix.lock` — `opentelemetry_api 1.5.0`, `:telemetry 1.4.2` versions confirmed [VERIFIED: file read]
- Context7 `/open-telemetry/opentelemetry-erlang` — `Tracer.with_span`, `set_attribute` API; experimental metrics separation [CITED: Context7 docs]
- Context7 `/beam-telemetry/telemetry` — `:telemetry.execute/3`, `:telemetry.attach/4` API and pattern [CITED: Context7 docs]

### Secondary (MEDIUM confidence)

- VERSIONING.md from opentelemetry-erlang: experimental metrics API status [CITED: https://github.com/open-telemetry/opentelemetry-erlang/blob/main/VERSIONING.md]

### Tertiary (LOW confidence)

- None.

---

## Metadata

**Confidence breakdown:**

- Standard stack: HIGH — both deps already locked in mix.lock; no new deps needed
- Architecture: HIGH — implementation sites are clear (apply_event, handle_failure, park_and_halt); patterns directly verified from existing codebase
- Pitfalls: HIGH — derived from verified codebase patterns and OTel no-op behavior
- TEL-03 rebuild integration: MEDIUM — Phase 3 not yet complete; rebuild_total mechanism is [ASSUMED]

**Research date:** 2026-06-24
**Valid until:** 2026-09-24 (stable APIs — 90 days)
