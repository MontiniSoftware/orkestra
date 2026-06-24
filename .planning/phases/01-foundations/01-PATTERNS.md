# Phase 1: Foundations - Pattern Map

**Mapped:** 2026-06-24
**Files analyzed:** 10 (6 new, 4 modified)
**Analogs found:** 8 / 10 (2 have no codebase analog — see "No Analog Found" section)

---

## File Classification

| New/Modified File | Role | Data Flow | Closest Analog | Match Quality |
|-------------------|------|-----------|----------------|---------------|
| `lib/orkestra/projection/storage.ex` | behaviour | request-response | `lib/orkestra/event_store.ex` | exact |
| `lib/orkestra/projection/checkpoint.ex` | model (Ecto schema) | CRUD | no codebase analog | none — use Pattern 3 from RESEARCH.md |
| `lib/orkestra/projection/dead_letter.ex` | model (Ecto schema) | CRUD | no codebase analog | none — use Pattern 3 from RESEARCH.md |
| `lib/orkestra/projection/migration.ex` | utility (migration helper) | batch | `lib/orkestra/event_store.ex` (structure only) | partial — use Pattern 4 from RESEARCH.md |
| `lib/orkestra/projector/lifecycle.ex` | utility (pure functions) | transform | `lib/orkestra/command_envelope.ex` | role-match |
| `lib/orkestra/event_store.ex` (modify) | behaviour | request-response | self | exact — extend in place |
| `lib/orkestra/event_store/in_memory.ex` (modify) | adapter | event-driven | self | exact — extend in place |
| `lib/orkestra/event_store/event_store_db.ex` (modify) | adapter | event-driven | self | exact — extend in place |
| `mix.exs` (modify) | config | — | self (`amqp`/`spear` entries) | exact |
| `test/orkestra/projection/` + `test/orkestra/projector/` (new) | test | — | `test/orkestra/metadata_test.exs` | role-match |

---

## Pattern Assignments

### `lib/orkestra/projection/storage.ex` (behaviour, request-response)

**Analog:** `lib/orkestra/event_store.ex`

**Imports / module header pattern** (lines 1-14):
```elixir
defmodule Orkestra.EventStore do
  @moduledoc """
  Behaviour for event persistence with optimistic concurrency.
  ...
  """

  @type stream_id :: String.t()
  @type revision :: non_neg_integer() | -1
```

**@callback declaration pattern** (lines 27-41):
```elixir
  @doc "Loads all events from a stream. Returns `{:ok, events, current_revision}` or `{:error, reason}`."
  @callback load_events(stream_id()) ::
              {:ok, [stored_event()], revision()} | {:error, term()}

  @callback append_events(stream_id(), events :: [stored_event()], expected_revision()) ::
              {:ok, revision()} | {:error, :wrong_expected_version} | {:error, term()}
```

**impl/0 helper pattern** (lines 43-47):
```elixir
  @doc "Returns the configured EventStore adapter."
  @spec impl() :: module()
  def impl do
    Application.get_env(:ultimus, __MODULE__, [])
    |> Keyword.get(:adapter, Orkestra.EventStore.InMemory)
  end
```

**What to copy:** The `@type` block, `@doc`+`@callback` pairing, and `impl/0` `Application.get_env` shape. For `storage.ex`, declare `@type projector_name :: String.t()`, `@type ops :: term()`, then `@callback write(projector_name(), event(), non_neg_integer(), opts()) :: {:ok, ops()} | {:error, term()}` and `@callback reset(projector_name(), opts()) :: :ok | {:error, term()}`. Do NOT add an `impl/0` — Storage adapters are passed explicitly by the Phase 2 GenServer, not looked up globally.

---

### `lib/orkestra/projection/checkpoint.ex` (Ecto schema, CRUD)

**No codebase analog.** No Ecto schemas exist in this repository. Follow Pattern 3 from RESEARCH.md verbatim.

