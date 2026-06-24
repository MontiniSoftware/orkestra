# Phase 2: Projector GenServer + Ecto Adapter - Research

**Researched:** 2026-06-24
**Domain:** Elixir GenServer sequential event processing, Ecto.Multi atomic transactions, per-projection isolated Ecto.Repo, SQL.Sandbox cross-process testing
**Confidence:** MEDIUM (Ecto/GenServer APIs confirmed via official hexdocs; per-projection Repo isolation pattern confirmed via ecto_sql migration docs; SQL Sandbox cross-process pattern confirmed via official hexdocs)

---

<user_constraints>
## User Constraints (from CONTEXT.md)

### Locked Decisions

**Subscription & Catch-up → Live**
- Consume events via the adapter's unified push subscription — `subscribe_from_position` replays history from the checkpoint then streams live events to the GenServer as process messages, giving a single code path (consistent with Phase 1 D-03).
- Process events strictly sequentially, one event per `handle_info`, using the GenServer mailbox as the in-order queue. No concurrent application to the same read model (success criterion 2).
- No hard catch-up/live state machine in v1 — the continuous ordered stream is treated uniformly. A `caught_up?` flag may be tracked only as a hook for later telemetry (Phase 4); it does not gate processing.
- Subscribe from the checkpoint's `last_position` using exclusive `>` semantics (Phase 1 D-01), so a restart resumes at the next unprocessed event (success criterion 1). Default `last_position` is `-1`, i.e. replay from position 0.

**Ecto Repo & Atomic Transaction**
- The checkpoint update is written inside the same `Ecto.Multi` as the read-model writes, via `Multi.insert` with `on_conflict` upsert keyed on the `projector_name` unique index (replacing `last_position`/`halted`/`updated_at`).
- The checkpoint, dead_letter, and read-model tables all live in the same per-projection Repo, so the one transaction spans all of them — this is what makes STORE-03's atomic co-write possible. A shared/global repo was rejected because it would break atomicity.
- The GenServer receives its Repo module via projector config/opts at start (not derived implicitly from the name).
- One `Ecto.Multi` transaction per event — the simplest construction that satisfies STORE-03. Batching multiple events per transaction is deferred (a throughput optimization, not a correctness need in v1).
- A simulated crash between the checkpoint write and the read-model write must not produce a double-write or missed-write on restart (success criterion 3) — guaranteed by the single-transaction commit.

**Halt & Error Behavior**
- On retry exhaustion the GenServer persists `halted=true` to the checkpoint and writes the event to the dead_letter store, then stays alive in an idle halted state (it does not crash). This keeps the halt visible and avoids supervisor restart loops (success criterion 4, ERR-03/ERR-04).
- Retries are scheduled with `Process.send_after` using `Lifecycle.next_delay/2` backoff; the same failing event is re-attempted (no blocking sleep that would stall the process).
- The dead_letter insert and the checkpoint `halted=true` update commit in a single transaction (atomic halt).
- Resume-after-halt is out of scope for Phase 2 — a halted projector stays parked until a later phase / manual intervention resolves it.

**Test Strategy (Ecto/Postgres adapter)**
- Test against real Postgres via `Ecto.Adapters.SQL.Sandbox`. The Storage behaviour and `Lifecycle` stay pure/unit-testable, but the Postgres adapter and the atomic-commit GenServer tests genuinely need a database.
- DB-dependent tests are tagged (e.g. `@tag :postgres`) so they are runnable locally/CI but skippable when no database is present — keeping the existing fast async suite green without Postgres.
- The crash/restart end-to-end test (success criterion 3) uses the InMemory EventStore + a real test Repo to simulate a crash between the checkpoint and read-model writes and assert no double/missed write on restart.
- Use `SQL.Sandbox` in manual/shared mode so the GenServer process can share the test transaction/ownership.

### Claude's Discretion
- Exact GenServer module name(s) and internal state shape.
- Postgres adapter module name and how `write/4` ops compose into the `Ecto.Multi` (the concrete "Multi-shaped ops" representation from Phase 1 D-06).
- Naming of the `caught_up?` flag and whether to include it at all in Phase 2.
- Test helper/fixture structure, example read-model schema used in tests.
- Backoff defaults already set in `Lifecycle` may be tuned.

### Deferred Ideas (OUT OF SCOPE)
- `use Orkestra.Projector` DSL, Projection Supervisor, mix tasks, `:orkestra` config wiring → Phase 3.
- Telemetry spans, lag/rebuild/error/halt metrics → Phase 4.
- MCP generator + Queries module → Phase 5.
- Auto-resume / dead-letter replay after halt → later phase.
- Batched multi-event transactions (throughput) → future optimization.
</user_constraints>

---

<phase_requirements>
## Phase Requirements

| ID | Description | Research Support |
|----|-------------|------------------|
| PROJ-03 | A projector persists its last-processed position and resumes from it after a restart | GenServer init reads Checkpoint via Repo; subscribes from `last_position` using exclusive > semantics (D-01); restart resumes from persisted position |
| PROJ-04 | A projector processes events strictly in order (single consumer per projector, no concurrent application) | GenServer mailbox is FIFO and processes one message at a time — sequential delivery guaranteed by OTP process model; `handle_info` for each pushed event |
| STORE-02 | A PostgreSQL/Ecto storage adapter persists read-model updates | `Orkestra.Projection.Storage.Postgres` implements `write/4` returning `Ecto.Multi.t()` (D-06); committed by GenServer via `Repo.transaction/1` |
| STORE-03 | The checkpoint update and the read-model write commit atomically in a single `Ecto.Multi` transaction | `Multi.append/2` or `Multi.merge/2` combines Storage adapter's Multi with the checkpoint upsert Multi; single `Repo.transaction(combined_multi)` call |
| STORE-04 | A projection's storage is isolated in its own `Ecto.Repo` with a dedicated connection pool | Consumer defines a module with `use Ecto.Repo, otp_app: :my_app, adapter: Ecto.Adapters.Postgres`; configured with `migration_source: "<projector>_schema_migrations"` and `priv: "priv/<projector>"`; passed to GenServer via opts |
| MIG-01 | Each projection owns its tables and an isolated migration history, separate from the host app's migrations | Per-projection Repo uses `migration_source` to name a unique `<projector>_schema_migrations` table; Ecto.Migrator can run from `[{version, Module}]` tuples without files — no shared migration table |
| ERR-04 | A halted projector's status is persisted and observable (no silent stall) | `halted: true` written to `projection_checkpoints` in same transaction as dead_letter insert; GenServer stays alive in idle halted state; Checkpoint schema has `halted` and `halted_at` fields |
| READ-01 | A developer can query a read model directly with Ecto (orkestra owns the write/lifecycle side, not the query shape) | Per-projection Repo is a full `Ecto.Repo` — callers use `Repo.all/2`, `Repo.get/3`, `Repo.one/2` directly on read-model schemas; no additional Orkestra query layer needed |
</phase_requirements>

---

