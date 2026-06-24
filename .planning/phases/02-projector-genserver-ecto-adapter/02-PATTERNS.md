# Phase 2: Projector GenServer + Ecto Adapter - Pattern Map

**Mapped:** 2026-06-24
**Files analyzed:** 6 new/modified files
**Analogs found:** 6 / 6

## File Classification

| New/Modified File | Role | Data Flow | Closest Analog | Match Quality |
|-------------------|------|-----------|----------------|---------------|
| `lib/orkestra/projector/gen_server.ex` | GenServer / service | event-driven (push subscription) | `lib/orkestra/event_handler.ex` + `lib/orkestra/event_store/in_memory.ex` | role-match + data-flow match |
| `lib/orkestra/projection/storage/postgres.ex` | adapter / service | CRUD (Ecto.Multi composition) | `lib/orkestra/projection/storage.ex` (behaviour it implements) | exact (behaviour contract) |
| `test/support/projection_test_repo.ex` | config / test support | n/a | `test/test_helper.exs` (Repo config style) | partial |
| `test/orkestra/projector/gen_server_test.exs` | test | event-driven + DB integration | `test/orkestra/projection/schemas_test.exs` | role-match |
| `test/orkestra/projection/storage/postgres_test.exs` | test | CRUD DB integration | `test/orkestra/projection/storage_test.exs` | role-match |
| `test/test_helper.exs` (modify) | config | n/a | existing `test/test_helper.exs` | exact (modify in place) |

---

## Pattern Assignments

### `lib/orkestra/projector/gen_server.ex` (GenServer, event-driven)

**Analogs:** `lib/orkestra/event_handler.ex` (GenServer/subscribe/handle_info pattern) and `lib/orkestra/event_store/in_memory.ex` (subscribe_from_position delivery model)

**Imports pattern** — copy from `lib/orkestra/event_handler.ex` lines 93–96:
```elixir
use GenServer

require Logger

alias Orkestra.Projector.Lifecycle
alias Orkestra.Projection.{Checkpoint, DeadLetter}
```

**Module guard (no Code.ensure_loaded? needed here)** — the GenServer itself has no Ecto dependency at compile time; the Repo module is injected at runtime via opts. No guard needed on this file.

**init/1 — deferred Repo access pattern** — copy `send(self(), :init)` trick from `lib/orkestra/event_handler.ex` lines 106–108:
```elixir
# event_handler.ex lines 106–108
@impl GenServer
def init(_opts) do
  send(self(), :subscribe)
  {:ok, %{subscribed: false}}
end
```
Apply same pattern for projector: defer all Repo calls (checkpoint load) to a `handle_info(:load_checkpoint, state)` clause so `Sandbox.allow/3` can be called by the test process after `start_supervised!/1` returns. This avoids `DBConnection.OwnershipError` (RESEARCH.md Pitfall 1).

**handle_info subscription trigger** — copy pattern from `lib/orkestra/event_handler.ex` lines 112–135 (subscribe then `Process.send_after` retry on failure):
```elixir
# event_handler.ex lines 112–136 (condensed)
@impl GenServer
def handle_info(:subscribe, state) do
  results = Enum.map(@topics, fn topic ->
    bus.subscribe_event(topic, __MODULE__, max_retries: @handler_max_retries)
  end)

  if Enum.all?(results, &(&1 == :ok)) do
    Logger.info("Event handler #{inspect(__MODULE__)} subscribed",
      handler: inspect(__MODULE__),
      topics: inspect(@topics),
      orkestra: :event_handler
    )
    {:noreply, %{state | subscribed: true}}
  else
    Logger.warning("Event handler #{inspect(__MODULE__)} subscribe failed, retrying",
      handler: inspect(__MODULE__),
      orkestra: :event_handler
    )
    Process.send_after(self(), :subscribe, 5_000)
    {:noreply, state}
  end
end
```
Adapt for projector: replace `subscribe_event` with `event_store.subscribe_from_position(:all, last_position, self())`, use `orkestra: :projector` tag, and store `subscription_ref` in state.

