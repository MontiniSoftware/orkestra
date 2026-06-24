# Phase 4: Telemetry & Observability - Pattern Map

**Mapped:** 2026-06-24
**Files analyzed:** 2 (1 modified + 1 modified)
**Analogs found:** 2 / 2

---

## File Classification

| New/Modified File | Role | Data Flow | Closest Analog | Match Quality |
|---|---|---|---|---|
| `lib/orkestra/projector/gen_server.ex` | service (GenServer) | event-driven | `lib/orkestra/aggregate/root.ex` | exact — both are OTP processes that emit OTel spans per operation and `:telemetry` events |
| `lib/orkestra/telemetry.ex` | utility | request-response | `lib/orkestra/telemetry.ex` (self) | self — adding helpers following existing `command_attrs/1` / `event_attrs/1` pattern |
| `test/orkestra/projector/telemetry_test.exs` | test | event-driven | `test/orkestra/projector/gen_server_test.exs` | role-match — same GenServer under test; adds `:telemetry.attach/4` assertions |

---

## Pattern Assignments

### `lib/orkestra/telemetry.ex` (utility, helper extension)

**Analog:** `lib/orkestra/telemetry.ex` lines 33–64 (existing `command_attrs/1` and `event_attrs/1`)

**Imports pattern** (lines 1–11):
```elixir
defmodule Orkestra.Telemetry do
  require OpenTelemetry.Tracer, as: Tracer
  alias Orkestra.{CommandEnvelope, EventEnvelope, Metadata}
```

**Core pattern — existing attribute helpers** (lines 33–64):
```elixir
@doc "Creates span attributes from a command envelope."
def command_attrs(%CommandEnvelope{command: cmd}) do
  base = %{
    "orkestra.command.type" => cmd.type,
    "orkestra.command.id" => cmd.id
  }
  Map.merge(base, metadata_attrs(cmd.metadata))
end

@doc "Creates span attributes from an event envelope."
def event_attrs(%EventEnvelope{event: event}) do
  base = %{
    "orkestra.event.type" => event.type,
    "orkestra.event.id" => event.id
  }
  Map.merge(base, metadata_attrs(event.metadata))
end
```

**New helper to add — copy this shape exactly:**
```elixir
@doc "Creates span attributes for a projector event-processing span."
@spec projector_span_attrs(String.t(), map(), non_neg_integer()) :: map()
def projector_span_attrs(projector_name, event, position) do
  %{
    "orkestra.projector.name"     => projector_name,
    "orkestra.projector.position" => position,
    "orkestra.event.type"         => event.type,
    "orkestra.event.id"           => event[:id] || ""
  }
end
```

**Key constraint:** No new module aliases needed. The helper takes plain values (not structs) because `Projector.GenServer` deals with raw event maps from EventStore, not `EventEnvelope` structs.

---

### `lib/orkestra/projector/gen_server.ex` (service/GenServer, event-driven)

**Analog:** `lib/orkestra/aggregate/root.ex` — same OTel span wrapping pattern, same `:telemetry` dispatch shape.

**Imports to add** (mirror `aggregate/root.ex` lines 27–32):
```elixir
# Already present:
require Logger
# Add these:
require OpenTelemetry.Tracer, as: Tracer
alias Orkestra.Telemetry, as: OTel
```

**TEL-01 — OTel span in `apply_event/2`**

Copy the `Tracer.with_span` wrapping pattern from `lib/orkestra/aggregate/root.ex` lines 55–94. The span wraps the existing `apply_event/2` body entirely. On `{:ok, _changes}` branch the span closes cleanly; on `{:error, ...}` branches call `Tracer.set_status(:error, inspect(reason))` before returning.

Pattern to copy (from `aggregate/root.ex` lines 55–61, 80–83):
```elixir
Tracer.with_span "orkestra.projector.apply_event",
  attributes: OTel.projector_span_attrs(projector_name, event, position) do
  # ... existing apply_event body goes here ...
  # In the {:ok, _changes} branch — emit TEL-02 lag metric
  # In {:error, step, reason, _} branch — Tracer.set_status(:error, inspect(reason))
end
```

Error path inside span (from `aggregate/root.ex` lines 80–88):
```elixir
{:error, step, reason, _changes} ->
  Tracer.set_status(:error, inspect(reason))
  Logger.warning("Projector event commit failed", ...)
  handle_failure(event, {step, reason}, state)
```

**TEL-02 — Lag metric after successful commit**

Emit inside the `{:ok, _changes}` branch of `repo.transaction(combined)`, after the existing `Logger.debug` call. The state must be extended with `last_seen_position` (tracked in the halted-discard `handle_info` clause too):