## Summary

Phase 2 builds the runtime of the projection subsystem on top of Phase 1's pure contracts. The three central technical challenges are: (1) atomic commit of the read-model write + checkpoint update in a single `Ecto.Multi` transaction using `Multi.append/2` to merge the Storage adapter's ops with a checkpoint upsert; (2) the per-projection isolated Ecto.Repo pattern that gives each projector its own connection pool, migration history (`migration_source`), and `priv/` directory; and (3) testing a GenServer that calls a real Repo with `Ecto.Adapters.SQL.Sandbox` in manual mode, using `Sandbox.allow/3` to grant the GenServer process access to the test's database connection.

The GenServer design is straightforward: `handle_info` for each pushed event from `subscribe_from_position`, sequential processing guaranteed by the OTP mailbox, `Process.send_after` for non-blocking retry scheduling, and a halted-state flag in GenServer state that gates further event processing without crashing. Atomicity is the non-negotiable correctness property — `Repo.transaction(combined_multi)` either commits checkpoint + read-model together or rolls both back, eliminating partial-write bugs on crash/restart. The `on_conflict` upsert on `projector_name` means the same `Multi.insert` call handles both first-start (insert) and resume-after-restart (update) without a separate load-or-create step.

The main pitfall is the SQL.Sandbox ownership model: the GenServer process is not the test process that checked out the connection, so `Sandbox.allow(Repo, self(), genserver_pid)` is required before any Repo call from the GenServer. Missing this produces a cryptic `DBConnection.OwnershipError` rather than a meaningful failure. A secondary pitfall is the `on_conflict` column target — using `conflict_target: :projector_name` (the column) rather than a constraint name requires the column be listed, matching the unique index added by Phase 1's migration.

**Primary recommendation:** Implement `Orkestra.Projector.GenServer` and `Orkestra.Projection.Storage.Postgres` as two focused modules. The GenServer holds `repo`, `storage_adapter`, `projector_name`, `lifecycle_config`, `attempts`, and `halted` in its state. The Postgres adapter implements `write/4` by returning `Ecto.Multi.t()` (the read-model Multi fragment); the GenServer merges it with the checkpoint upsert Multi via `Multi.append/2` and calls `Repo.transaction/1`. Tests use manual SQL.Sandbox mode with explicit `Sandbox.allow/3`.

---

## Architectural Responsibility Map

| Capability | Primary Tier | Secondary Tier | Rationale |
|------------|-------------|----------------|-----------|
| Event subscription + delivery | EventStore adapter (InMemory / EventStoreDB) | GenServer `handle_info` (consumer) | push delivery already designed in Phase 1; GenServer is a pure mailbox consumer |
| Sequential event ordering | OTP GenServer mailbox (FIFO) | — | Guaranteed by BEAM process model; no application-level queue needed |
| Checkpoint read on startup | GenServer `init/1` via Repo | Checkpoint schema (Phase 1) | GenServer loads the persisted position at start; Repo/schema owns the read |
| Read-model + checkpoint atomic write | GenServer (commits the Multi) | Storage.Postgres (builds read-model Multi), Checkpoint upsert (built inline) | GenServer assembles and commits; adapters provide the component Multis |
| Retry scheduling | GenServer (Process.send_after) | Lifecycle (pure delay computation) | No blocking sleep; Lifecycle is stateless, GenServer holds attempt count |
| Halt persistence | GenServer (atomic transaction) | Checkpoint schema, DeadLetter schema | `halted=true` + dead_letter insert in one Repo.transaction — same pattern as normal checkpoint update |
| Read-model queryability | Per-projection Ecto.Repo (consumer-defined) | Ecto schemas (consumer-defined) | Orkestra owns the write path; query shape is consumer's responsibility (READ-01) |
| Isolated migration history | Per-projection Repo (`migration_source` config) | Ecto.Migrator | Each projector's Repo has its own `<name>_schema_migrations` table |

---

## Standard Stack

### Core

| Library | Version | Purpose | Why Standard |
|---------|---------|---------|--------------|
| ecto | ~> 3.12 | Ecto.Multi composition, Ecto.Repo, Ecto.Schema, changeset/upsert | Already in mix.exs as optional dep; `Multi.append/2` is the merge primitive; ~> 3.12 covers 3.14.x [VERIFIED: mix.exs] |
| ecto_sql | ~> 3.12 | Repo.transaction, Ecto.Adapters.SQL.Sandbox, Ecto.Migrator | Already in mix.exs; provides SQL adapter implementation and test sandbox [VERIFIED: mix.exs] |
| postgrex | ~> 0.18 | Postgres wire protocol driver for the per-projection Repo | Already in mix.exs as optional dep; required for Ecto.Adapters.Postgres [VERIFIED: mix.exs] |

All three are `optional: true` in mix.exs — already present from Phase 1. No new deps needed for Phase 2.

### Supporting (already present)

| Library | Version | Purpose | When to Use |
|---------|---------|---------|-------------|
| jason | ~> 1.2 | event_data serialization in dead_letter (`:map` jsonb field) | Already in mix.exs; used for dead-letter event payload encoding |

### Alternatives Considered

| Instead of | Could Use | Tradeoff |
|------------|-----------|----------|
| `Multi.append/2` to compose Multis | `Multi.merge/2` with function | `append/2` is simpler when both Multis are already built; `merge/2` is better when the second Multi depends on results of the first — use `append/2` for flat composition here |
| `conflict_target: :projector_name` (column) | `conflict_target: {:unsafe_fragment, "ON CONSTRAINT ..."}` | Column reference is safe and explicit; unsafe_fragment is only needed for expression indexes |
| Manual SQL.Sandbox mode | Shared mode | Manual mode allows async tests safely; shared mode disables concurrency — use shared only when process ancestry is complex |

**Installation:** All deps already declared as optional in mix.exs. No new entries needed.

---

## Package Legitimacy Audit

No new packages are introduced in Phase 2. All three Hex packages (`ecto`, `ecto_sql`, `postgrex`) were audited in Phase 1 and carry `OK` verdicts.

| Package | Registry | Verdict | Disposition |
|---------|----------|---------|-------------|
| ecto | Hex.pm | OK | Approved (Phase 1) |
| ecto_sql | Hex.pm | OK | Approved (Phase 1) |
| postgrex | Hex.pm | OK | Approved (Phase 1) |

**Packages removed due to SLOP verdict:** none
**Packages flagged as suspicious SUS:** none

---

## Architecture Patterns

### System Architecture Diagram