**handle_info for pushed event** — the InMemory adapter pushes `stored_event_with_position()` maps directly to the subscriber pid (see `lib/orkestra/event_store/in_memory.ex` lines 178–180):
```elixir
# in_memory.ex lines 178–180
|> Enum.filter(fn e -> e.global_position > from_position end)
|> Enum.each(fn e -> send(subscriber, e) end)
```
The GenServer receives these as bare map messages in `handle_info/2`. Pattern-match on a map with `global_position` key:
```elixir
@impl GenServer
def handle_info(%{global_position: _} = event, state) do
  # process or discard based on state.halted
end

@impl GenServer
def handle_info({:retry_event, event}, state) do
  # re-attempt the same event
end
```

**Logger metadata tag** — use `orkestra: :projector` (not `:event_handler`). See Logger pattern in `lib/orkestra/event_handler.ex` lines 121–125:
```elixir
Logger.info("Event handler #{inspect(__MODULE__)} subscribed",
  handler: inspect(__MODULE__),
  topics: inspect(@topics),
  orkestra: :event_handler  # ← change to :projector
)
```

**Error return from handle_info** — always `{:noreply, state}`. Never `{:stop, ...}` for halt (RESEARCH.md Anti-Patterns). The GenServer process must stay alive when halted.

**Process.send_after for retry** — copy the exact call site pattern from `lib/orkestra/event_handler.ex` line 134:
```elixir
Process.send_after(self(), :subscribe, 5_000)
# Adapt to:
Process.send_after(self(), {:retry_event, event}, delay)
```

**GenServer state shape** — all fields passed via opts at start, no application config reads:
```elixir
%{
  repo: module(),                       # per-projection Ecto.Repo
  projector_name: String.t(),
  storage_adapter: module(),            # implements Storage behaviour
  event_store: module(),                # implements EventStore behaviour
  lifecycle_config: Lifecycle.config(), # %{max_retries, backoff_base_ms, backoff_cap_ms}
  subscription_ref: reference() | nil,
  attempts: non_neg_integer(),
  halted: boolean()
}
```

---

### `lib/orkestra/projection/storage/postgres.ex` (adapter, CRUD)

**Analog:** `lib/orkestra/projection/checkpoint.ex` and `lib/orkestra/projection/dead_letter.ex` (Code.ensure_loaded? guard pattern) plus `lib/orkestra/projection/storage.ex` (behaviour being implemented)