State extension in `init/1` (add to the `state` map, lines 100–115):
```elixir
state = %{
  # ... existing fields ...
  last_seen_position: nil,    # tracks the highest global_position seen, even if halted
  rebuild_total: Map.get(config, :rebuild_total, nil),    # set by rebuild mix task (Phase 3)
  rebuild_events_replayed: 0  # counter for TEL-03
}
```

Lag emit pattern (copy `:telemetry.execute/3` shape from RESEARCH.md Pattern 2):
```elixir
{:ok, _changes} ->
  Logger.debug("Projector applied event", ...)

  lag = (state.last_seen_position || position) - position
  :telemetry.execute(
    [:orkestra, :projector, :lag],
    %{lag: lag},
    %{projector_name: projector_name}
  )

  {:noreply, %{state | attempts: 0}}
```

`last_seen_position` update — add to the halted discard clause and to normal delivery clause in `handle_info` (lines 169–184):
```elixir
# In halted discard clause — update last_seen_position so lag stays honest
def handle_info(%{global_position: position} = _event, %{halted: true} = state) do
  Logger.warning("Projector is halted — discarding event", ...)
  {:noreply, %{state | last_seen_position: position}}
end

# In normal delivery clause — update before delegating to apply_event
def handle_info(%{global_position: _} = event, state) do
  state = %{state | last_seen_position: event.global_position}
  apply_event(event, state)
end
```

**TEL-03 — Rebuild progress metric**

Emit inside the same `{:ok, _changes}` branch, after lag, guarded by `rebuild_total`:
```elixir
if state.rebuild_total && state.rebuild_total > 0 do
  replayed = state.rebuild_events_replayed + 1
  :telemetry.execute(
    [:orkestra, :projector, :rebuild_progress],
    %{events_replayed: replayed, total_events: state.rebuild_total},
    %{
      projector_name: projector_name,
      percent: Float.round(replayed / state.rebuild_total * 100, 1)
    }
  )
  %{state | attempts: 0, rebuild_events_replayed: replayed}
else
  %{state | attempts: 0}
end
```

**TEL-04 — Halt telemetry in `park_and_halt/4`**

Add `:telemetry.execute` and `Tracer.add_event` calls at the end of `park_and_halt/4` (after the `case repo.transaction(halt_multi)` block, lines 344–367). Both the `{:ok, _}` and `{:error, ...}` branches should emit the event — it fires regardless of DB success/failure because the GenServer is halting either way.

Pattern to add after the `case` block (before the final `{:noreply, ...}`):
```elixir
:telemetry.execute(
  [:orkestra, :projector, :halted],
  %{attempts: attempts},
  %{
    projector_name: projector_name,
    position: event.global_position,
    reason: inspect(reason)
  }
)

Tracer.add_event("projector.halted", %{
  "orkestra.projector.name"     => projector_name,
  "orkestra.projector.position" => event.global_position,
  "error.attempts"              => attempts
})
```

Also emit retry counter in `handle_failure/3` `:retry` branch (after `Process.send_after`, lines 293–294):
```elixir
:telemetry.execute(
  [:orkestra, :projector, :retry],
  %{attempts: new_attempts, delay_ms: delay},
  %{projector_name: state.projector_name, position: event.global_position}
)
```

---

### `test/orkestra/projector/telemetry_test.exs` (test, event-driven)

**Analog:** `test/orkestra/projector/gen_server_test.exs` (full file, 446 lines)

**Test module structure** (copy from `gen_server_test.exs` lines 1–53):
```elixir
if Code.ensure_loaded?(Ecto.Multi) do
  defmodule Orkestra.Projector.TelemetryTest do
    @moduledoc false

    use ExUnit.Case, async: false

    alias Orkestra.EventStore.InMemory
    alias Orkestra.Projector.GenServer, as: ProjectorGenServer
    # ... test support aliases (same as gen_server_test.exs) ...
```

**Test setup — `:telemetry.attach/4` pattern** (from RESEARCH.md Code Examples section):
```elixir
setup do
  :ok = Ecto.Adapters.SQL.Sandbox.checkout(ProjectionRepo)
  {:ok, _} = start_supervised(InMemory)

  test_pid = self()

  :telemetry.attach(
    "test-lag-#{inspect(self())}",
    [:orkestra, :projector, :lag],
    fn _event, measurements, metadata, _config ->
      send(test_pid, {:telemetry_lag, measurements, metadata})
    end,
    nil
  )

  :telemetry.attach(
    "test-halted-#{inspect(self())}",
    [:orkestra, :projector, :halted],
    fn _event, measurements, metadata, _config ->
      send(test_pid, {:telemetry_halted, measurements, metadata})
    end,
    nil
  )

  on_exit(fn ->
    :telemetry.detach("test-lag-#{inspect(self())}")
    :telemetry.detach("test-halted-#{inspect(self())}")
  end)

  :ok
end
```