**Closest structural analog for module shape:** `lib/orkestra/event_store.ex` (module with `@type` declarations + a single responsibility) and the `@behaviour` + `defstruct` pattern from `lib/orkestra/command_envelope.ex`.

**Key constraint — optional dep guard (RESEARCH.md Pattern 3):**
```elixir
if Code.ensure_loaded?(Ecto.Schema) do
  defmodule Orkestra.Projection.Checkpoint do
    use Ecto.Schema
    import Ecto.Changeset

    @primary_key {:id, :binary_id, autogenerate: true}
    @timestamps_opts [type: :utc_datetime_usec]

    schema "projection_checkpoints" do
      field :projector_name, :string
      field :last_position, :integer, default: -1
      field :halted, :boolean, default: false
      field :halted_at, :utc_datetime_usec
      timestamps(inserted_at: false, updated_at: :updated_at)
    end
  end
end
```

**Guard rule:** The ENTIRE `defmodule ... end` block must be inside the `if Code.ensure_loaded?` — NOT just the `use Ecto.Schema` call. See RESEARCH.md Pitfall 2.

**Docs pattern:** Follow `lib/orkestra/aggregate.ex` lines 1-10 — `@moduledoc` on every module, `@doc` on every public function.

---

### `lib/orkestra/projection/dead_letter.ex` (Ecto schema, CRUD)

**No codebase analog.** Same guard and `use Ecto.Schema` pattern as `checkpoint.ex` above.

**Key constraint — optional dep guard (RESEARCH.md Pattern 3):**
```elixir
if Code.ensure_loaded?(Ecto.Schema) do
  defmodule Orkestra.Projection.DeadLetter do
    use Ecto.Schema

    @primary_key {:id, :binary_id, autogenerate: true}

    schema "projection_dead_letters" do
      field :projector_name, :string
      field :position, :integer
      field :event_data, :map
      field :error, :string
      field :attempts, :integer, default: 0
      field :occurred_at, :utc_datetime_usec
    end
  end
end
```

No `:timestamps` macro — `occurred_at` is set explicitly by the caller. `event_data` uses `:map` (Jason-encodable; stored as jsonb in Postgres).

---

### `lib/orkestra/projection/migration.ex` (migration helper, batch)

**No codebase analog.** No migration files exist in this repository. Follow Pattern 4 from RESEARCH.md (Oban-style library migration).

**Guard pattern — same full-module wrap as schemas:**
```elixir
if Code.ensure_loaded?(Ecto.Migration) do
  defmodule Orkestra.Projection.Migration do
    use Ecto.Migration

    def up do
      create table(:projection_checkpoints, primary_key: false) do
        ...
      end
      create table(:projection_dead_letters, primary_key: false) do
        ...
      end
    end

    def down do
      drop table(:projection_dead_letters)
      drop table(:projection_checkpoints)
    end
  end
end
```

Full `up/0` and `down/0` DDL is in RESEARCH.md Pattern 4. The `@moduledoc` must include the "Usage" section showing the consumer's wrapper migration pattern.

---

### `lib/orkestra/projector/lifecycle.ex` (pure functions, transform)

**Analog:** `lib/orkestra/command_envelope.ex`

**Pure function module pattern** (lines 1-50 of command_envelope.ex):

Module structure — no `use`, no `@behaviour`, just `@moduledoc`, `@type`, `@doc`, `@spec`, `def`:
```elixir
defmodule Orkestra.CommandEnvelope do
  @moduledoc """..."""

  alias Orkestra.Command

  @type status :: :pending | :dispatched | :succeeded | :failed | :rejected

  @type t :: %__MODULE__{
          ...
          attempts: non_neg_integer(),
          max_retries: non_neg_integer(),
          ...
        }
```

**Retry semantics analog** (`command_envelope.ex` lines 91-97):
```elixir
  @doc "Whether the envelope can be retried."
  @spec retryable?(t()) :: boolean()
  def retryable?(%__MODULE__{status: :failed, attempts: attempts, max_retries: max}) do
    attempts <= max
  end

  def retryable?(_), do: false
```