```
EventStore (InMemory or EventStoreDB)
    │
    │  subscribe_from_position(:all, last_position, self())  → {:ok, ref}
    │  push: stored_event_with_position() messages to GenServer mailbox
    ▼
Orkestra.Projector.GenServer (one per projector instance)
    │  state: %{repo, storage_adapter, projector_name, lifecycle_config,
    │            attempts, halted, subscription_ref}
    │
    ├── init/1
    │     1. Load Checkpoint from Repo (or default last_position = -1)
    │     2. If halted == true → enter halted idle state, skip subscribe
    │     3. Subscribe: EventStore.subscribe_from_position(:all, last_position, self())
    │     4. Return {:ok, state}
    │
    ├── handle_info(event, state)   [one per pushed event — SEQUENTIAL]
    │     if state.halted → Logger.warning, ignore event, {:noreply, state}
    │     else:
    │       1. storage_adapter.write(projector_name, event, position, opts) → {:ok, read_model_multi}
    │       2. build checkpoint_multi: Multi.insert(checkpoint_struct, on_conflict upsert)
    │       3. combined = Multi.append(read_model_multi, checkpoint_multi)
    │       4. repo.transaction(combined)
    │            → {:ok, _} → reset attempts, {:noreply, state}
    │            → {:error, step, reason, _} → handle_failure(event, reason, state)
    │
    ├── handle_failure(event, reason, state)
    │     new_attempts = state.attempts + 1
    │     case Lifecycle.classify(new_attempts, lifecycle_config)
    │       :retry →
    │         delay = Lifecycle.next_delay(new_attempts, lifecycle_config)
    │         Process.send_after(self(), {:retry_event, event}, delay)
    │         {:noreply, %{state | attempts: new_attempts}}
    │       :park →
    │         park_and_halt(event, reason, new_attempts, state)
    │
    ├── handle_info({:retry_event, event}, state)
    │     → same as handle_info(event, state) — re-attempts the same event
    │
    └── park_and_halt(event, reason, attempts, state)
          1. Build dead_letter_multi: Multi.insert(dead_letter_struct)
          2. Build halted_checkpoint_multi: Multi.insert(checkpoint_struct halted=true, on_conflict upsert)
          3. combined = Multi.append(dead_letter_multi, halted_checkpoint_multi)
          4. repo.transaction(combined)    ← atomic halt
          5. {:noreply, %{state | halted: true, attempts: 0}}
          (GenServer stays alive — no crash, no stop)

Orkestra.Projection.Storage.Postgres   [implements Storage behaviour]
    │  write/4 → {:ok, Ecto.Multi.t()}   (read-model writes as Multi fragment)
    │  reset/2 → :ok                     (delete_all from read-model table)

Per-Projection Ecto.Repo  (defined by consumer, passed to GenServer via opts)
    │  Configured with:
    │    adapter: Ecto.Adapters.Postgres
    │    migration_source: "<projector_name>_schema_migrations"
    │    priv: "priv/<projector_name>"    (optional, for file-based migrations)
    │    pool: Ecto.Adapters.SQL.Sandbox  (test env only)
    │
    └── Repo.transaction(combined_multi)
          ← executes in GenServer's calling process
          ← rolls back entirely on any step failure
```

### Recommended Project Structure

```
lib/orkestra/
├── projector/
│   ├── lifecycle.ex              # existing (Phase 1) — pure retry functions
│   └── gen_server.ex             # NEW: Orkestra.Projector.GenServer
├── projection/
│   ├── storage.ex                # existing (Phase 1) — behaviour
│   ├── storage/
│   │   └── postgres.ex           # NEW: Orkestra.Projection.Storage.Postgres
│   ├── checkpoint.ex             # existing (Phase 1) — Ecto schema
│   ├── dead_letter.ex            # existing (Phase 1) — Ecto schema
│   └── migration.ex              # existing (Phase 1) — up/0 and down/0

test/orkestra/
├── projector/
│   ├── lifecycle_test.exs        # existing — pure unit tests
│   └── gen_server_test.exs       # NEW: @tag :postgres — sandbox tests
├── projection/
│   ├── storage_test.exs          # existing — behaviour contract tests
│   ├── schemas_test.exs          # existing — schema field tests
│   └── storage/
│       └── postgres_test.exs     # NEW: @tag :postgres — real DB tests

test/support/
└── projection_test_repo.ex       # NEW: test-only Repo module for GenServer tests
```

### Pattern 1: Ecto.Multi Atomic Composition (STORE-03)

**What:** Build two `Ecto.Multi` structs independently and merge them with `Multi.append/2` before calling `Repo.transaction/1`.

**When to use:** Every event processing step — the Storage adapter produces the read-model Multi, the GenServer builds the checkpoint upsert Multi, then appends them before committing.

**Example:**
```elixir
# Source: Ecto.Multi documentation [CITED: ecto.hexdocs.pm/Ecto.Multi.html]

# Step 1: Storage adapter returns the read-model Multi
{:ok, read_model_multi} = storage_adapter.write(projector_name, event, position, [])

# Step 2: GenServer builds the checkpoint upsert Multi
checkpoint = %Orkestra.Projection.Checkpoint{
  projector_name: projector_name,
  last_position: event.global_position,
  halted: false,
  updated_at: DateTime.utc_now()
}

checkpoint_multi =
  Ecto.Multi.new()
  |> Ecto.Multi.insert(:checkpoint, checkpoint,
    on_conflict: [set: [last_position: event.global_position, halted: false, updated_at: DateTime.utc_now()]],
    conflict_target: :projector_name
  )

# Step 3: Append and commit atomically
combined = Ecto.Multi.append(read_model_multi, checkpoint_multi)

case repo.transaction(combined) do
  {:ok, _changes} -> {:noreply, %{state | attempts: 0}}
  {:error, step, reason, _changes} -> handle_failure(event, {step, reason}, state)
end
```

**Key properties:**
- `Multi.append/2` is deterministic — operations from the first Multi run before the second [CITED: ecto.hexdocs.pm/Ecto.Multi.html]
- Step names must be unique across both Multis — use namespaced atoms (`:checkpoint`, `:read_model_insert`, etc.)
- `Repo.transaction/1` is called in the GenServer process — that process must own the Sandbox connection in tests

### Pattern 2: Checkpoint Upsert with on_conflict

**What:** First event application inserts a checkpoint row; subsequent applications update it. A single `Multi.insert` with `on_conflict` handles both cases via the `projector_name` unique index.

**When to use:** Every event commit — both normal processing and halt transitions.

**Example:**
```elixir
# Source: Ecto.Repo documentation [CITED: ecto.hexdocs.pm/Ecto.Repo.html]

# on_conflict: [set: [...]] updates named columns on conflict
# conflict_target: :projector_name uses the projector_name column
# (matches the unique_index(:projection_checkpoints, [:projector_name]) from Phase 1 migration)

Ecto.Multi.insert(:checkpoint, checkpoint_struct,
  on_conflict: [
    set: [
      last_position: event.global_position,
      halted: false,
      updated_at: DateTime.utc_now()
    ]
  ],
  conflict_target: :projector_name
)

# For atomic halt (park_and_halt path):
Ecto.Multi.insert(:halted_checkpoint, checkpoint_struct,
  on_conflict: [
    set: [
      halted: true,
      halted_at: DateTime.utc_now(),
      updated_at: DateTime.utc_now()
    ]
  ],
  conflict_target: :projector_name
)
```

