# Phase 1: Foundations - Research

**Researched:** 2026-06-24
**Domain:** Elixir CQRS/ES — EventStore catch-up subscription API, Ecto schema/migration optional dep patterns, Ecto.Multi composability, pure lifecycle retry logic
**Confidence:** MEDIUM (core Elixir/Ecto APIs well-known; Spear :all-stream position type requires assumption; optional-dep compile pattern confirmed via community sources)

---

<user_constraints>
## User Constraints (from CONTEXT.md)

### Locked Decisions

- **D-01:** A projection "position" is a non-negative monotonic integer, adapter-provided. The InMemory adapter generates a gap-free global counter (0, 1, 2, …) across all events; the EventStoreDB adapter maps it to the `$all` stream commit position (monotonic but not gap-free). The contract is "monotonic integer," not "gap-free."
- **D-02:** The checkpoint stores this integer position directly (single comparable column), so positional lag (`head − checkpoint`, TEL-02) is plain integer arithmetic that works identically for both adapters.
- **D-03:** The InMemory adapter delivers events via process messages (push): it tracks subscriber pids, replays history from the requested position on subscribe, then pushes ordered messages to subscribers on each append. This mirrors EventStoreDB's push-subscription model so the Phase 2 Projector GenServer codes against one delivery model. Strict in-order, deterministic delivery in tests is the binding success criterion.
- **D-04:** Uniform retry with exponential backoff. Every error retries up to `max_retries` with exponential backoff (base × 2^attempt, capped), then the event is parked to the dead-letter store and the projector halts. No transient/permanent error classification in v1. Retry count/backoff are configurable per projector.
- **D-05:** `Lifecycle` is pure: it classifies the outcome (retry vs park), computes the next delay, and decides halt — all as return values with no I/O, so it is fully unit-testable.
- **D-06:** `Storage.write/4` returns Ecto.Multi-shaped write operations — a description of the read-model writes that the Postgres adapter composes into a single `Ecto.Multi` together with the checkpoint update (enabling STORE-03's atomic co-write in Phase 2). The "ops" abstraction must stay generic enough that future Mongo/ES adapters (which have no `Ecto.Multi`) can implement `write/4` their own idiomatic way.

### Claude's Discretion

- Exact arity/argument order and naming of `subscribe_from_position/3` (e.g. which args are position / subscriber / opts) — pick the shape that best fits the push model and existing EventStore conventions.
- Exact column set/types of the `Checkpoint` and `DeadLetter` schemas beyond the fields mandated by ERR-02 (projector, position, event, error, attempts, timestamp) and ERR-04 (persisted halted status).
- Concrete representation of the "Multi-shaped ops" returned by `write/4`.
- Backoff base/cap defaults.

### Deferred Ideas (OUT OF SCOPE)

- Transient/permanent error classification — deferred; v1 uses uniform retry + backoff.
- Pluggable backoff strategies (fixed/linear in addition to exponential) — deferred; exponential is the v1 default.
- Dead-letter drain/resume tooling (ERR-05) — Phase 1 only persists parked events + halt status.
</user_constraints>

---

<phase_requirements>
## Phase Requirements

| ID | Description | Research Support |
|----|-------------|------------------|
| STORE-01 | Storage-adapter behaviour defines the contract (write, reset) so backends are pluggable behind a shared lifecycle | D-06 write/4 multi-shaped ops design + behaviour pattern from existing EventStore behaviour |
| ERR-01 | On a projection error, the event is retried with backoff (reusing orkestra's existing retry semantics), configurable per projector | Exponential backoff formula + CommandEnvelope retry field shape + pure Lifecycle design |
| ERR-02 | When retries are exhausted, the failing event is parked to a dead-letter store (projector, position, event, error, attempts, timestamp) | DeadLetter Ecto schema + Orkestra-owned migration pattern |
| ERR-03 | After parking, the projector halts rather than skipping ahead, preserving read-model integrity | Lifecycle pure function halt decision + Checkpoint halted field |
| PROJ-02 | A projector consumes events asynchronously via an EventStore catch-up subscription — replaying from its last checkpoint, then transitioning to live with no gap | subscribe_from_position/3 callback shape + InMemory push delivery design + Spear :all subscribe API |
</phase_requirements>

---

## Summary

Phase 1 lays four orthogonal foundations that all later phases depend on: (1) the `subscribe_from_position/3` callback on the EventStore behaviour with two adapter implementations, (2) the `Checkpoint` and `DeadLetter` Ecto schemas with Orkestra-owned migrations, (3) the `Storage` behaviour with its composable-ops write contract, and (4) the pure `Projector.Lifecycle` module. All four are contracts, not runtime processes — Phase 2 builds the GenServer against them.

The central technical tensions are: the InMemory adapter must gain a global position counter and subscriber tracking while remaining deterministic for tests; the Ecto schema and migration modules must compile when `ecto`/`ecto_sql` are absent (optional deps); and the `Storage.write/4` return type must be composable by the Postgres adapter without coupling the behaviour itself to Ecto.

The Spear `subscribe/4` function (arity 4, not 3) is the EventStoreDB seam: it accepts `stream_name: :all` and `from: integer_position` (exclusive, meaning `from: N` delivers events with position > N), matching the D-01 monotonic integer contract. The InMemory adapter implements the same semantics in-process via `Process.send/3`.

**Primary recommendation:** Define `subscribe_from_position/3` as `(stream_name_or_all, from_position, subscriber_pid_or_name)` — matching the existing `load_events` ordering convention (stream first, then position) — and return `{:ok, subscription_ref} | {:error, reason}`. Use a module-level `if Code.ensure_loaded?(Ecto.Schema) do ... end` guard around every Ecto schema module to make them compile-optional. Follow the Oban pattern for migrations: the library defines migration modules internally; users generate a host-app migration that calls `Orkestra.Projection.Migration.up()`.

---

## Architectural Responsibility Map

| Capability | Primary Tier | Secondary Tier | Rationale |
|------------|-------------|----------------|-----------|
| Event position tracking (subscribe_from_position) | EventStore adapter (InMemory / EventStoreDB) | EventStore behaviour (contract) | Position is adapter-provided by D-01; behaviour defines the callback contract only |
| Checkpoint persistence schema | Orkestra library (shared Ecto schema) | Consumer app Repo (Phase 2) | Orkestra owns the table definition; consumer Repo executes queries |
| Dead-letter persistence schema | Orkestra library (shared Ecto schema) | Consumer app Repo (Phase 2) | Same ownership model as Checkpoint |
| Storage adapter contract | Orkestra.Projection.Storage behaviour | Postgres adapter (Phase 2) | Behaviour defines write/4 and reset/2; Postgres adapter implements for Ecto |
| Retry delay computation | Projector.Lifecycle (pure function) | — | D-05: pure, no I/O; adapter-agnostic |
| Halt decision | Projector.Lifecycle (pure function) | — | D-05: pure return value, consumed by Phase 2 GenServer |

---

## Standard Stack

### Core (this phase)

| Library | Version | Purpose | Why Standard |
|---------|---------|---------|--------------|
| ecto | ~> 3.12 | Schema definition, Ecto.Multi data structure | Official Elixir data mapping library; Ecto.Multi is the composable-ops type; ~> 3.12 confirmed latest stable 3.14.0 [VERIFIED: hex.pm] |
| ecto_sql | ~> 3.12 | Ecto.Migration, Ecto.Migrator, SQL adapter support | Companion to ecto for SQL migrations and migration runner [VERIFIED: hex.pm] |
| postgrex | ~> 0.18 | PostgreSQL wire protocol driver for Ecto | Official Elixir Postgres driver; latest stable 0.22.2; ~> 0.18 covers the range [VERIFIED: hex.pm] |

All three are added as `optional: true` in `mix.exs` — consumers opt in; the library compiles without them.

Spear (~> 1.4, already in mix.exs) is used for the EventStoreDB `subscribe_from_position` implementation. [VERIFIED: mix.lock]

### Supporting (already present)

| Library | Version | Purpose | When to Use |
|---------|---------|---------|-------------|
| spear | ~> 1.4 | Spear.subscribe/4 for :all-stream catch-up subscriptions | EventStoreDB adapter's subscribe_from_position implementation |
| jason | ~> 1.2 | JSON serialization for event data stored in dead_letter | Already in mix.exs; used for dead-letter event serialization |

### Alternatives Considered

| Instead of | Could Use | Tradeoff |
|------------|-----------|----------|
| `Ecto.Multi` as ops type | Plain `{:ok, fun}` callback | Multi is already the Ecto transaction primitive; plain callback would duplicate its semantics without the Phase 2 merge benefit |
| Integer position in checkpoint | Opaque binary/string token | Integer position enables lag arithmetic (D-02); binary token would require adapter-specific deserialization |
| Process-message push (D-03) | Polling-based pull | Push matches EventStoreDB's subscription model so Phase 2 uses one code path for both adapters |

**Installation (add to mix.exs deps):**
```elixir
{:ecto, "~> 3.12", optional: true},
{:ecto_sql, "~> 3.12", optional: true},
{:postgrex, "~> 0.18", optional: true}
```

---

## Package Legitimacy Audit

> Note: the `gsd-tools package-legitimacy` seam supports npm/pypi/crates only; Hex.pm packages are verified directly via the Hex.pm API.

| Package | Registry | Age | Downloads | Source Repo | Verdict | Disposition |
|---------|----------|-----|-----------|-------------|---------|-------------|
| ecto | Hex.pm | ~10 yrs | 142M+ all-time | github.com/elixir-ecto/ecto | OK | Approved |
| ecto_sql | Hex.pm | ~7 yrs | 124M+ all-time | github.com/elixir-ecto/ecto_sql | OK | Approved |
| postgrex | Hex.pm | ~10 yrs | 136M+ all-time | github.com/elixir-ecto/postgrex | OK | Approved |

[VERIFIED: hex.pm] — all three packages confirmed at hex.pm/api/packages/{name} with official GitHub repos under `elixir-ecto` organization.

**Packages removed due to SLOP verdict:** none
**Packages flagged as suspicious SUS:** none

---

## Architecture Patterns

### System Architecture Diagram

```
EventStore behaviour
    │  (add @callback subscribe_from_position/3)
    ├─── InMemory adapter
    │        Agent state: %{streams, global_counter, subscribers}
    │        On subscribe: replay history from position → push to pid
    │        On append: increment counter, stamp global_position, push to all subscriber pids
    │
    └─── EventStoreDB adapter
             Spear.subscribe(conn, pid, :all, from: position)
             Maps Spear.Event.metadata.commit_position → integer global_position

Orkestra.Projection.Storage behaviour
    │  @callback write/4 → {:ok, ops} | {:error, reason}
    │  @callback reset/2 → :ok | {:error, reason}
    │  (ops type: Ecto.Multi.t() for Postgres; term() for Mongo/ES)
    │
    └─── [Phase 2] Postgres adapter implements write/4 returning Ecto.Multi.t()

Orkestra.Projection.Checkpoint   (Ecto schema, optional dep guarded)
    │  table: projection_checkpoints
    │  fields: projector_name, last_position, halted, halted_at, updated_at
    │
    └─── Orkestra.Projection.Migration.up/0   (creates projection_checkpoints + projection_dead_letters)

Orkestra.Projection.DeadLetter   (Ecto schema, optional dep guarded)
    │  table: projection_dead_letters
    │  fields: projector_name, position, event_data, error, attempts, occurred_at

Orkestra.Projector.Lifecycle   (pure functions, no deps)
    │  classify/1     → :retry | :park
    │  next_delay/3   → delay_ms :: non_neg_integer()
    │  should_halt?/2 → boolean()
    │  (consumes attempt count + config, returns decisions)
```

### Recommended Project Structure

```
lib/orkestra/
├── event_store.ex                     # existing — add subscribe_from_position/3 @callback
├── event_store/
│   ├── in_memory.ex                   # existing — extend Agent state, add subscribe_from_position impl
│   └── event_store_db.ex              # existing — add subscribe_from_position via Spear.subscribe/4
├── projection/
│   ├── storage.ex                     # NEW: Storage behaviour (write/4, reset/2)
│   ├── checkpoint.ex                  # NEW: Ecto schema (guarded by Code.ensure_loaded?)
│   ├── dead_letter.ex                 # NEW: Ecto schema (guarded by Code.ensure_loaded?)
│   └── migration.ex                   # NEW: up/0 and down/0 (Oban-style, guarded by Code.ensure_loaded?)
└── projector/
    └── lifecycle.ex                   # NEW: pure functions, zero deps

priv/
└── orkestra/
    └── migrations/
        └── 20260101000000_create_projection_tables.ex  # NEW: migration file
        # (OR: migration defined entirely inside Migration.up/0 without files)

test/orkestra/
├── event_store/
│   └── in_memory_subscription_test.exs  # NEW: subscribe_from_position tests
├── projection/
│   └── storage_test.exs                 # NEW: behaviour contract tests
└── projector/
    └── lifecycle_test.exs               # NEW: pure function unit tests
```

### Pattern 1: subscribe_from_position/3 Callback

**What:** New callback on EventStore behaviour; push-delivery model; both adapters implement it.

**Recommended signature** (Claude's Discretion):
```elixir
# Source: design based on existing load_events/2 ordering convention
@callback subscribe_from_position(
  stream_id :: stream_id() | :all,
  from_position :: non_neg_integer(),
  subscriber :: pid()
) :: {:ok, subscription_ref :: reference()} | {:error, term()}
```

Argument order matches the existing `load_events(stream_id, from_revision)` convention: stream first, then position. Subscriber pid is third (following Spear's own ordering of connection, subscriber, stream, opts).

**InMemory implementation sketch:**
```elixir
# Source: design based on Agent state extension pattern [ASSUMED]
# Agent state must expand from %{streams: map()} to:
# %{streams: map(), global_counter: non_neg_integer(), subscribers: [pid()], global_events: [stored_event_with_position()]}

def subscribe_from_position(:all, from_position, subscriber) do
  Agent.update(__MODULE__, fn state ->
    %{state | subscribers: [subscriber | state.subscribers]}
  end)
  # Replay history from position (exclusive: position > from_position)
  replay_history(from_position, subscriber)
  ref = make_ref()
  {:ok, ref}
end

defp replay_history(from_position, subscriber) do
  events = Agent.get(__MODULE__, &Map.get(&1, :global_events, []))
  events
  |> Enum.filter(fn e -> e.global_position > from_position end)
  |> Enum.each(fn e -> send(subscriber, e) end)
end
```

**Message format sent to subscriber:**
```elixir
# Each message is a stored_event() extended with :global_position
%{
  id: "uuid",
  type: "EventType",
  data: %{},
  metadata: %{},
  stream_revision: 0,
  global_position: 42   # the monotonic counter value
}
```

**EventStoreDB implementation sketch:**
```elixir
# Source: Spear.subscribe/4 docs [CITED: hexdocs.pm/spear/Spear.html]
def subscribe_from_position(:all, from_position, subscriber) do
  # Spear from: is exclusive for subscriptions — from_position matches D-01 semantics
  Spear.subscribe(@connection, subscriber, :all, from: from_position)
  # Returns {:ok, subscription_ref} from Spear directly
end
```

The EventStoreDB adapter must also extract `commit_position` from received `Spear.Event.t()` and surface it as `global_position` in the message delivered to the subscriber, so Phase 2's GenServer can update its checkpoint without knowing which adapter is in use.

### Pattern 2: Storage Behaviour with Multi-Shaped Ops (D-06)

**What:** `write/4` returns an opaque ops value; the Postgres adapter returns `Ecto.Multi.t()`; Mongo/ES adapters return their own idiomatic type. The behaviour itself does not mention `Ecto.Multi` — decoupling is by convention, not type.

```elixir
# Source: design pattern based on D-06 decision [ASSUMED]
defmodule Orkestra.Projection.Storage do
  @moduledoc """
  Behaviour for pluggable read-model storage adapters.

  ## write/4

  Returns an opaque `ops` term describing the write operations for a single
  event application. The Postgres adapter returns an `Ecto.Multi.t()` that
  the Projector GenServer (Phase 2) merges with the checkpoint update before
  calling `Repo.transaction/1`. Future adapters return their own idiomatic
  write descriptor.

  ## reset/2

  Clears all read-model state for a given projector (used by rebuild).
  """

  @type projector_name :: String.t()
  @type event :: map()
  @type opts :: keyword()
  @type ops :: term()

  @doc "Returns write operations for applying `event` to the read model."
  @callback write(projector_name(), event(), non_neg_integer(), opts()) ::
              {:ok, ops()} | {:error, term()}

  @doc "Resets all read-model state for `projector_name`."
  @callback reset(projector_name(), opts()) :: :ok | {:error, term()}
end
```

**Key insight:** `Ecto.Multi` is a pure data structure — no Repo required to construct it; the Repo is only needed when calling `Repo.transaction(multi)`. [CITED: hexdocs.pm/ecto/3.12.4/composable-transactions-with-multi.html] This means the Postgres adapter can build and return a `Multi.t()` from `write/4` without holding a Repo reference.

### Pattern 3: Ecto Schema with Optional Dep Guard

**What:** Wrap entire `defmodule` in `if Code.ensure_loaded?(Ecto.Schema)` so the module is only compiled when ecto is available. Wrapping just `use Ecto.Schema` inside an already-open module does NOT work — the `use` macro expands at compile time before the condition is evaluated. [CITED: github.com/elixir-lang/elixir/issues/8970]

```elixir
# Source: pattern from Elixir community [CITED: elixirforum.com/t/37318]
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
      timestamps(updated_at: :updated_at, inserted_at: false)
    end
  end
end
```

Same guard applies to `Orkestra.Projection.DeadLetter` and `Orkestra.Projection.Migration`.

**Validation:** Test with `mix compile --no-optional-deps --warnings-as-errors` to confirm the library compiles cleanly without ecto. [CITED: elixir.hexdocs.pm/library-guidelines.html]

### Pattern 4: Library-Owned Migrations (Oban Pattern)

**What:** Orkestra defines migration logic internally; consumer generates a host-app migration that delegates to `Orkestra.Projection.Migration.up/0`. No files in the consuming app's `priv/` need to be generated by Orkestra.

```elixir
# lib/orkestra/projection/migration.ex  (guarded)
if Code.ensure_loaded?(Ecto.Migration) do
  defmodule Orkestra.Projection.Migration do
    @moduledoc """
    Runs Orkestra's internal projection table migrations.

    ## Usage

        # In your application:
        mix ecto.gen.migration create_orkestra_projection_tables

        # In the generated migration file:
        defmodule MyApp.Repo.Migrations.CreateOrkestraProjectionTables do
          use Ecto.Migration
          def up, do: Orkestra.Projection.Migration.up()
          def down, do: Orkestra.Projection.Migration.down()
        end
    """

    use Ecto.Migration

    def up do
      create table(:projection_checkpoints, primary_key: false) do
        add :id, :binary_id, primary_key: true
        add :projector_name, :string, null: false
        add :last_position, :bigint, default: -1, null: false
        add :halted, :boolean, default: false, null: false
        add :halted_at, :utc_datetime_usec
        timestamps(inserted_at: false, updated_at: :updated_at)
      end

      create unique_index(:projection_checkpoints, [:projector_name])

      create table(:projection_dead_letters, primary_key: false) do
        add :id, :binary_id, primary_key: true
        add :projector_name, :string, null: false
        add :position, :bigint, null: false
        add :event_data, :map, null: false
        add :error, :text, null: false
        add :attempts, :integer, default: 0, null: false
        add :occurred_at, :utc_datetime_usec, null: false
      end

      create index(:projection_dead_letters, [:projector_name])
      create index(:projection_dead_letters, [:projector_name, :position])
    end

    def down do
      drop table(:projection_dead_letters)
      drop table(:projection_checkpoints)
    end
  end
end
```

**Note on `use Ecto.Migration` inside the guarded block:** The inner `defmodule` + `use Ecto.Migration` is safe here because the entire module is conditionally defined — the macro expansion only occurs if `Ecto.Migration` is loaded. [ASSUMED — consistent with the Code.ensure_loaded? full-module-wrap pattern]

### Pattern 5: Pure Projector.Lifecycle Functions

**What:** A module of pure functions — no I/O, no process state, no GenServer — that the Phase 2 GenServer calls to make retry/park/halt decisions.

```elixir
# lib/orkestra/projector/lifecycle.ex
defmodule Orkestra.Projector.Lifecycle do
  @moduledoc """
  Pure functions for projector error classification and retry decisions.
  No I/O. Fully unit-testable with ExUnit async: true.
  """

  @type config :: %{
    max_retries: non_neg_integer(),
    backoff_base_ms: non_neg_integer(),
    backoff_cap_ms: non_neg_integer()
  }

  @default_config %{
    max_retries: 5,
    backoff_base_ms: 500,
    backoff_cap_ms: 30_000
  }

  @doc "Returns the backoff delay in milliseconds for the given attempt number (0-indexed)."
  @spec next_delay(non_neg_integer(), config()) :: non_neg_integer()
  def next_delay(attempt, config \\ @default_config) do
    base = config.backoff_base_ms
    cap = config.backoff_cap_ms
    # Pure integer arithmetic: base * 2^attempt, capped
    # Bitwise.bsl(1, attempt) == 2^attempt without :math float conversion
    import Bitwise, only: [bsl: 2]
    min(cap, base * bsl(1, attempt))
  end

  @doc "Returns :retry or :park based on attempt count vs max_retries."
  @spec classify(non_neg_integer(), config()) :: :retry | :park
  def classify(attempts, config \\ @default_config) do
    if attempts < config.max_retries, do: :retry, else: :park
  end

  @doc "Returns true when the projector should halt (attempts exhausted)."
  @spec should_halt?(non_neg_integer(), config()) :: boolean()
  def should_halt?(attempts, config \\ @default_config) do
    attempts >= config.max_retries
  end
end
```

**Why `Bitwise.bsl` not `:math.pow`:** `Bitwise.bsl(1, attempt)` is pure integer arithmetic, returns an integer directly, and avoids float rounding. `:math.pow` returns a float requiring `round()` which can overflow for large attempts. [CITED: github.com/elixir-tesla/tesla — Tesla middleware/retry.ex uses this pattern]

**Unit test pattern (no I/O, async: true):**
```elixir
defmodule Orkestra.Projector.LifecycleTest do
  use ExUnit.Case, async: true

  alias Orkestra.Projector.Lifecycle

  describe "next_delay/2" do
    test "attempt 0 returns base" do
      assert Lifecycle.next_delay(0, %{backoff_base_ms: 500, backoff_cap_ms: 30_000}) == 500
    end

    test "attempt 1 returns base * 2" do
      assert Lifecycle.next_delay(1, %{backoff_base_ms: 500, backoff_cap_ms: 30_000}) == 1_000
    end

    test "caps at backoff_cap_ms" do
      assert Lifecycle.next_delay(20, %{backoff_base_ms: 500, backoff_cap_ms: 30_000}) == 30_000
    end
  end

  describe "classify/2" do
    test "returns :retry when attempts < max_retries" do
      assert Lifecycle.classify(2, %{max_retries: 5}) == :retry
    end

    test "returns :park when attempts == max_retries" do
      assert Lifecycle.classify(5, %{max_retries: 5}) == :park
    end
  end
end
```

### Anti-Patterns to Avoid

- **Embedding Repo calls in Storage behaviour callbacks:** `write/4` must return an ops description, not execute writes. Execution happens in Phase 2's GenServer.
- **Using `use Ecto.Schema` directly in module body when ecto is optional:** Causes `CompileError` when ecto is not installed. Always wrap the entire `defmodule` block.
- **Polling in InMemory subscribe_from_position:** Phase 2's GenServer must work identically with InMemory and EventStoreDB. InMemory must push messages, not require the caller to poll.
- **Float arithmetic for backoff:** Use `Bitwise.bsl(1, attempt)` not `:math.pow/2` to avoid float rounding issues.
- **Agent.get_and_update race in InMemory push delivery:** When appending and pushing to subscribers, the push must occur inside the Agent update or in a disciplined sequence — not after a separate `Agent.get` — to avoid delivering out-of-order on concurrent appends.

---

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| Composable DB write ops | Custom operation DSL | `Ecto.Multi` (already a composable data structure) | Multi.append/2 and Multi.merge/2 handle composition; it is Repo-independent until transaction execution |
| Integer exponentiation for backoff | `:math.pow` + `round` | `Bitwise.bsl(1, attempt)` | Pure integer, no float overflow, no rounding; Tesla middleware uses this exact pattern |
| Schema struct definition | Hand-crafted maps | `Ecto.Schema` with `use` guard | Schema provides changeset validation, Repo integration, and type-safe fields for free |
| Catch-up subscription on EventStoreDB | Custom gRPC streaming | `Spear.subscribe/4` with `from: position` | Spear handles connection management, backpressure, reconnect, and checkpoint extraction |

---

## Common Pitfalls

### Pitfall 1: subscribe_from_position/3 Position Semantics (Exclusive vs Inclusive)

**What goes wrong:** Subscriber receives the event AT `from_position` again on restart, causing a duplicate event application.

**Why it happens:** Spear's `subscribe/4` with `from: N` for subscriptions is **exclusive** (delivers events with position > N), not inclusive. InMemory must match this semantic exactly. [CITED: hexdocs.pm/spear/Spear.html]

**How to avoid:** Use `> from_position` (not `>=`) when filtering history replay in InMemory. Document the exclusive semantics in the `@callback` doc.

**Warning signs:** A projector reprocesses the last event after restart, causing duplicate read-model entries.

### Pitfall 2: Module Does Not Compile Without Ecto (CompileError)

**What goes wrong:** `mix compile --no-optional-deps` raises `(CompileError) module Ecto.Schema is not loaded`.

**Why it happens:** `use Ecto.Schema` inside an already-open `defmodule` block is evaluated at compile time even when wrapped in `if Code.ensure_loaded?`. [CITED: github.com/elixir-lang/elixir/issues/8970]

**How to avoid:** Wrap the ENTIRE `defmodule ... end` block in `if Code.ensure_loaded?(Ecto.Schema) do`. Test with `mix compile --no-optional-deps --warnings-as-errors`.

**Warning signs:** Library users without ecto in their app get `CompileError` when adding `{:orkestra, ...}` to their mix.exs.

### Pitfall 3: InMemory Agent State Race on Subscribe + Append

**What goes wrong:** A subscriber is added to the Agent state, then concurrent `append_events` calls push events before the history replay completes, causing out-of-order delivery or gaps.

**Why it happens:** The current InMemory Agent state is `%{streams: map()}` — a single shared map. If subscription registration and history replay are not atomic with respect to concurrent appends, a subscriber can miss events appended between the `subscribe` call and the `replay_history` call, or receive events out of order.

**How to avoid:** In `subscribe_from_position/3`, do the subscriber registration and history replay inside a single `Agent.get_and_update` or use a `GenServer` instead of a plain `Agent` to serialize the operation. For the test use-case (which is single-process), a simpler discipline also works: the test is the only appender during subscription setup.

**Warning signs:** InMemory subscription tests are flaky under concurrent `append_events` calls.

### Pitfall 4: Storage.write/4 Returns a Repo-Bound Closure

**What goes wrong:** The ops returned by `write/4` capture a Repo module or connection pid, making the result non-portable and preventing Phase 2 from choosing the Repo at transaction time.

**Why it happens:** An implementer does `{:ok, fn -> Repo.insert(changeset) end}` instead of returning a pure `Ecto.Multi.t()`.

**How to avoid:** The Postgres adapter's `write/4` must return `{:ok, %Ecto.Multi{}}` — a data structure, not a closure. Document this in the Storage behaviour's `@doc`.

### Pitfall 5: Exponential Backoff Integer Overflow

**What goes wrong:** `base * Bitwise.bsl(1, attempt)` overflows for large attempt numbers (attempt > 62 for 64-bit integers).

**Why it happens:** `Bitwise.bsl(1, 63)` produces a very large integer on 64-bit BEAM; multiplication overflows to a negative number or raises.

**How to avoid:** Always apply the cap BEFORE multiplication: `min(cap, base * bsl(1, min(attempt, 62)))`. Or: if `attempt > max_retries` (e.g. 5), the cap is hit long before overflow. The `max_retries` config keeps attempt values small in practice.

---

## Code Examples

### EventStore Behaviour Extension

```elixir
# Source: design based on existing Orkestra.EventStore @callback pattern [ASSUMED — mirrors existing callbacks]

@doc """
Asynchronously subscribes `subscriber` to receive events from `stream_id` starting
after `from_position` (exclusive). Pushes messages of the form:

    stored_event() with global_position :: non_neg_integer() key added

Terminates with `{:eos, ref, :closed | :dropped}` on subscription end.

Use `:all` as `stream_id` to subscribe to all events across all streams.
"""
@callback subscribe_from_position(
  stream_id :: stream_id() | :all,
  from_position :: non_neg_integer(),
  subscriber :: pid()
) :: {:ok, subscription_ref :: reference()} | {:error, term()}
```

### InMemory Agent State Extension

```elixir
# Source: design for D-03 push delivery [ASSUMED]
# Extend start_link to initialize the new state keys
def start_link(opts \\ []) do
  name = opts[:name] || __MODULE__
  Agent.start_link(fn ->
    %{
      streams: %{},
      global_counter: 0,
      # List of {pid, ref} tuples; ref returned to subscriber
      subscribers: [],
      # All events in global order: [%{...stored_event, global_position: N}]
      global_events: []
    }
  end, name: name)
end
```

### Checkpoint Schema (with halted status for ERR-03/ERR-04)

```elixir
# Source: design based on ERR-02/ERR-04 requirements + Ecto.Schema conventions [ASSUMED]
if Code.ensure_loaded?(Ecto.Schema) do
  defmodule Orkestra.Projection.Checkpoint do
    use Ecto.Schema

    @primary_key {:id, :binary_id, autogenerate: true}

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

### DeadLetter Schema

```elixir
# Source: design based on ERR-02 requirements fields [ASSUMED]
if Code.ensure_loaded?(Ecto.Schema) do
  defmodule Orkestra.Projection.DeadLetter do
    use Ecto.Schema

    @primary_key {:id, :binary_id, autogenerate: true}

    schema "projection_dead_letters" do
      field :projector_name, :string
      field :position, :integer
      field :event_data, :map       # serialized event (Jason-encodable)
      field :error, :string         # inspect(reason) or message
      field :attempts, :integer, default: 0
      field :occurred_at, :utc_datetime_usec
    end
  end
end
```

---

## State of the Art

| Old Approach | Current Approach | When Changed | Impact |
|--------------|------------------|--------------|--------|
| Spear.subscribe_to_all/3 (hypothetical) | Spear.subscribe/4 with stream_name: :all | Spear 1.x design | Use Spear.subscribe/4 — there is no separate subscribe_to_all function [CITED: hexdocs.pm/spear/Spear.html] |
| :math.pow for backoff | Bitwise.bsl for 2^n | Long-standing Elixir idiom | Integer arithmetic, no float rounding |
| Library-owned migration files in priv/ | Library ships Migration.up/0; user generates wrapper migration | Oban pattern, industry standard | Cleaner separation; host app controls timing and Repo |

**Deprecated/outdated:**
- Registering `ecto`/`ecto_sql`/`postgrex` in `extra_applications` manually: not needed in Elixir 1.8+ for optional deps. [CITED: kianmeng.org/2021/03/optional-dependencies]

---

## Assumptions Log

| # | Claim | Section | Risk if Wrong |
|---|-------|---------|---------------|
| A1 | `if Code.ensure_loaded?(Ecto.Schema) do defmodule ... end` correctly gates the entire module at compile time | Pattern 3, Pitfall 2 | If the guard does not work as described, schema modules will fail to compile without ecto — must be tested with `--no-optional-deps` |
| A2 | `use Ecto.Migration` inside a `Code.ensure_loaded?` full-module-wrap also works (not just `use Ecto.Schema`) | Pattern 4 | If Migration's `use` has a stricter expansion than Schema, the migration module compile guard may fail — test separately |
| A3 | InMemory `subscribe_from_position` can use a plain Agent with a single-state `Agent.get_and_update` call that atomically registers the subscriber and snapshots existing events for replay | Pattern 1, Pitfall 3 | If Agent.get_and_update is too coarse and causes contention in multi-process tests, a GenServer conversion may be needed |
| A4 | Spear.subscribe/4 with `from: integer` is exclusive (delivers events with position > N) | Pattern 1, Pitfall 1 | If from: is inclusive, every restart re-delivers the last event — must be verified by reading an EventStoreDB test or official Spear test suite |
| A5 | The `global_position` extracted from `Spear.Event.metadata.commit_position` is a plain integer compatible with `non_neg_integer()` and can be stored directly in the checkpoint | Architecture Patterns, EventStoreDB adapter sketch | If commit_position is a struct ({prepare, commit} tuple) not an integer, the D-01 "single integer" contract breaks — verify against Spear.Event.t() source |
| A6 | postgrex ~> 0.18 is the correct version range (latest stable 0.22.2); ecto/ecto_sql ~> 3.12 are compatible with Elixir 1.18 | Standard Stack | Wrong version constraint causes dep resolution failure for consumers |

---

## Open Questions

1. **Spear commit_position type for `from:` parameter on :all stream**
   - What we know: `Spear.Event.metadata.commit_position` is documented as a large integer. `Spear.subscribe/4` accepts `from: integer` for :all. `Spear.Event.to_checkpoint/1` converts an event to `Spear.Filter.Checkpoint.t()` for use as `from:`. [CITED: hexdocs.pm/spear/Spear.Event.html]
   - What's unclear: Whether `from: commit_position_integer` directly works, or whether `from: Spear.Event.to_checkpoint(event)` is required for :all subscriptions in production scenarios where `prepare_position != commit_position`.
   - Recommendation: Use `Spear.Event.to_checkpoint/1` in the EventStoreDB adapter's push handler to persist the checkpoint value, and use the `commit_position` integer for the `from:` parameter (since D-01 maps it to a plain integer). If EventStoreDB requires a checkpoint struct for :all `from:`, the adapter can map the stored integer to a checkpoint internally. Add an explicit test against a live EventStoreDB instance in Phase 2.

2. **InMemory Agent vs. GenServer for subscriber tracking**
   - What we know: The current InMemory adapter uses a plain Agent. Adding subscriber pids to Agent state means the Agent process holds references to subscriber processes; the Agent update callback must be pure.
   - What's unclear: Whether the test suite will exercise concurrent `subscribe` + `append` calls that expose ordering issues with a plain Agent.
   - Recommendation: Start with Agent; document the single-process assumption in a module comment; convert to GenServer in a follow-up task if Phase 2 tests reveal ordering failures.

3. **`:ultimus` config-key bug in `EventStore.impl/0`**
   - What we know: `event_store.ex` reads `Application.get_env(:ultimus, ...)` — wrong app key; should be `:orkestra`. CFG-01 schedules the fix in Phase 3.
   - What's unclear: Whether Phase 1's `subscribe_from_position/3` tests need to call `impl/0` (which would require the consumer to configure `:ultimus`).
   - Recommendation: Do not fix the bug in Phase 1. Tests for `subscribe_from_position/3` should call the adapter directly (e.g., `InMemory.subscribe_from_position(...)`) rather than routing through `impl/0`, avoiding the bug.

---

## Environment Availability

| Dependency | Required By | Available | Version | Fallback |
|------------|------------|-----------|---------|----------|
| Elixir | All | ✓ | 1.18.4 | — |
| Erlang/OTP | All | ✓ | OTP 27 | — |
| Mix | Build/test | ✓ | 1.18.4 | — |
| ExUnit | Tests | ✓ | built-in | — |
| ecto | Checkpoint/DeadLetter schemas + migrations | ✗ (not yet in mix.lock) | — | Code.ensure_loaded? guard; add to mix.exs as optional dep |
| ecto_sql | Migration module | ✗ (not yet in mix.lock) | — | Same optional dep guard |
| postgrex | Not needed in Phase 1 (no Repo queries) | ✗ | — | Not needed until Phase 2 |
| EventStoreDB | subscribe_from_position EventStoreDB adapter test | ✗ | — | InMemory adapter covers Phase 1 tests; EventStoreDB needed in Phase 2+ integration tests |

**Missing dependencies with no fallback:** None — the EventStoreDB adapter implementation can be coded in Phase 1 but its integration tests run in Phase 2 against a live EventStoreDB. Phase 1 unit tests use InMemory only.

**Missing dependencies with fallback:** ecto/ecto_sql — must be added to mix.exs as optional deps before Phase 1 implementation; schemas/migrations are guarded to compile only when present.

---

## Validation Architecture

### Test Framework

| Property | Value |
|----------|-------|
| Framework | ExUnit (built-in, Elixir 1.18) |
| Config file | `test/test_helper.exs` (exists; currently starts PubSub supervisor) |
| Quick run command | `mix test test/orkestra/projector/lifecycle_test.exs` |
| Full suite command | `mix test` |

### Phase Requirements → Test Map

| Req ID | Behavior | Test Type | Automated Command | File Exists? |
|--------|----------|-----------|-------------------|-------------|
| PROJ-02 | subscribe_from_position delivers history then live events in order | unit | `mix test test/orkestra/event_store/in_memory_subscription_test.exs` | ❌ Wave 0 |
| PROJ-02 | EventStoreDB adapter subscribe_from_position compiles + returns {:ok, ref} | unit (compile-only) | `mix test test/orkestra/event_store/event_store_db_test.exs` | ❌ Wave 0 |
| STORE-01 | Storage behaviour contract: a module implementing write/4 and reset/2 passes | unit | `mix test test/orkestra/projection/storage_test.exs` | ❌ Wave 0 |
| ERR-01 | Lifecycle.next_delay/2 returns correct backoff for attempt 0, 1, 2, cap | unit | `mix test test/orkestra/projector/lifecycle_test.exs` | ❌ Wave 0 |
| ERR-01 | Lifecycle.classify/2 returns :retry when attempts < max_retries | unit | `mix test test/orkestra/projector/lifecycle_test.exs` | ❌ Wave 0 |
| ERR-02 | DeadLetter schema fields exist (projector_name, position, event_data, error, attempts, occurred_at) | unit (if ecto present) | `mix test test/orkestra/projection/schemas_test.exs` | ❌ Wave 0 |
| ERR-03 | Lifecycle.classify/2 returns :park and should_halt? returns true when exhausted | unit | `mix test test/orkestra/projector/lifecycle_test.exs` | ❌ Wave 0 |

All test files are Wave 0 gaps (none exist yet).

### Sampling Rate

- **Per task commit:** `mix test test/orkestra/projector/lifecycle_test.exs --seed 0`
- **Per wave merge:** `mix test`
- **Phase gate:** `mix test && mix compile --no-optional-deps --warnings-as-errors`

### Wave 0 Gaps

- [ ] `test/orkestra/event_store/in_memory_subscription_test.exs` — covers PROJ-02 InMemory push delivery
- [ ] `test/orkestra/event_store/event_store_db_test.exs` — covers PROJ-02 EventStoreDB adapter compiles
- [ ] `test/orkestra/projection/storage_test.exs` — covers STORE-01 behaviour contract
- [ ] `test/orkestra/projection/schemas_test.exs` — covers ERR-02 schema fields (conditional on ecto present)
- [ ] `test/orkestra/projector/lifecycle_test.exs` — covers ERR-01, ERR-03
- [ ] `test/test_helper.exs` update — may need `Application.put_env(:orkestra, Orkestra.EventStore, adapter: Orkestra.EventStore.InMemory)` for subscribe tests

---

## Security Domain

> security_enforcement: true; security_asvs_level: 1

### Applicable ASVS Categories

| ASVS Category | Applies | Standard Control |
|---------------|---------|-----------------|
| V2 Authentication | no | Phase 1 is library contracts, no auth surface |
| V3 Session Management | no | No sessions in this phase |
| V4 Access Control | no | No access control surface in contract definitions |
| V5 Input Validation | yes (low surface) | Checkpoint/DeadLetter changesets validate types; Lifecycle config validated at call site |
| V6 Cryptography | no | No cryptographic operations |

### Known Threat Patterns for Elixir CQRS Library

| Pattern | STRIDE | Standard Mitigation |
|---------|--------|---------------------|
| Unsafe term deserialization in event_data | Tampering | Use `:safe` atom on `:erlang.binary_to_term` (Snapshot module already does this); JSON (Jason) for event_data in DeadLetter |
| Subscriber pid injection via subscribe_from_position | Elevation of Privilege | Only accept `pid()` from trusted internal callers; the InMemory adapter pushes to pids passed in — no external input validation needed in v1 |
| Unbounded retry delay growth | Denial of Service | Enforced by cap in `next_delay/2`; always apply `min(cap, ...)` |

---

## Project Constraints (from CLAUDE.md)

- **Language:** Elixir 1.18+ / Erlang OTP 27+
- **Formatting:** `mix format` required; `.formatter.exs` covers `lib/`, `test/`, `config/`
- **Docs:** `@moduledoc` and `@doc` required on every public module and function
- **Specs:** `@spec` required on all public functions
- **Error style:** Return tuples `{:ok, value} | {:error, reason}`; structured atom reasons (not string messages)
- **Logging:** `Logger.{debug,info,warning,error}` with structured metadata; `orkestra: :domain_tag` key
- **Optional deps:** Follow the existing `:amqp`/`:spear` `optional: true` pattern for ecto/ecto_sql/postgrex
- **Behaviour pattern:** `@callback` + `@impl true` + `@behaviour Module` (not to be changed)
- **Config key bug:** Do NOT silently fix the `:ultimus` → `:orkestra` config key; that is CFG-01 in Phase 3
- **Do not replace:** Existing EventStore behaviour and adapters are to be extended, not replaced

---

## Sources

### Primary (MEDIUM confidence)

- [Spear.subscribe/4 documentation](https://spear.hexdocs.pm/Spear.html) — subscribe/4 signature, :all stream, from: parameter, subscriber messages, to_checkpoint/1
- [Spear.Event documentation](https://spear.hexdocs.pm/Spear.Event.html) — commit_position, prepare_position fields
- [Ecto.Multi composable transactions guide](https://hexdocs.pm/ecto/3.12.4/composable-transactions-with-multi.html) — Multi as data structure, Repo independence, append/merge API
- [Elixir library guidelines on optional deps](https://elixir.hexdocs.pm/library-guidelines.html) — `--no-optional-deps` compile test recommendation
- [Oban.Migrations pattern](https://oban.hexdocs.pm/2.5.0/Oban.Migrations.html) — library ships up/0 and down/0; user generates wrapper migration

### Secondary (LOW confidence — web research)

- [Elixir forum on optional dependencies](https://elixirforum.com/t/is-there-a-guide-for-relying-on-optional-dependencies-in-a-library/37318) — Code.ensure_loaded? full-module-wrap pattern
- [Elixir issue #8970](https://github.com/elixir-lang/elixir/issues/8970) — Code.ensure_loaded? wrapping `use` inside module does NOT work
- [Tesla middleware/retry.ex](https://github.com/elixir-tesla/tesla) — Bitwise.bsl(1, attempt) for 2^n backoff calculation
- [Hex.pm API](https://hex.pm/api/packages/) — verified ecto 3.14.0, ecto_sql 3.14.0, postgrex 0.22.2

### Codebase (HIGH confidence — direct read)

- `lib/orkestra/event_store.ex` — existing behaviour to extend
- `lib/orkestra/event_store/in_memory.ex` — existing Agent state to extend
- `lib/orkestra/event_store/event_store_db.ex` — existing Spear adapter to extend
- `lib/orkestra/command_envelope.ex` — retry field shape reference (attempts, max_retries)
- `mix.exs` — existing optional dep pattern (amqp, spear)
- `test/` directory — 85 tests passing, ExUnit async: true pattern established

---

## Metadata

**Confidence breakdown:**
- Standard stack: MEDIUM — ecto/ecto_sql/postgrex versions verified on hex.pm; Spear version from mix.lock
- Architecture: MEDIUM — Spear subscribe/4 API verified via hexdocs; InMemory Agent design is ASSUMED
- Pitfalls: MEDIUM — Code.ensure_loaded? limitation cited from official Elixir issue; backoff formula cited from Tesla; position exclusivity cited from Spear docs

**Research date:** 2026-06-24
**Valid until:** 2026-07-24 (stable Elixir/Ecto/Spear APIs; 30-day window)