**What to copy for `lifecycle.ex`:** The `@type config :: %{...}` map type, `@spec` on every function, and the `attempts <= max_retries` boundary comparison. Backoff uses `import Bitwise, only: [bsl: 2]` inside the function body (not at module level) to avoid polluting the module namespace — see RESEARCH.md Pattern 5.

**`@spec` format to follow** (`command_envelope.ex` lines 59, 67, 75):
```elixir
  @spec wrap(Command.t(), keyword()) :: t()
  @spec mark_dispatched(t()) :: t()
  @spec mark_succeeded(t(), term()) :: t()
```

---

### `lib/orkestra/event_store.ex` (modify — add `subscribe_from_position/3` callback)

**Analog:** self — extend the existing `@callback` block.

**Existing callback block to insert after** (lines 27-41):
```elixir
  @doc "Loads all events from a stream. Returns `{:ok, events, current_revision}` or `{:error, reason}`."
  @callback load_events(stream_id()) ::
              {:ok, [stored_event()], revision()} | {:error, term()}

  @doc "Loads events from a stream starting after `from_revision`."
  @callback load_events(stream_id(), from_revision :: non_neg_integer()) ::
              {:ok, [stored_event()], revision()} | {:error, term()}
```

**New callback to add** (after the existing callbacks, before `impl/0`):
```elixir
  @doc """
  Asynchronously subscribes `subscriber` to receive events starting after
  `from_position` (exclusive). Use `:all` to subscribe across all streams.

  Pushes messages of the form `stored_event()` extended with
  `:global_position :: non_neg_integer()` to `subscriber`.

  Returns `{:ok, subscription_ref}` on success.
  """
  @callback subscribe_from_position(
              stream_id :: stream_id() | :all,
              from_position :: non_neg_integer(),
              subscriber :: pid()
            ) :: {:ok, reference()} | {:error, term()}
```

Also extend the `@type stored_event` map on lines 19-25 to include `global_position: non_neg_integer()` as an optional key (or document it as adapter-added in the callback `@doc`).

---

### `lib/orkestra/event_store/in_memory.ex` (modify — extend Agent state + add `subscribe_from_position/3`)

**Analog:** self — extend the existing Agent-backed module.

**Current `start_link` pattern to replace** (lines 11-14):
```elixir
  def start_link(opts \\ []) do
    name = opts[:name] || __MODULE__
    Agent.start_link(fn -> %{} end, name: name)
  end
```

**Extended state shape (new start_link):**
```elixir
  def start_link(opts \\ []) do
    name = opts[:name] || __MODULE__
    Agent.start_link(
      fn ->
        %{
          streams: %{},
          global_counter: 0,
          subscribers: [],
          global_events: []
        }
      end,
      name: name
    )
  end
```

**Existing `do_append` private helper pattern** (lines 68-82) — extend to increment `global_counter` and stamp `global_position` on each event, and push to subscribers. The push must happen inside the same `Agent.get_and_update` call (or immediately after with a snapshot of the just-appended events) — see RESEARCH.md Pitfall 3.

**Existing `load_events` filter pattern** (lines 37-39) as the model for history replay filtering:
```elixir
      filtered = Enum.filter(events, fn e -> e.stream_revision > from_revision end)
```

Copy this `> from_revision` (exclusive) semantics for the history replay in `subscribe_from_position/3`:
```elixir
      |> Enum.filter(fn e -> e.global_position > from_position end)
```

**`@impl true` placement** (lines 22, 31, 44) — every behaviour callback starts with `@impl true` on the line immediately before `def`.

---

### `lib/orkestra/event_store/event_store_db.ex` (modify — add `subscribe_from_position/3` via Spear)

**Analog:** self — add an `@impl true` function following the existing pattern.

**Existing Spear call pattern** (lines 64-68) — shows `@connection`, named options, and direct Spear API use:
```elixir
      events =
        Spear.stream!(@connection, stream_id,
          direction: :forwards,
          from: from_revision + 1
        )
```