**Pitfall:** `conflict_target` accepts a column atom or list — NOT a constraint name string. Use `:projector_name` (atom), not `"projection_checkpoints_projector_name_index"`.

### Pattern 3: Per-Projection Isolated Ecto.Repo

**What:** Each projector uses a dedicated Repo module with its own connection pool, migration history table name, and optional priv directory.

**When to use:** Every projector definition (STORE-04, MIG-01).

**Example (consumer app):**
```elixir
# Source: Ecto.Repo documentation [CITED: ecto.hexdocs.pm/Ecto.Repo.html]
# Source: ecto_sql migration_source option [CITED: ecto-sql.hexdocs.pm/Ecto.Migration.html]

defmodule MyApp.OrderProjection.Repo do
  use Ecto.Repo,
    otp_app: :my_app,
    adapter: Ecto.Adapters.Postgres
end

# In config/config.exs:
config :my_app, MyApp.OrderProjection.Repo,
  database: "my_app_repo",
  migration_source: "order_projection_schema_migrations",
  priv: "priv/order_projection"  # optional — only needed for file-based migrations

# The GenServer receives the Repo via opts at start:
GenServer.start_link(Orkestra.Projector.GenServer, %{
  repo: MyApp.OrderProjection.Repo,
  projector_name: "MyApp.OrderProjection",
  storage_adapter: MyApp.OrderProjection.Storage,
  lifecycle_config: %{max_retries: 5, backoff_base_ms: 500, backoff_cap_ms: 30_000}
})
```

**`migration_source` isolation:** Each per-projection Repo uses a unique table name for its migration history. This means `mix ecto.migrate` for one projection's Repo does not touch another projection's migration table — independent rollback is possible. [CITED: ecto-sql.hexdocs.pm/Ecto.Migration.html]

**Programmatic migrations (MIG-01 — no priv files needed):** `Ecto.Migrator.run/4` accepts `[{version, Module}]` tuples as the second argument, allowing in-code migration modules without files. This is the preferred pattern for Phase 2 since the Orkestra library ships `Migration.up/0` / `Migration.down/0` (Phase 1 pattern). [CITED: ecto-sql.hexdocs.pm/Ecto.Migrator.html]

### Pattern 4: GenServer Sequential Event Processing

**What:** `handle_info/2` receives pushed event messages from `subscribe_from_position`. OTP mailbox guarantees sequential delivery — no concurrent application to the same state.

**When to use:** Core GenServer design for all event processing.

**Example:**
```elixir
# Source: Elixir GenServer documentation — handle_info is for non-cast/call messages [ASSUMED — well-established OTP pattern]

defmodule Orkestra.Projector.GenServer do
  use GenServer
  alias Orkestra.Projector.Lifecycle
  alias Orkestra.Projection.{Checkpoint, DeadLetter}

  @impl true
  def init(config) do
    repo = config.repo
    projector_name = config.projector_name

    # Load checkpoint; default to last_position = -1 (replay all)
    last_position =
      case repo.get_by(Checkpoint, projector_name: projector_name) do
        nil -> -1
        %Checkpoint{halted: true} ->
          # Start halted — do not subscribe
          # halted state is surfaced to the caller via state.halted
          send(self(), :init_halted)
          -1
        %Checkpoint{last_position: pos} -> pos
      end

    # Subscribe from last_position (exclusive > semantics from D-01)
    {:ok, ref} = config.event_store.subscribe_from_position(:all, last_position, self())

    {:ok, %{
      repo: repo,
      projector_name: projector_name,
      storage_adapter: config.storage_adapter,
      lifecycle_config: config.lifecycle_config,
      event_store: config.event_store,
      subscription_ref: ref,
      attempts: 0,
      halted: false
    }}
  end

  @impl true
  def handle_info(%{global_position: _} = event, %{halted: true} = state) do
    # Halted — silently discard (do not advance position)
    Logger.warning("Projector is halted, ignoring event",
      projector: state.projector_name,
      position: event.global_position,
      orkestra: :projector
    )
    {:noreply, state}
  end

  @impl true
  def handle_info(%{global_position: _} = event, state) do
    apply_event(event, state)
  end

  @impl true
  def handle_info({:retry_event, event}, state) do
    apply_event(event, state)
  end
end
```

**Key property:** The GenServer mailbox serializes ALL `handle_info` calls — no two events are ever applied simultaneously to the same projector, regardless of how fast the EventStore pushes them. [ASSUMED — OTP process model guarantee, well-established]

### Pattern 5: SQL.Sandbox Cross-Process Testing

**What:** Test a GenServer that calls `Repo` functions by checking out a sandbox connection in the test process and allowing the GenServer process to share it.

**When to use:** All Postgres-tagged GenServer tests.

**Example:**
```elixir
# Source: Ecto.Adapters.SQL.Sandbox documentation [CITED: ecto-sql.hexdocs.pm/Ecto.Adapters.SQL.Sandbox.html]

# In test/support/projection_test_repo.ex:
defmodule Test.ProjectionRepo do
  use Ecto.Repo, otp_app: :orkestra, adapter: Ecto.Adapters.Postgres
end

# In test/test_helper.exs (add for Postgres tests):
# Application.put_env(:orkestra, Test.ProjectionRepo, ...)
# Ecto.Adapters.SQL.Sandbox.mode(Test.ProjectionRepo, :manual)

# In the test:
setup do
  :ok = Ecto.Adapters.SQL.Sandbox.checkout(Test.ProjectionRepo)
  :ok
end

@tag :postgres
test "atomic commit: checkpoint and read model write together" do
  {:ok, pid} = start_supervised({Orkestra.Projector.GenServer, config_with_test_repo()})

  # Allow the GenServer process to use the test's sandbox connection
  Ecto.Adapters.SQL.Sandbox.allow(Test.ProjectionRepo, self(), pid)

  # Now the GenServer can call Test.ProjectionRepo.transaction/1
  # ...
end
```

**Critical order:** `start_supervised/1` first (to get the pid), THEN `Sandbox.allow/3`. If `allow` is called before the process starts, the pid is not yet known. The GenServer's `init` must NOT make any Repo calls before returning — subscribe to the EventStore in `init`, but defer the first Repo checkpoint load or use a `handle_continue` so the allow call can happen first. [CITED: ecto-sql.hexdocs.pm/Ecto.Adapters.SQL.Sandbox.html]

**Alternative:** Use `{:shared, self()}` mode in setup to avoid per-process allow calls, at the cost of disabling test concurrency for that describe block.

### Anti-Patterns to Avoid