**Code.ensure_loaded? guard** — copy exactly from `lib/orkestra/projection/checkpoint.ex` lines 1–2:
```elixir
# checkpoint.ex lines 1–2
if Code.ensure_loaded?(Ecto.Schema) do
  defmodule Orkestra.Projection.Checkpoint do
```
For the Postgres adapter, guard on `Ecto.Multi` (the Postgres adapter's direct dependency):
```elixir
if Code.ensure_loaded?(Ecto.Multi) do
  defmodule Orkestra.Projection.Storage.Postgres do
```

**@behaviour + @impl true pattern** — copy from `lib/orkestra/event_store/in_memory.ex` lines 41–42:
```elixir
# in_memory.ex lines 41–42
@behaviour Orkestra.EventStore
```
Apply as:
```elixir
@behaviour Orkestra.Projection.Storage

@impl true
@spec write(Storage.projector_name(), Storage.event(), non_neg_integer(), Storage.opts()) ::
        {:ok, Ecto.Multi.t()} | {:error, term()}
def write(projector_name, event, position, opts) do
  # ...
end

@impl true
@spec reset(Storage.projector_name(), Storage.opts()) :: :ok | {:error, term()}
def reset(projector_name, opts) do
  # ...
end
```

**@spec on all public functions** — copy style from `lib/orkestra/event_store/in_memory.ex` lines 78–82:
```elixir
# in_memory.ex lines 78–82
@impl true
@spec load_events(Orkestra.EventStore.stream_id()) ::
        {:ok, [Orkestra.EventStore.stored_event()], Orkestra.EventStore.revision()}
        | {:error, term()}
def load_events(stream_id) do
```

**write/4 returns Ecto.Multi.t()** — the Storage behaviour declares `ops :: term()` but the Postgres adapter concretely returns `Ecto.Multi.t()`. The GenServer merges this with the checkpoint upsert Multi using `Ecto.Multi.append(read_model_multi, checkpoint_multi)` before calling `repo.transaction/1`. The adapter must NOT call the Repo; it only returns the Multi fragment.

**Step naming convention to prevent Multi.append clash** — prefix all step names in `write/4` with `:read_model_` (e.g., `:read_model_insert`, `:read_model_update`). The GenServer uses `:checkpoint` and `:halted_checkpoint` and `:dead_letter`. Document this in `@doc` to prevent future collisions (RESEARCH.md Pitfall 2).

---

### `test/support/projection_test_repo.ex` (test support, config)

**Analog:** `test/test_helper.exs` for config style; `lib/orkestra/projection/migration.ex` lines 1–5 for the `use Ecto.Repo` pattern from RESEARCH.md code examples.

**Module structure:**
```elixir
defmodule Orkestra.Test.ProjectionRepo do
  @moduledoc false
  use Ecto.Repo,
    otp_app: :orkestra,
    adapter: Ecto.Adapters.Postgres
end
```
Note: no `Code.ensure_loaded?` guard needed here — this file is only compiled in the test environment (in `test/support/`). Add it to `mix.exs` `elixirc_paths` for test env if not already automatic.

---

### `test/orkestra/projector/gen_server_test.exs` (test, event-driven + DB integration)

**Analog:** `test/orkestra/projection/schemas_test.exs` (ExUnit structure) and `test/orkestra/projection/storage_test.exs` (behaviour test pattern)

**Module guard pattern** — copy from `test/orkestra/projection/schemas_test.exs` lines 1–2:
```elixir
# schemas_test.exs lines 1–2
if Code.ensure_loaded?(Ecto.Schema) do
  defmodule Orkestra.Projection.SchemasTest do
```
Apply to gen_server_test:
```elixir
if Code.ensure_loaded?(Ecto.Multi) do
  defmodule Orkestra.Projector.GenServerTest do
```

**@moduletag and async: false** — Postgres tests must be `async: false` (shared sandbox connection / no concurrent DB ownership):
```elixir
use ExUnit.Case, async: false
@moduletag :postgres
```
See `test/orkestra/projection/schemas_test.exs` line 5 for the `async: true` pure pattern; flip to `async: false` for Postgres tests.

**Sandbox setup pattern** (from RESEARCH.md Pattern 5):
```elixir
setup do
  :ok = Ecto.Adapters.SQL.Sandbox.checkout(Orkestra.Test.ProjectionRepo)
  :ok
end

test "..." do
  pid = start_supervised!({Orkestra.Projector.GenServer, test_config()})
  Ecto.Adapters.SQL.Sandbox.allow(Orkestra.Test.ProjectionRepo, self(), pid)
  # Now safe to trigger Repo calls inside the GenServer via send/1
end
```

**alias pattern** — copy from `test/orkestra/projection/schemas_test.exs` lines 7–8:
```elixir
alias Orkestra.Projection.Checkpoint
alias Orkestra.Projection.DeadLetter
```
Add `alias Orkestra.Projector.GenServer, as: ProjectorGenServer` and `alias Orkestra.EventStore.InMemory`.

---

### `test/orkestra/projection/storage/postgres_test.exs` (test, CRUD DB integration)

**Analog:** `test/orkestra/projection/storage_test.exs` (behaviour contract test structure)

**Module guard** — same `if Code.ensure_loaded?(Ecto.Multi) do` pattern.

**Test structure** — copy `describe` / `test` block structure from `test/orkestra/projection/storage_test.exs` lines 24–59:
```elixir
# storage_test.exs lines 24–59
describe "Storage behaviour contract" do
  test "a module implementing write/4 and reset/2 satisfies the behaviour" do
    behaviours = StubAdapter.__info__(:attributes)
      |> Keyword.get_values(:behaviour)
      |> List.flatten()
    assert Storage in behaviours
  end
  ...
end
```
Adapt: use `Orkestra.Projection.Storage.Postgres` as the subject; verify it satisfies `@behaviour Orkestra.Projection.Storage`, that `write/4` returns `{:ok, %Ecto.Multi{}}`, and that `Multi.append` with a checkpoint Multi succeeds without name clash.

**@moduletag :postgres** and `async: false` — same as gen_server_test.

---

### `test/test_helper.exs` (modify — add conditional Repo start + Sandbox.mode)

**Analog:** existing `test/test_helper.exs` lines 1–13

**Current content** (lines 1–13):
```elixir
Application.put_env(:orkestra, Orkestra.MessageBus,
  adapter: Orkestra.MessageBus.PubSub,
  app_prefix: nil
)

Application.put_env(:orkestra, Orkestra.MessageBus.PubSub,
  pubsub: Orkestra.PubSub
)

{:ok, _} = Phoenix.PubSub.Supervisor.start_link(name: Orkestra.PubSub)

ExUnit.start()
```

**Add before `ExUnit.start()`** — conditional Postgres Repo setup and sandbox mode:
```elixir
# Postgres integration tests — only when Ecto.Adapters.SQL.Sandbox is available
# and a DATABASE_URL / POSTGRES config is present. Tagged @tag :postgres.
if Code.ensure_loaded?(Ecto.Adapters.SQL.Sandbox) do
  Application.put_env(:orkestra, Orkestra.Test.ProjectionRepo,
    url: System.get_env("DATABASE_URL", "postgres://postgres:postgres@localhost/orkestra_test"),
    pool: Ecto.Adapters.SQL.Sandbox,
    pool_size: 5
  )

  case Orkestra.Test.ProjectionRepo.start_link() do
    {:ok, _} ->
      Ecto.Adapters.SQL.Sandbox.mode(Orkestra.Test.ProjectionRepo, :manual)

    {:error, reason} ->
      IO.puts("Skipping Postgres tests — Repo start failed: #{inspect(reason)}")
      ExUnit.configure(exclude: [:postgres])
  end
end

ExUnit.start(exclude: [:postgres])  # default exclusion; CI overrides with --include postgres
```

---

## Shared Patterns

### Optional Dependency Guard
**Source:** `lib/orkestra/projection/checkpoint.ex` lines 1–2 and `lib/orkestra/projection/dead_letter.ex` lines 1–2
**Apply to:** `lib/orkestra/projection/storage/postgres.ex`
```elixir
if Code.ensure_loaded?(Ecto.Multi) do
  defmodule Orkestra.Projection.Storage.Postgres do
    # ...
  end
end
```
Do NOT apply to `lib/orkestra/projector/gen_server.ex` — the GenServer has no compile-time Ecto dep (Repo is injected at runtime).

### @behaviour + @impl true
**Source:** `lib/orkestra/event_store/in_memory.ex` lines 41–42, 78–79
**Apply to:** `lib/orkestra/projection/storage/postgres.ex`
```elixir
@behaviour Orkestra.Projection.Storage

@impl true
@spec write(...) :: ...
def write(...) do
```

### Logger structured metadata with orkestra: tag
**Source:** `lib/orkestra/event_handler.ex` lines 121–125, 128–133
**Apply to:** `lib/orkestra/projector/gen_server.ex` — use `orkestra: :projector` for all Logger calls
```elixir
Logger.info("Projector subscribed",
  projector: projector_name,
  last_position: last_position,
  orkestra: :projector
)

Logger.warning("Projector is halted, discarding event",
  projector: projector_name,
  position: event.global_position,
  orkestra: :projector
)

Logger.error("Projector halted after exhausting retries",
  projector: projector_name,
  position: event.global_position,
  attempts: attempts,
  orkestra: :projector
)
```

### Process.send_after for non-blocking retry
**Source:** `lib/orkestra/event_handler.ex` line 134
**Apply to:** `lib/orkestra/projector/gen_server.ex` retry scheduling
```elixir
# event_handler.ex line 134
Process.send_after(self(), :subscribe, 5_000)
# Projector equivalent:
Process.send_after(self(), {:retry_event, event}, delay)
# where delay = Lifecycle.next_delay(attempts, lifecycle_config)
```

### Error tuple return style
**Source:** All existing modules — `{:ok, value}` / `{:error, reason}` consistently
**Apply to:** All new modules. The GenServer's `handle_info` always returns `{:noreply, state}` (never `{:stop, ...}` on halt). The Postgres adapter's `write/4` returns `{:ok, Ecto.Multi.t()} | {:error, term()}`.

### @spec on all public functions
**Source:** `lib/orkestra/event_store/in_memory.ex` lines 47–48, 78–82
**Apply to:** All new public functions in `gen_server.ex` and `storage/postgres.ex`
```elixir
@spec start_link(map()) :: GenServer.on_start()
@spec write(Storage.projector_name(), Storage.event(), non_neg_integer(), Storage.opts()) ::
        {:ok, Ecto.Multi.t()} | {:error, term()}
@spec reset(Storage.projector_name(), Storage.opts()) :: :ok | {:error, term()}
```

### @moduledoc and @doc required
**Source:** Every existing module — `@moduledoc` on the module, `@doc` on each public function
**Apply to:** All new modules. See `lib/orkestra/projector/lifecycle.ex` lines 1–25 for the established `@moduledoc` style with a "## Configuration" section.

---

## Key Integration Points (not analog-based)

These patterns come from the locked decisions in CONTEXT.md and Phase 1 schemas; no direct analog exists yet.

### Ecto.Multi atomic composition (STORE-03)
```elixir
# GenServer assembles and commits; adapter provides read_model_multi fragment
{:ok, read_model_multi} = storage_adapter.write(projector_name, event, position, opts)

checkpoint = %Checkpoint{
  projector_name: projector_name,
  last_position: event.global_position,
  halted: false,
  updated_at: DateTime.utc_now()
}

checkpoint_multi =
  Ecto.Multi.new()
  |> Ecto.Multi.insert(:checkpoint, checkpoint,
    on_conflict: [
      set: [last_position: event.global_position, halted: false, updated_at: DateTime.utc_now()]
    ],
    conflict_target: :projector_name   # atom, NOT a constraint name string
  )

# read_model_multi first, checkpoint second — Multi.append arg order matters
combined = Ecto.Multi.append(read_model_multi, checkpoint_multi)

case repo.transaction(combined) do
  {:ok, _changes} -> {:noreply, %{state | attempts: 0}}
  {:error, step, reason, _changes} -> handle_failure(event, {step, reason}, state)
end
```

### Checkpoint schema field access
**Source:** `lib/orkestra/projection/checkpoint.ex` lines 31–37
```elixir
schema "projection_checkpoints" do
  field(:projector_name, :string)
  field(:last_position, :integer, default: -1)
  field(:halted, :boolean, default: false)
  field(:halted_at, :utc_datetime_usec)
  timestamps(inserted_at: false, updated_at: :updated_at)
end
```
The upsert `conflict_target: :projector_name` matches the `unique_index(:projection_checkpoints, [:projector_name])` from `lib/orkestra/projection/migration.ex` line 57.

### Lifecycle.classify/2 and Lifecycle.next_delay/2 call sites
**Source:** `lib/orkestra/projector/lifecycle.ex` lines 63–72, 90–93
```elixir
# classify/2: :retry when attempts < max_retries, :park when exhausted
case Lifecycle.classify(new_attempts, lifecycle_config) do
  :retry ->
    delay = Lifecycle.next_delay(new_attempts, lifecycle_config)
    Process.send_after(self(), {:retry_event, event}, delay)
    {:noreply, %{state | attempts: new_attempts}}

  :park ->
    park_and_halt(event, reason, new_attempts, state)
end
```

### subscribe_from_position/3 return and push delivery
**Source:** `lib/orkestra/event_store/in_memory.ex` lines 155–189
```elixir
# Returns {:ok, ref}
{:ok, ref} = event_store.subscribe_from_position(:all, last_position, self())
# Pushes stored_event_with_position() maps directly to GenServer pid as messages
# GenServer receives them as: handle_info(%{global_position: _, ...} = event, state)
```

---

## No Analog Found

All new files have analogs within the existing codebase. No files lack a reference pattern.

---

## Metadata

**Analog search scope:** `lib/orkestra/`, `test/orkestra/projection/`, `test/test_helper.exs`
**Files scanned:** 10
**Pattern extraction date:** 2026-06-24