**Error handling pattern** (lines 75-88) — `rescue` with `Spear.Grpc.Response` match plus catch-all:
```elixir
    rescue
      e in Spear.Grpc.Response ->
        if e.status == :not_found do
          {:ok, [], from_revision}
        else
          {:error, e}
        end

      e ->
        {:error, e}
```

**Logger metadata pattern** (lines 113-118):
```elixir
        Logger.debug("Events appended",
          stream: stream_id,
          count: length(events),
          revision: new_revision,
          orkestra: :event_store
        )
```

Use `orkestra: :event_store` tag for the new `subscribe_from_position/3` log calls.

**New implementation shape to add:**
```elixir
  @impl true
  def subscribe_from_position(stream_id_or_all, from_position, subscriber) do
    Spear.subscribe(@connection, subscriber, stream_id_or_all, from: from_position)
  rescue
    e ->
      Logger.error("EventStoreDB subscribe failed",
        stream: inspect(stream_id_or_all),
        from: from_position,
        error: Exception.message(e),
        orkestra: :event_store
      )

      {:error, e}
  end
```

Note: `Spear.subscribe/4` returns `{:ok, subscription_ref}` directly. The EventStoreDB adapter must also add a private helper that extracts `commit_position` from received `Spear.Event.t()` for use as `global_position` in the forwarded message — see RESEARCH.md Open Question 1.

---

### `mix.exs` (modify — add optional deps)

**Analog:** self — existing `optional: true` entries (lines 31, 34):
```elixir
      {:amqp, "~> 4.1", optional: true},
      {:spear, "~> 1.4", optional: true},
```

**Entries to add** (insert after line 34, maintaining alphabetical order within the optional group):
```elixir
      {:ecto, "~> 3.12", optional: true},
      {:ecto_sql, "~> 3.12", optional: true},
      {:postgrex, "~> 0.18", optional: true},
```

No change to `application/0` — optional deps are NOT added to `extra_applications` (see RESEARCH.md State of the Art, "Deprecated" note).

---

### `test/orkestra/projector/lifecycle_test.exs` (new pure-function test)

**Analog:** `test/orkestra/metadata_test.exs`

**Test module structure** (lines 1-7):
```elixir
defmodule Orkestra.MetadataTest do
  use ExUnit.Case, async: true

  alias Orkestra.Metadata

  describe "new/1" do
    test "generates a correlation_id" do
```

**What to copy:** `use ExUnit.Case, async: true` (pure functions — no shared state, safe for async), `alias` the module under test, one `describe` block per public function, one `test` per boundary condition. No `setup` block needed. See full test example in RESEARCH.md Pattern 5.

---

### `test/orkestra/event_store/in_memory_subscription_test.exs` (new Agent/push test)

**Analog:** `test/orkestra/metadata_test.exs` for structure; `test/test_helper.exs` for adapter setup.

**Test helper pattern** — if the InMemory adapter needs to be started for subscription tests, follow `test/test_helper.exs` lines 1-10:
```elixir
Application.put_env(:orkestra, Orkestra.MessageBus,
  adapter: Orkestra.MessageBus.PubSub,
  app_prefix: nil
)

{:ok, _} = Phoenix.PubSub.Supervisor.start_link(name: Orkestra.PubSub)

ExUnit.start()
```

The InMemory adapter may need `Orkestra.EventStore.InMemory.start_link()` in a `setup` block (or `ExUnit.start_supervised!`), not in `test_helper.exs` — keep adapter lifecycle per-test for isolation.

**`async: false`** for InMemory subscription tests — the InMemory Agent is a named singleton; concurrent tests would share state. `metadata_test.exs` uses `async: true` only because `Metadata` is stateless.

---

### `test/orkestra/projection/storage_test.exs` (new behaviour-contract test)

**Analog:** `test/orkestra/metadata_test.exs` — structure only.

This file tests the `Storage` behaviour contract using a minimal in-process stub adapter. No Ecto or Repo needed. Use `async: true`.

---

## Shared Patterns