- **Calling `Repo.get_by` in `init` before `Sandbox.allow`:** Causes `DBConnection.OwnershipError` in tests. Load the checkpoint in a `handle_continue` callback (or a `send(self(), :load_checkpoint)` in init) so the test has time to call `Sandbox.allow` after getting the pid.
- **Using atom step names that clash across Multi fragments:** If `read_model_multi` uses `:insert` and `checkpoint_multi` also uses `:insert`, `Multi.append` raises `ArgumentError: duplicate multi key`. Namespace step names (e.g. `:read_model_insert`, `:checkpoint_upsert`).
- **Blocking the GenServer with `Process.sleep` during retry delay:** Use `Process.send_after(self(), {:retry_event, event}, delay)` instead. `sleep` blocks the entire process, preventing it from processing shutdown messages or other admin signals.
- **Crashing the GenServer on halt:** `park_and_halt` must return `{:noreply, state}` not `{:stop, :normal, state}`. A halted projector that crashes triggers supervisor restarts, re-reads the checkpoint as `halted=true`, and then... starts halted again — wasted restarts. Stay alive.
- **Building the checkpoint Multi inside the Storage adapter:** The Storage adapter owns only the read-model Multi fragment (D-06). The checkpoint upsert is the GenServer's responsibility. Mixing them couples the adapter to the checkpoint schema.
- **Using `conflict_target: "projection_checkpoints_projector_name_index"` (string constraint name):** Ecto's `conflict_target` for Postgres expects a column name atom or list, not a constraint name string. Use `conflict_target: :projector_name`.

---

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| Atomic multi-table write | Custom two-phase commit | `Ecto.Multi` + `Repo.transaction/1` | ACID transaction is the correct primitive; Multi is a pure composable data structure |
| Upsert (insert-or-update) checkpoint | SELECT then INSERT or UPDATE | `Repo.insert` with `on_conflict: [set: ...], conflict_target:` | PostgreSQL's native ON CONFLICT DO UPDATE; single round-trip, no TOCTOU race |
| Sequential event queue | `GenStage`, `Broadway`, custom queue | OTP GenServer mailbox | Mailbox is FIFO and single-consumer by design; no additional library needed for v1 |
| Retry delay without blocking | `:timer.sleep` in handle_info | `Process.send_after(self(), message, delay)` | `send_after` is non-blocking; the GenServer processes other messages during the delay |
| Connection sharing in tests | Custom mock Repo | `Ecto.Adapters.SQL.Sandbox.allow/3` | Official Ecto test infrastructure; handles connection pooling, transaction isolation, and cleanup |

---

## Runtime State Inventory

> Step 2.5 evaluation: Phase 2 is NOT a rename/refactor/migration phase. It is a greenfield feature addition (new modules, no renames). This section is SKIPPED.

---

## Common Pitfalls

### Pitfall 1: DBConnection.OwnershipError in GenServer Repo Calls

**What goes wrong:** GenServer calls `Repo.get_by/3` or `Repo.transaction/1` during `init/1`; the test gets an `DBConnection.OwnershipError: cannot find ownership process`.

**Why it happens:** The test process checks out the sandbox connection, then `start_supervised` starts the GenServer. But if `init/1` immediately calls the Repo, `Sandbox.allow` has not been called yet — the GenServer process is not the owner of the sandbox connection and has not been granted access.

**How to avoid:** Defer all Repo calls out of `init/1`. Use `{:ok, state, {:continue, :load_checkpoint}}` + `handle_continue/2`, or `send(self(), :init)` inside `init/1`. The test calls `Sandbox.allow(Repo, self(), pid)` after `start_supervised!/1` returns, before the `:init` or `:continue` message is processed. [CITED: ecto-sql.hexdocs.pm/Ecto.Adapters.SQL.Sandbox.html]

**Warning signs:** Tests that succeed when run alone but fail when run with `mix test` (timing-dependent Repo access before allow).

### Pitfall 2: Duplicate Step Names in Multi.append

**What goes wrong:** `Ecto.Multi.append(read_model_multi, checkpoint_multi)` raises `ArgumentError: cannot merge multis with overlapping names`.

**Why it happens:** If the Storage adapter uses `:insert` as its step name and the GenServer's checkpoint Multi also uses `:insert`, they clash.

**How to avoid:** Establish a naming convention: Storage adapter uses `:read_model_<op>` prefixes (e.g. `:read_model_insert`, `:read_model_update`); GenServer's checkpoint step uses `:checkpoint`. Document the convention in both modules' `@doc`. [CITED: ecto.hexdocs.pm/Ecto.Multi.html]

**Warning signs:** `ArgumentError` in `Multi.append/2` or `Repo.transaction/1`.

### Pitfall 3: Checkpoint Multi executed AFTER read-model Multi (wrong order)

**What goes wrong:** Checkpoint is updated before the read-model write commits. On a crash mid-transaction the checkpoint is ahead of the actual read-model state, causing a skip on restart.

**Why it happens:** `Multi.append(checkpoint_multi, read_model_multi)` — wrong argument order. The first argument runs first.

**How to avoid:** Always `Multi.append(read_model_multi, checkpoint_multi)` — read-model operations first, checkpoint upsert second. Both are in the same transaction so the order within the transaction does not affect atomicity, but the logical ordering is clearer: "apply the event, then advance the checkpoint." [CITED: ecto.hexdocs.pm/Ecto.Multi.html]

**Warning signs:** In tests, a forced checkpoint-ahead condition causes an event to be skipped on restart rather than replayed.

### Pitfall 4: Halted State Ignored After Restart

**What goes wrong:** GenServer restarts (crash or supervisor restart), loads the checkpoint (which has `halted=true`), but subscribes to the EventStore anyway and starts processing events — effectively un-halting itself without operator action.

**Why it happens:** `init/1` checks the checkpoint position but not the halted flag before calling `subscribe_from_position`.

**How to avoid:** In `init/1` (or `handle_continue/2`), check `checkpoint.halted`. If `true`, skip the `subscribe_from_position` call and set `state.halted = true`. The GenServer starts but discards all incoming events until an external signal resets the halt (Phase 3+). Log a warning with `orkestra: :projector` metadata. [CITED: Phase 1 Checkpoint schema — halted field present]

**Warning signs:** A projector that was halted processes events after a restart without any operator action.

### Pitfall 5: on_conflict with `conflict_target` expects column atoms, not constraint name

**What goes wrong:** `conflict_target: "projection_checkpoints_projector_name_index"` does not work as expected — Postgrex may ignore the conflict target and fall back to raising on conflict.

**Why it happens:** Ecto's `conflict_target` for `insert/2` accepts a list of column atoms or `{:unsafe_fragment, "expr"}`. A string constraint name is not valid syntax for the column-based form.

**How to avoid:** Use `conflict_target: :projector_name` (atom for a single-column unique index) or `conflict_target: [:projector_name]` (list form). The unique index on `projector_name` in Phase 1's migration maps directly to this. [CITED: ecto.hexdocs.pm/Ecto.Repo.html]

**Warning signs:** Upsert inserts duplicate rows instead of updating, or raises `UniqueConstraintError`.

### Pitfall 6: Sandbox `allow` called before GenServer process starts

**What goes wrong:** `Sandbox.allow(Repo, self(), future_pid)` is called before the GenServer is started — `future_pid` is nil or stale.