**Sandbox ownership pattern** (from `gen_server_test.exs` lines 157–158 — critical ordering):
```elixir
pid = start_supervised!({ProjectorGenServer, test_config(projector_name)})
Ecto.Adapters.SQL.Sandbox.allow(ProjectionRepo, self(), pid)
```

**Assertion pattern** (from RESEARCH.md Code Examples, verified against ExUnit conventions):
```elixir
test "TEL-02 — emits lag telemetry after successful commit" do
  # ... append event, start projector ...
  assert_receive {:telemetry_lag, %{lag: lag}, %{projector_name: _}}, 1000
  assert lag >= 0
end

test "TEL-04 — emits halted telemetry after retry exhaustion" do
  # ... start projector with crash handler, append failing event ...
  assert_receive {:telemetry_halted, %{attempts: attempts}, meta}, 5000
  assert attempts > 0
  assert meta.projector_name == projector_name
end
```

**Do NOT assert on OTel span attributes in tests** — the OTel SDK is not loaded in test env; `Tracer.with_span` is a no-op macro that executes its body. Test observable side effects instead (DB state, `:telemetry` events, Logger messages). This matches the existing test suite — zero OTel assertions in `gen_server_test.exs`.

**Helper reuse** — copy `unique_projector_name/0`, `test_config/3`, `append_event/2`, `wait_until/2`, `poll/2`, `get_checkpoint/1` helpers verbatim from `test/orkestra/projector/gen_server_test.exs` lines 60–147. These are standalone private functions with no inter-test state.

---

## Shared Patterns

### OTel Span Wrapping
**Source:** `lib/orkestra/aggregate/root.ex` lines 55–94
**Apply to:** `apply_event/2` in `Projector.GenServer`

The canonical pattern is:
```elixir
Tracer.with_span "orkestra.<subsystem>.<operation>",
  attributes: %{"orkestra.<key>" => value} do
  # ... operation body ...
  case result do
    {:ok, _} -> result
    {:error, reason} ->
      Tracer.set_status(:error, inspect(reason))
      result
  end
end
```

The `Telemetry.with_span/3` wrapper at `lib/orkestra/telemetry.ex` lines 19–31 provides an alternate API that auto-handles `{:error, _}` returns — use this for one-liner wrapping where the body is a function. For more complex branching (like `apply_event/2` with separate storage_adapter and repo.transaction results), use `Tracer.with_span` directly as in `aggregate/root.ex`.

### Logger Metadata Pattern
**Source:** `lib/orkestra/aggregate/root.ex` lines 53–54, 93–94
**Apply to:** Not needed in Projector.GenServer — it is a long-lived process; logger metadata should not be set/cleared per event as that would thrash the process dictionary. Leave Logger metadata management out of the projector event loop.

### Telemetry Execute Shape
**Source:** RESEARCH.md Patterns 2–4 (verified against `beam-telemetry/telemetry` README)
**Apply to:** `apply_event/2` (lag, rebuild_progress) and `park_and_halt/4` (halted), `handle_failure/3` (retry)

Canonical shape:
```elixir
:telemetry.execute(
  [:orkestra, :projector, :<event_name>],   # atom list — event name
  %{<measurement_key>: value},              # measurements map — numeric values
  %{projector_name: name, <meta_key>: val}  # metadata map — context
)
```

### Error Span Status
**Source:** `lib/orkestra/aggregate/root.ex` line 81, `lib/orkestra/command_handler.ex` line 124
**Apply to:** All `{:error, _}` branches inside `Tracer.with_span` blocks

```elixir
{:error, reason} ->
  Tracer.set_status(:error, inspect(reason))
  # optionally also:
  Tracer.add_event("error", %{"error.reason" => inspect(reason)})
```

### Span Event (Tracer.add_event)
**Source:** `lib/orkestra/aggregate/root.ex` lines 119–123
**Apply to:** `park_and_halt/4` to record the halt as a span event

```elixir
Tracer.add_event("concurrency_retry", %{
  "attempt" => attempt + 1,
  "orkestra.aggregate.stream_id" => stream_id
})
```

---

## No Analog Found

All files have close analogs. No entries.

---

## Metadata

**Analog search scope:** `lib/orkestra/`, `test/orkestra/projector/`
**Files read:** 5 (`telemetry.ex`, `projector/gen_server.ex`, `aggregate/root.ex`, `command_handler.ex`, `test/orkestra/projector/gen_server_test.exs`)
**Pattern extraction date:** 2026-06-24