### Optional Dependency Guarding
**Source:** `mix.exs` lines 31, 34 (existing `optional: true` pattern); RESEARCH.md Pattern 3 (Ecto schema full-module wrap)
**Apply to:** `checkpoint.ex`, `dead_letter.ex`, `migration.ex`

Rule: The `optional: true` flag in `mix.exs` prevents the dep from being required transitively. The `if Code.ensure_loaded?(Ecto.Schema) do defmodule ... end` guard prevents compile-time errors when the dep is absent. Both are required together.

Validation gate: `mix compile --no-optional-deps --warnings-as-errors` must pass before the phase is complete.

### @impl true on Behaviour Callbacks
**Source:** `lib/orkestra/event_store/in_memory.ex` lines 22, 31, 44; `lib/orkestra/event_store/event_store_db.ex` lines 19, 60, 92
**Apply to:** All new/modified callbacks in `in_memory.ex` and `event_store_db.ex`

Pattern: `@impl true` on the line immediately before every `def` that implements a `@callback`. Never skip it.

### Error Tuple Convention
**Source:** `lib/orkestra/event_store/in_memory.ex` lines 25-28; `lib/orkestra/event_store/event_store_db.ex` lines 122-140
**Apply to:** All public functions in all new modules

```elixir
{:ok, value}          # success with result
:ok                   # success with no result (reset/2)
{:error, :atom_reason}  # structured atom reason preferred over strings
{:error, term()}        # for pass-through adapter errors
```

### Logger Structured Metadata
**Source:** `lib/orkestra/event_store/event_store_db.ex` lines 113-118
**Apply to:** `in_memory.ex` and `event_store_db.ex` new functions

```elixir
Logger.debug("Events appended",
  stream: stream_id,
  count: length(events),
  revision: new_revision,
  orkestra: :event_store      # ← domain tag for filtering
)
```

For new projection modules use `orkestra: :projection` or `orkestra: :projector` as the domain tag.

### @doc + @spec on Every Public Function
**Source:** `lib/orkestra/aggregate.ex` lines 41-68; `lib/orkestra/command_envelope.ex` lines 53-60
**Apply to:** All new modules

```elixir
  @doc "Returns the initial state for a brand-new aggregate."
  @callback init_state() :: state()

  @doc "Whether the envelope can be retried."
  @spec retryable?(t()) :: boolean()
  def retryable?(%__MODULE__{...}) do
```

Every public `def` and every `@callback` must have a `@doc`. Every public `def` must have a `@spec`. No exceptions per CLAUDE.md.

### Module Naming and File Path Convention
**Source:** CLAUDE.md Naming Patterns
- File: `lib/orkestra/projection/storage.ex` → Module: `Orkestra.Projection.Storage`
- File: `lib/orkestra/projector/lifecycle.ex` → Module: `Orkestra.Projector.Lifecycle`
- Test: `test/orkestra/projector/lifecycle_test.exs` → Module: `Orkestra.Projector.LifecycleTest`

---

## No Analog Found

| File | Role | Data Flow | Reason |
|------|------|-----------|--------|
| `lib/orkestra/projection/checkpoint.ex` | model (Ecto schema) | CRUD | No Ecto schemas exist in the codebase; first use of `use Ecto.Schema` |
| `lib/orkestra/projection/dead_letter.ex` | model (Ecto schema) | CRUD | Same — no Ecto schemas in codebase |
| `lib/orkestra/projection/migration.ex` | utility (migration) | batch | No migration files exist; no `priv/` directory; first use of `use Ecto.Migration` |

For these three files: use RESEARCH.md Patterns 3 and 4 as the authoritative implementation reference. The codebase provides the module shape and doc conventions (from `aggregate.ex`, `event_store.ex`) but not the Ecto-specific patterns.

---

## Metadata

**Analog search scope:** `lib/orkestra/`, `test/orkestra/`, `mix.exs`
**Files read:** 9 source files, 2 test files
**Pattern extraction date:** 2026-06-24