**Why it happens:** Test code tries to pre-allow a pid before `start_supervised!/1` is called.

**How to avoid:** Always `start_supervised!/1` first to get the pid, then `Sandbox.allow`. Order matters. [CITED: ecto-sql.hexdocs.pm/Ecto.Adapters.SQL.Sandbox.html]

---

## Code Examples

### Complete GenServer State Shape

```elixir
# Source: design based on locked decisions in CONTEXT.md [ASSUMED — module name is Claude's discretion]
@type state :: %{
  # Required at start — passed via opts
  repo: module(),                          # per-projection Ecto.Repo
  projector_name: String.t(),              # unique projector identifier
  storage_adapter: module(),               # implements Storage behaviour
  event_store: module(),                   # implements EventStore behaviour
  lifecycle_config: Lifecycle.config(),    # max_retries, backoff params

  # Runtime state
  subscription_ref: reference() | nil,    # from subscribe_from_position
  attempts: non_neg_integer(),            # current retry count for failing event
  halted: boolean()                       # true after park_and_halt
}
```

### Atomic Halt Transaction

```elixir
# Source: design from CONTEXT.md locked decisions + Ecto.Multi docs [ASSUMED pattern — uses verified Ecto API]
defp park_and_halt(event, reason, attempts, state) do
  now = DateTime.utc_now()

  dead_letter = %Orkestra.Projection.DeadLetter{
    id: Ecto.UUID.generate(),
    projector_name: state.projector_name,
    position: event.global_position,
    event_data: event,
    error: inspect(reason),
    attempts: attempts,
    occurred_at: now
  }

  halted_checkpoint = %Orkestra.Projection.Checkpoint{
    id: Ecto.UUID.generate(),
    projector_name: state.projector_name,
    last_position: event.global_position - 1,  # do not advance past failing event
    halted: true,
    halted_at: now
  }

  halt_multi =
    Ecto.Multi.new()
    |> Ecto.Multi.insert(:dead_letter, dead_letter)
    |> Ecto.Multi.insert(:halted_checkpoint, halted_checkpoint,
      on_conflict: [set: [halted: true, halted_at: now, updated_at: now]],
      conflict_target: :projector_name
    )

  case state.repo.transaction(halt_multi) do
    {:ok, _} ->
      Logger.error("Projector halted after exhausting retries",
        projector: state.projector_name,
        position: event.global_position,
        attempts: attempts,
        orkestra: :projector
      )
      {:noreply, %{state | halted: true, attempts: 0}}

    {:error, step, db_reason, _} ->
      Logger.error("Failed to persist halt — projector still alive but state uncertain",
        projector: state.projector_name,
        step: step,
        reason: inspect(db_reason),
        orkestra: :projector
      )
      # Return halted anyway — a DB failure persisting the halt is a severe issue
      {:noreply, %{state | halted: true, attempts: 0}}
  end
end
```

### Postgres Storage Adapter Skeleton

```elixir
# Source: design based on Storage behaviour contract (Phase 1) + Ecto.Multi API [ASSUMED — module name is Claude's discretion]
if Code.ensure_loaded?(Ecto.Multi) do
  defmodule Orkestra.Projection.Storage.Postgres do
    @moduledoc """
    PostgreSQL storage adapter implementing `Orkestra.Projection.Storage`.

    Returns `Ecto.Multi.t()` from `write/4` — a pure data structure the
    Projector GenServer appends to the checkpoint upsert Multi before calling
    `Repo.transaction/1`. The Repo is NOT referenced here; it is injected by
    the GenServer at transaction time (STORE-03).
    """

    @behaviour Orkestra.Projection.Storage

    @impl true
    @spec write(String.t(), map(), non_neg_integer(), keyword()) ::
            {:ok, Ecto.Multi.t()} | {:error, term()}
    def write(projector_name, event, position, opts) do
      # The consuming application injects its read-model write operations.
      # Phase 2 ships this as a skeletal default; the per-projector implementation
      # is wired in by the Phase 3 DSL.
      handler = Keyword.fetch!(opts, :handler)

      case handler.(projector_name, event, position) do
        {:ok, multi} when is_struct(multi, Ecto.Multi) -> {:ok, multi}
        {:error, reason} -> {:error, reason}
      end
    end

    @impl true
    @spec reset(String.t(), keyword()) :: :ok | {:error, term()}
    def reset(projector_name, opts) do
      repo = Keyword.fetch!(opts, :repo)
      schema = Keyword.fetch!(opts, :schema)

      case repo.delete_all(from(s in schema, where: s.projector_name == ^projector_name)) do
        {_, nil} -> :ok
        {:error, reason} -> {:error, reason}
      end
    end
  end
end
```

### SQL.Sandbox Test Setup (Postgres-tagged tests)

```elixir
# Source: Ecto.Adapters.SQL.Sandbox docs [CITED: ecto-sql.hexdocs.pm/Ecto.Adapters.SQL.Sandbox.html]

defmodule Orkestra.Projector.GenServerTest do
  use ExUnit.Case, async: false  # async: false because Sandbox.checkout is not concurrency-safe without shared mode

  @moduletag :postgres

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Test.ProjectionRepo)
    :ok
  end

  test "resumes from persisted checkpoint position after restart" do
    # 1. Start GenServer (no Repo calls until handle_continue)
    pid = start_supervised!({Orkestra.Projector.GenServer, test_config()})

    # 2. Allow GenServer process to use the sandbox connection
    Ecto.Adapters.SQL.Sandbox.allow(Test.ProjectionRepo, self(), pid)

    # 3. Now safe to trigger Repo calls inside the GenServer
    # ...
  end
end
```

---

## State of the Art

| Old Approach | Current Approach | When Changed | Impact |
|--------------|------------------|--------------|--------|
| Two separate Repo calls (insert checkpoint, insert read-model) | Single `Ecto.Multi` combining both | Ecto 1.x+ | Atomic commit — no partial writes on crash |
| Shared global migration table `schema_migrations` for all projections | Per-projection `migration_source` config for isolated migration history | Ecto 2.x+ | Independent migrate/rollback/drop per projection |
| `Repo.insert_or_update/2` with explicit SELECT-then-INSERT | `Repo.insert/2` with `on_conflict: [set: ...], conflict_target:` | Ecto 2.x+ | Single round-trip upsert, no race condition |
| GenStage/Broadway for sequential processing | Plain GenServer mailbox | OTP design | No extra library for v1; mailbox is inherently sequential |

**Deprecated/outdated:**
- `Ecto.Multi.merge/2` with a static second Multi: use `Multi.append/2` instead; `merge/2` is for dynamic Multis that need values from the first Multi's results.
- Testing Repo-calling processes with mocks instead of SQL.Sandbox: SQL.Sandbox provides real transactional isolation with automatic rollback — preferred for correctness tests.

---

## Assumptions Log

| # | Claim | Section | Risk if Wrong |
|---|-------|---------|---------------|
| A1 | GenServer `init/1` using `handle_continue` defers Repo calls safely so `Sandbox.allow` can be called after `start_supervised!` | Pattern 5, Pitfall 1 | If the GenServer processes the `:continue` message before `allow` is called (race between process scheduling and test setup), the pattern fails — use `handle_continue` which is reliably deferred until after `init` returns |
| A2 | `conflict_target: :projector_name` (single column atom) correctly identifies the unique index added by Phase 1 migration | Pattern 2, Pitfall 5 | If Postgres requires the full column list `[:projector_name]` not a bare atom, the upsert silently falls back to `:raise` — verify against a real DB in a Wave 0 test |
| A3 | `Multi.append(read_model_multi, checkpoint_multi)` produces step names in the correct order and the failure return includes the failing step name for diagnostics | Pattern 1, Pitfall 2 | If Multi.append mangles step ordering or names, the combined transaction behavior is unpredictable |
| A4 | A GenServer in `:halted` state that discards incoming event messages does not accumulate unbounded mailbox growth | Pattern 4, Common Pitfalls | If the EventStore pushes events faster than the GenServer discards them, the process mailbox grows unboundedly — mitigated by logging and by the fact that InMemory is single-process; monitor mailbox size in production |
| A5 | `Ecto.Migrator.run(repo, [{version, Module}], :up, all: true)` is the correct signature for running programmatic (non-file) migrations against a per-projection Repo | Pattern 3 (MIG-01) | If the tuple-list form requires different opts or a different function, MIG-01's isolated migration history cannot be run programmatically — verify against ecto_sql 3.12 source |

---

## Open Questions

1. **Sandbox checkout failure for per-projection Repo in CI**
   - What we know: `Sandbox.checkout/2` requires the Repo to be started and connected. In CI without Postgres, the Repo start fails — which is why tests are tagged `@tag :postgres` and skipped via `ExUnit.configure(exclude: [:postgres])`.
   - What's unclear: Whether the test-only Repo (`Test.ProjectionRepo`) needs to be started in `test_helper.exs` or per-test via `start_supervised`.
   - Recommendation: Start `Test.ProjectionRepo` in `test_helper.exs` under a conditional (`if postgres_available?`); use `ExUnit.configure(exclude: [:postgres])` by default; CI with Postgres sets `POSTGRES_URL` and includes the tag.

2. **GenServer init Repo access timing vs. Sandbox.allow**
   - What we know: `handle_continue/2` is the standard OTP mechanism to defer work from `init/1`; it runs as the first callback after `init/1` returns.
   - What's unclear: Whether `handle_continue` runs before or after the test process can call `Sandbox.allow` (it depends on process scheduling).
   - Recommendation: Use `send(self(), :init)` in `init/1` instead of `handle_continue` — `send` enqueues a message in the mailbox; the test can call `Sandbox.allow` between `start_supervised!` returning and the GenServer processing the `:init` message, because the test process runs first when the GenServer hasn't been scheduled yet. Document this ordering assumption.

3. **Storage.Postgres write/4 contract for Phase 2 (without Phase 3 DSL)**
   - What we know: Phase 2 ships the Postgres adapter; Phase 3 ships the `use Orkestra.Projector` DSL. Without the DSL, `write/4` has no way to know which user-defined function to call.
   - What's unclear: What `write/4` does in Phase 2 — a no-op Multi? A callback opts key?
   - Recommendation: Accept an `:event_handler` function in `opts` (a 3-arity function taking `(projector_name, event, position) -> {:ok, Ecto.Multi.t()} | {:error, term()}`). Tests pass the handler directly; Phase 3 DSL wires it automatically. Document as a known evolution point.

---

## Environment Availability

| Dependency | Required By | Available | Version | Fallback |
|------------|------------|-----------|---------|----------|
| Elixir | All | ✓ | 1.18.4 | — |
| Erlang/OTP | All | ✓ | OTP 27 | — |
| ecto/ecto_sql/postgrex | Postgres adapter, SQL.Sandbox tests | ✓ (in mix.lock) | ecto 3.12+, ecto_sql 3.12+, postgrex 0.18+ | Optional dep guard; compile without them |
| PostgreSQL | Postgres-tagged tests | ✗ (unknown — not checked) | — | Skip `:postgres` tagged tests; InMemory covers pure GenServer unit tests |
| EventStoreDB | EventStoreDB adapter integration | ✗ | — | InMemory adapter used for all Phase 2 tests |

**Missing dependencies with no fallback:** None for the Phase 2 unit/integration tests. The Postgres adapter tests require a running Postgres instance but are tagged and skippable.

**Missing dependencies with fallback:** PostgreSQL — use `@tag :postgres` exclusion; all correctness tests can use InMemory EventStore + test Repo pointing at Postgres (if available) or be skipped.

---

## Validation Architecture

### Test Framework

| Property | Value |
|----------|-------|
| Framework | ExUnit (built-in, Elixir 1.18) |
| Config file | `test/test_helper.exs` (exists) |
| Quick run command | `mix test --exclude postgres` |
| Full suite command | `mix test` (requires Postgres) |

### Phase Requirements → Test Map

| Req ID | Behavior | Test Type | Automated Command | File Exists? |
|--------|----------|-----------|-------------------|-------------|
| PROJ-03 | GenServer resumes from persisted checkpoint position after restart | integration (@tag :postgres) | `mix test test/orkestra/projector/gen_server_test.exs --include postgres` | ❌ Wave 0 |
| PROJ-04 | Events applied strictly in order — no concurrent application | unit (InMemory) | `mix test test/orkestra/projector/gen_server_test.exs` | ❌ Wave 0 |
| STORE-02 | Postgres adapter write/4 persists read-model updates via Multi | integration (@tag :postgres) | `mix test test/orkestra/projection/storage/postgres_test.exs --include postgres` | ❌ Wave 0 |
| STORE-03 | Checkpoint + read-model write commit atomically | integration (@tag :postgres) | `mix test test/orkestra/projector/gen_server_test.exs --include postgres` | ❌ Wave 0 |
| STORE-04 | Per-projection Repo isolation — connection pool, migration_source | integration (@tag :postgres) | `mix test test/orkestra/projection/storage/postgres_test.exs --include postgres` | ❌ Wave 0 |
| MIG-01 | Isolated migration history — migration_source per projection | integration (@tag :postgres) | `mix test test/orkestra/projection/storage/postgres_test.exs --include postgres` | ❌ Wave 0 |
| ERR-04 | Halted status persisted to checkpoint; projector stays alive | integration (@tag :postgres) | `mix test test/orkestra/projector/gen_server_test.exs --include postgres` | ❌ Wave 0 |
| READ-01 | Developer can query read model via Repo directly | integration (@tag :postgres) | `mix test test/orkestra/projector/gen_server_test.exs --include postgres` | ❌ Wave 0 |

### Sampling Rate

- **Per task commit:** `mix test --exclude postgres` (fast — no Postgres required)
- **Per wave merge:** `mix test` (full suite including Postgres-tagged tests)
- **Phase gate:** `mix test && mix compile --no-optional-deps --warnings-as-errors`

### Wave 0 Gaps

- [ ] `test/support/projection_test_repo.ex` — test-only Ecto.Repo for GenServer tests
- [ ] `test/orkestra/projector/gen_server_test.exs` — covers PROJ-03, PROJ-04, STORE-03, ERR-04, READ-01
- [ ] `test/orkestra/projection/storage/postgres_test.exs` — covers STORE-02, STORE-04, MIG-01
- [ ] `test/test_helper.exs` update — add conditional Repo start + Sandbox.mode for Postgres tests
- [ ] `config/test.exs` — add `pool: Ecto.Adapters.SQL.Sandbox` for `Test.ProjectionRepo`

*(Existing tests: lifecycle_test.exs, schemas_test.exs, storage_test.exs, in_memory_subscription_test.exs — all remain valid; none are invalidated by Phase 2)*

---

## Security Domain

> security_enforcement: true; security_asvs_level: 1

### Applicable ASVS Categories

| ASVS Category | Applies | Standard Control |
|---------------|---------|-----------------|
| V2 Authentication | no | GenServer is an internal OTP process; no auth surface |
| V3 Session Management | no | No sessions |
| V4 Access Control | no | No access control surface in GenServer internals |
| V5 Input Validation | yes (low surface) | event_data stored as `:map` (JSON-safe); no unsafe atom deserialization (T-01-05 from Phase 1); Checkpoint/DeadLetter changesets validate types |
| V6 Cryptography | no | No cryptographic operations |

### Known Threat Patterns for Elixir CQRS Library

| Pattern | STRIDE | Standard Mitigation |
|---------|--------|---------------------|
| Unsafe term deserialization in event_data | Tampering | Store event_data as `:map` (jsonb) via Jason — already established in Phase 1; do not use `:erlang.binary_to_term` in GenServer event handling |
| Unbounded retry causing OOM or CPU spike | Denial of Service | Enforced cap in `Lifecycle.next_delay/2` (backoff_cap_ms); `should_halt?/2` terminates retries at max_retries; GenServer never enters a tight loop |
| Mailbox flooding from high-throughput EventStore | Denial of Service | GenServer mailbox is bounded by BEAM process memory; monitor mailbox length in production (Phase 4 telemetry); halted state discards events but still accumulates in mailbox — document as operational concern |
| Stale subscription ref after GenServer restart | Information Disclosure | `unsubscribe(ref)` in `terminate/2` cleanly removes the subscription; re-subscribes with fresh ref in new `init/1` |

---

## Project Constraints (from CLAUDE.md)

- **Language:** Elixir 1.18+ / Erlang OTP 27+
- **Formatting:** `mix format` required; `.formatter.exs` covers `lib/`, `test/`, `config/`
- **Docs:** `@moduledoc` and `@doc` required on every public module and function; `@spec` required on all public functions
- **Error style:** Return tuples `{:ok, value} | {:error, reason}`; structured atom reasons; no string-message errors
- **Logging:** `Logger.{debug,info,warning,error}` with structured metadata; `orkestra: :projector` tag for new GenServer module
- **Optional deps:** ecto/ecto_sql/postgrex already declared `optional: true` in mix.exs; Postgres adapter must be guarded with `if Code.ensure_loaded?(Ecto.Multi) do defmodule ... end`
- **Behaviour pattern:** `@behaviour Orkestra.Projection.Storage` + `@impl true` on each callback in the Postgres adapter
- **Config key bug:** Do NOT fix the `:ultimus` → `:orkestra` config key (CFG-01 is Phase 3); GenServer receives Repo + EventStore module directly via opts rather than reading from application config
- **Do not replace:** Existing EventStore behaviour, InMemory adapter, Lifecycle, Checkpoint/DeadLetter schemas, Migration, Storage behaviour — all extend only

---

## Sources

### Primary (MEDIUM confidence — official hexdocs verified via WebFetch)
- [Ecto.Multi documentation](https://ecto.hexdocs.pm/Ecto.Multi.html) — append/2, merge/2, run/3, put/3, step naming, Repo.transaction semantics
- [Ecto.Repo insert/2 documentation](https://ecto.hexdocs.pm/Ecto.Repo.html) — on_conflict options, conflict_target, {:replace, fields}, [set: [...]] upsert pattern
- [Ecto.Adapters.SQL.Sandbox documentation](https://ecto-sql.hexdocs.pm/Ecto.Adapters.SQL.Sandbox.html) — manual mode, checkout/2, allow/3, start_supervised pattern, shared vs manual mode
- [Ecto.Migration documentation](https://ecto-sql.hexdocs.pm/Ecto.Migration.html) — migration_source option, priv option, migration_repo option
- [Ecto.Migrator documentation](https://ecto-sql.hexdocs.pm/Ecto.Migrator.html) — run/4 signature, [{version, Module}] tuple format, migrations_path/2

### Secondary (MEDIUM confidence — Phase 1 research, verified against hexdocs)
- Phase 1 RESEARCH.md — subscribe_from_position contract, exclusive position semantics, Checkpoint/DeadLetter schema fields, optional dep guard pattern

### Codebase (HIGH confidence — direct read)
- `lib/orkestra/projector/lifecycle.ex` — next_delay/2, classify/2, should_halt?/2 exact signatures and @max_shift constant
- `lib/orkestra/projection/storage.ex` — write/4 and reset/2 callback signatures; ops type definition
- `lib/orkestra/projection/checkpoint.ex` — schema fields: projector_name, last_position, halted, halted_at, updated_at
- `lib/orkestra/projection/dead_letter.ex` — schema fields: projector_name, position, event_data, error, attempts, occurred_at
- `lib/orkestra/projection/migration.ex` — unique_index(:projection_checkpoints, [:projector_name]) confirmed
- `lib/orkestra/event_store/in_memory.ex` — subscribe_from_position/3 returns {:ok, ref}; push delivery pattern; filter_for_stream logic
- `lib/orkestra/event_store.ex` — subscribe_from_position/3 callback signature; stored_event_with_position type
- `mix.exs` — ecto/ecto_sql/postgrex already declared optional: true

---

## Metadata

**Confidence breakdown:**
- Standard stack: HIGH — all three packages already in mix.lock; no new deps
- Architecture (GenServer + Multi patterns): MEDIUM — Ecto.Multi/Repo API confirmed via official hexdocs; GenServer pattern is well-established OTP; SQL.Sandbox cross-process pattern confirmed via official hexdocs
- Pitfalls: MEDIUM — Sandbox ownership error pattern confirmed via docs; Multi step name clash is a documented Multi property; others are ASSUMED from OTP/Ecto design
- Per-projection Repo isolation: MEDIUM — migration_source option confirmed via ecto_sql docs; priv option confirmed; Ecto.Migrator tuple format confirmed

**Research date:** 2026-06-24
**Valid until:** 2026-07-24 (stable Ecto 3.x / OTP APIs; 30-day window)
