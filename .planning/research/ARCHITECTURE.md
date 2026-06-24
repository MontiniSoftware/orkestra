# Architecture Research

**Domain:** Event-sourced projection / read-model subsystem for Orkestra (Elixir CQRS/ES library)
**Researched:** 2026-06-24
**Confidence:** MEDIUM — core lifecycle and Ecto isolation patterns verified against hexdocs; some design choices are reasoned from existing Orkestra conventions and the Commanded reference implementation.

## Standard Architecture

### System Overview

The projection subsystem sits entirely on the read (query) side of Orkestra's existing CQRS split. It adds no write-path coupling. The existing write path — Command → Aggregate.Root → EventStore + MessageBus — is unchanged.

```
┌────────────────────────────── WRITE SIDE (existing, unchanged) ───────────────────────────┐
│  Command → CommandHandler → Aggregate.Root → EventStore.append → MessageBus.publish        │
└───────────────────────────────────────────────────────────────────────────────────────────┘
                                                         │
                             ┌───────────────────────────▼───────────────────────────────────┐
                             │               PROJECTION SUBSYSTEM (new)                       │
                             │                                                                │
                             │  ┌─────────────────────────────────────────────────────────┐  │
                             │  │           Orkestra.Projection.Supervisor                 │  │
                             │  │  (one_for_one; sits alongside existing app supervisor)   │  │
                             │  │                                                          │  │
                             │  │  ┌───────────────────┐   ┌───────────────────┐           │  │
                             │  │  │  ProjectorA        │   │  ProjectorB        │  ...     │  │
                             │  │  │  (GenServer)        │   │  (GenServer)        │          │  │
                             │  │  └────────┬──────────┘   └────────┬──────────┘           │  │
                             │  └──────────┼───────────────────────┼─────────────────────┘  │
                             │             │                         │                        │
                             │  ┌──────────▼─────────────────────────▼───────────────────┐  │
                             │  │            Orkestra.Projection.Lifecycle (shared)        │  │
                             │  │  subscribe → catch-up → live → checkpoint →              │  │
                             │  │  retry → park-to-dead-letter → halt                      │  │
                             │  └──────────┬──────────────────────────────────────────────┘  │
                             │             │                                                  │
                             │  ┌──────────▼──────────────────────────────────────────────┐  │
                             │  │         Orkestra.Projection.Storage (behaviour)           │  │
                             │  │                                                           │  │
                             │  │  ┌─────────────────────┐   ┌──────────────────────────┐ │  │
                             │  │  │  Storage.Ecto        │   │  Storage.Mongo (future)  │ │  │
                             │  │  │  (Postgres adapter)  │   │  Storage.ES (future)     │ │  │
                             │  │  └──────────┬───────────┘   └──────────────────────────┘ │  │
                             │  └─────────────┼─────────────────────────────────────────── ┘  │
                             │                │                                                │
                             │  ┌─────────────▼───────────────────────────────────────────┐  │
                             │  │         Per-Projection Ecto.Repo + Isolated Migrations   │  │
                             │  │  projection_checkpoints (shared orkestra table)          │  │
                             │  │  projection_dead_letters (shared orkestra table)         │  │
                             │  │  read_model_* (per-projection, owned by projection)      │  │
                             │  └────────────────────────────────────────────────────────┘   │
                             └───────────────────────────────────────────────────────────────┘
                                          ▲                    ▲
                              reads from  │                    │ live events from
                          ┌───────────────┘                    └──────────────────┐
                          │                                                       │
               ┌──────────┴─────────┐                             ┌──────────────┴──────┐
               │  EventStore        │                             │  MessageBus          │
               │  (catch-up replay) │                             │  (NOT used for       │
               └────────────────────┘                             │   projector intake)  │
                                                                  └──────────────────────┘
```

**Key architectural choice:** Projectors read events directly from the EventStore (not via MessageBus) using a persistent catch-up subscription. The MessageBus alone cannot deliver ordered catch-up; it only delivers new events to live subscribers. The EventStore subscription delivers historical events in order from the checkpoint, then automatically transitions to live delivery once caught up. This is the same pattern used by Commanded and the Elixir EventStore library.

### Component Responsibilities

| Component | Responsibility | Module |
|-----------|----------------|--------|
| `Orkestra.Projector` | Behaviour + DSL macro (`project/2`) for defining which events update which read models | `lib/orkestra/projector.ex` |
| `Orkestra.Projector.Server` | GenServer: subscribe, catch-up, live, retry, halt FSM | `lib/orkestra/projector/server.ex` |
| `Orkestra.Projector.Lifecycle` | Pure functions: retry logic, error classification, halt decision | `lib/orkestra/projector/lifecycle.ex` |
| `Orkestra.Projection.Storage` | Behaviour: `write/3`, `reset/1` (per-adapter write API only) | `lib/orkestra/projection/storage.ex` |
| `Orkestra.Projection.Checkpoint` | Read/write checkpoint position for a projector name | `lib/orkestra/projection/checkpoint.ex` |
| `Orkestra.Projection.DeadLetter` | Park failed events; query parked events per projector | `lib/orkestra/projection/dead_letter.ex` |
| `Orkestra.Projection.Storage.Ecto` | Ecto adapter: wraps user's `project` callbacks in `Ecto.Multi`, commits atomically with checkpoint | `lib/orkestra/projection/storage/ecto.ex` |
| `Orkestra.Projection.Supervisor` | `one_for_one` supervisor over all projector GenServers | `lib/orkestra/projection/supervisor.ex` |
| `Orkestra.Projection.Migration` | Mix tasks and helpers: per-projection isolated `Ecto.Migrator.run/4` | `lib/mix/tasks/orkestra.projection.migrate.ex` |

## Recommended Project Structure

Within the Orkestra library (`lib/orkestra/`):

```
lib/orkestra/
├── projector.ex                   # Behaviour + DSL macro (use Orkestra.Projector)
├── projector/
│   ├── server.ex                  # GenServer lifecycle (subscribe/catch-up/live/retry/halt)
│   └── lifecycle.ex               # Pure functions: classify error, decide retry vs halt
├── projection/
│   ├── storage.ex                 # Behaviour: write/3, reset/1
│   ├── checkpoint.ex              # Read/write checkpoint (shared Ecto schema)
│   ├── dead_letter.ex             # Park failed events (shared Ecto schema)
│   ├── supervisor.ex              # one_for_one supervisor over projector GenServers
│   └── storage/
│       └── ecto.ex                # Postgres/Ecto adapter (Ecto.Multi, transactional writes)

priv/
└── orkestra/
    └── migrations/                # Orkestra-owned tables: projection_checkpoints, projection_dead_letters
        ├── 20260624000001_create_projection_checkpoints.exs
        └── 20260624000002_create_projection_dead_letters.exs
```

Within an application using Orkestra (developer-owned):

```
lib/my_app/
└── projections/
    └── order_summary/
        ├── projector.ex           # defmodule MyApp.Projections.OrderSummary.Projector
        │                          #   use Orkestra.Projector, ...
        ├── schema.ex              # Ecto schema for the read model table(s)
        ├── queries.ex             # (optional generated) paged list/1, get_by/2
        └── repo.ex                # MyApp.Projections.OrderSummary.Repo (per-projection)

priv/
└── my_app/
    └── projections/
        └── order_summary/
            └── migrations/        # Isolated migrations for this projection's tables
                └── 20260624000001_create_order_summaries.exs
```

### Structure Rationale

- **`lib/orkestra/projector.ex` (the entry point):** Mirrors `Orkestra.EventHandler` — a `use Orkestra.Projector, ...` macro that injects the GenServer, subscribes, and wires the `project/2` callbacks. Developers only touch this file.
- **`lib/orkestra/projector/server.ex`:** All lifecycle state machine logic lives here, not in the user-facing projector module. Same split as `Aggregate` (pure) vs `Aggregate.Root` (imperative shell).
- **`lib/orkestra/projection/storage.ex`:** The storage behaviour is separate from the projector behaviour so that future adapters (Mongo, ES) only implement `write/3` and `reset/1` — the lifecycle stays unchanged.
- **`lib/orkestra/projection/checkpoint.ex`:** Checkpoint and dead-letter are Orkestra-owned schemas stored in the application's main repo (or a dedicated Orkestra repo). They are not per-projection — they are the cross-cutting plumbing.
- **Per-projection repo (`MyApp.Projections.OrderSummary.Repo`):** Owns only the read-model tables. Uses a distinct `migration_source` table name (`projection_order_summary_migrations`) so its migration history is fully isolated from the app's `schema_migrations`.

## Architectural Patterns

### Pattern 1: Dual-Phase EventStore Subscription (Catch-Up then Live)

**What:** On `init`, the projector GenServer reads its last checkpoint from `projection_checkpoints`, then opens a persistent subscription to the EventStore from that position. The EventStore delivers all historical events from checkpoint → head (catch-up phase), then seamlessly delivers new events as they arrive (live phase). No code switch is needed — the same `handle_info({:events, events}, state)` clause handles both phases.

**When to use:** Always — this is the only correct model for projectors. PubSub alone misses events published before the projector started. EventStore direct reads alone require polling. The persistent subscription handles both.

**Trade-offs:** Requires `EventStore.subscribe_to_all_streams/3` or `subscribe_to_stream/4`. For the InMemory adapter, the subscription must be emulated (polling or process-local delivery). For EventStoreDB, Spear supports persistent subscriptions natively.

**Example skeleton:**

```elixir
# In Orkestra.Projector.Server (GenServer)
def init(%{projector: module, name: name}) do
  send(self(), :subscribe)
  {:ok, %{projector: module, name: name, status: :starting, retry_count: 0}}
end

def handle_info(:subscribe, state) do
  checkpoint = Checkpoint.load(state.name)  # last processed position, or -1
  store = EventStore.impl()
  :ok = store.subscribe(state.name, self(), from_position: checkpoint)
  {:noreply, %{state | status: :catching_up}}
end

def handle_info({:events, events}, state) do
  Enum.reduce_while(events, {:noreply, state}, fn event, {:noreply, acc_state} ->
    case process_event(event, acc_state) do
      {:ok, new_state} -> {:cont, {:noreply, new_state}}
      {:halt, new_state} -> {:halt, {:stop, :halted, new_state}}
    end
  end)
end
```

### Pattern 2: Transactional Checkpoint Co-Write (Atomic With Read-Model Update)

**What:** For the Ecto adapter, the checkpoint position is written in the same `Ecto.Multi` transaction as the read-model update. This prevents the checkpoint advancing while the read-model write is mid-flight, and prevents the read model being updated without a checkpoint advance. If the transaction rolls back, the projector retries the same event.

**When to use:** Always for the Ecto/Postgres adapter. MongoDB adapters must handle this with two-phase writes (write read model, then write checkpoint) and accept at-least-once semantics with idempotent handlers. Elasticsearch cannot do atomic two-phase writes; checkpoint is written after a successful index call.

**Trade-offs:** Requires that the checkpoint table lives in the same Postgres database as the read model. This is the design: each per-projection Repo connects to the same Postgres database as the app's main Repo (just using its own migration table). The checkpoint row is written via that same Repo.

**Example (Ecto adapter write):**

```elixir
# In Orkestra.Projection.Storage.Ecto
def write(repo, event, position, user_multi_fn) do
  multi =
    Ecto.Multi.new()
    |> user_multi_fn.(event)                                     # user's project callback
    |> Ecto.Multi.run(:checkpoint, fn repo, _ ->                 # atomic checkpoint advance
         Checkpoint.upsert(repo, projector_name, position)
       end)

  case repo.transaction(multi) do
    {:ok, _} -> :ok
    {:error, _step, reason, _changes} -> {:error, reason}
  end
end
```

### Pattern 3: Retry-Then-Park-Then-Halt Error Handling

**What:** Strictly ordered — must not skip events. On `handle_event` error: (1) increment `retry_count` in GenServer state; (2) if below `max_retries`, re-deliver the same event after an exponential backoff (`Process.send_after(self(), {:retry_event, event}, delay)`); (3) on exhaustion, write the event to `projection_dead_letters` (with projector name, position, event data, error reason, timestamp), then `{:stop, :halted, state}`. The supervisor child spec uses `restart: :transient` so a deliberate halt is not auto-restarted.

**When to use:** Default for all projectors. The `max_retries` and backoff are configurable per-projector via `use Orkestra.Projector, max_retries: 5`.

**Trade-offs:** Halted projectors require operator attention. This is intentional — an invalid read model (from skipped events) is worse than a paused projector. Provide an admin function (`Orkestra.Projector.resume/1`) that clears the dead-letter entry and restarts the GenServer.

**Example state machine:**

```
:starting → (subscribe) → :catching_up → (caught up) → :running
:running → (error) → :retrying (retry_count < max)
:retrying → (retry ok) → :running
:retrying → (retry exhausted) → (park to dead_letters) → :halted → GenServer.stop
```

### Pattern 4: Per-Projection Isolated Ecto Repo and Migrations

**What:** Each projection has its own `Ecto.Repo` module pointing to the same database but using a distinct `migration_source` table. Migrations live in `priv/my_app/projections/MY_PROJECTION/migrations/`. `Ecto.Migrator.run/4` is called per-projection at startup via `Ecto.Migrator.with_repo/3`. The projection can be rolled back, dropped, or rebuilt without touching any other projection or the app's own `schema_migrations`.

**When to use:** Always for the Ecto adapter. This enables the "graceful migrations" goal: each projection is independently migratable.

**Why not a shared Repo:** Sharing the app's main Repo would couple projection table evolution to the app's migration history. A dropped or rebuilt projection would modify shared migration state.

**Example config (in application):**

```elixir
# config/config.exs
config :my_app, MyApp.Projections.OrderSummary.Repo,
  database: "my_app_repo",
  migration_source: "projection_order_summary_migrations",
  priv: "priv/my_app/projections/order_summary"

# In mix.exs or application.ex:
# Start the per-projection repo under the projection supervisor
# Run migrations at boot: Ecto.Migrator.with_repo(Repo, &Ecto.Migrator.run(&1, path, :up, all: true))
```

### Pattern 5: Storage Adapter Behaviour (Enabling Mongo and ES Later)

**What:** `Orkestra.Projection.Storage` defines a behaviour with exactly two write-side callbacks: `write/4` (apply one event to the storage, update checkpoint) and `reset/1` (clear the read model for rebuild). The checkpoint read (`load_position/1`) is called by the shared `Projector.Server`, not by the adapter. This keeps the adapter surface minimal and storage-specific.

**When to use:** All projection storage backends implement this behaviour. The Ecto adapter is the first implementation.

**How Mongo slots in:** `Orkestra.Projection.Storage.Mongo` implements `write/4` using the `mongodb` driver with `Mongo.insert_one/3` or `Mongo.update_one/4`. No Ecto involved. Checkpoints for Mongo projectors are stored in a separate lightweight Postgres (or ETS for dev) checkpoint store, since Mongo has no native transactions across collections that include the checkpoint.

**How ES slots in:** `Orkestra.Projection.Storage.Elasticsearch` implements `write/4` using an HTTP client. Checkpoint is written after a confirmed index call. Migration equivalent is handled via index mapping versioning and alias swap (outside this behaviour — ES adapter exposes its own `migrate/1` and `rebuild/1` that the lifecycle layer calls instead of `reset/1`).

**Behaviour definition:**

```elixir
defmodule Orkestra.Projection.Storage do
  @type projector_name :: String.t()
  @type event :: map()
  @type position :: non_neg_integer()
  @type opts :: keyword()

  @doc "Apply one event to the read-model storage and advance the checkpoint atomically."
  @callback write(projector_name(), event(), position(), opts()) :: :ok | {:error, term()}

  @doc "Clear (drop/truncate) the read model to prepare for a full rebuild."
  @callback reset(projector_name(), opts()) :: :ok | {:error, term()}
end
```

## Data Flow

### Primary Event-to-Read-Model Flow

```
EventStore.append_events
      │
      ▼ (EventStore persistent subscription delivers events in order)
Projector.Server (GenServer)
      │
      ├── load checkpoint from projection_checkpoints (on init)
      ├── subscribe to EventStore from checkpoint position
      │
      ▼ receive {:events, [event, ...]}
      │
      ├── for each event:
      │       │
      │       ├── call user's project/2 callback
      │       │       ↓ returns {:ok, multi} or :skip or {:error, reason}
      │       │
      │       ├── [on :ok] pass event + multi to Storage.write/4
      │       │       ↓ Storage.Ecto: Ecto.Multi + checkpoint upsert, in one transaction
      │       │       ↓ Storage.Mongo: driver write, then checkpoint write (two-phase)
      │       │
      │       ├── [on {:error, _}] retry (Lifecycle.next_action/3)
      │       │       ↓ if retries exhausted: DeadLetter.park/3 → GenServer.stop(:halted)
      │       │
      │       └── [on :skip] advance checkpoint only (no read-model write)
      │
      └── after all events: ack to EventStore subscription
```

### Checkpoint Advance Data Flow

```
Ecto adapter (atomic):
  Ecto.Multi
    ├── user's project steps (read-model table writes)
    └── checkpoint upsert (projection_checkpoints row for this projector)
  ──→ repo.transaction(multi)
  ──→ :ok (checkpoint advanced atomically with read-model)

Mongo adapter (two-phase, at-least-once):
  1. Mongo.insert/update (read-model write)
  2. Checkpoint.upsert (separate Postgres or ETS write)
  ──→ idempotent handlers required (duplicate event delivery possible on crash between steps)

ES adapter (post-write):
  1. HTTP index call (ES write)
  2. Checkpoint.upsert (separate write)
  ──→ same at-least-once semantics as Mongo
```

### Replay/Rebuild Flow

```
Developer calls: Orkestra.Projector.rebuild(MyProjector)
      │
      ├── 1. Stop projector GenServer (graceful shutdown)
      ├── 2. Storage.reset(projector_name, opts)  → truncate read-model tables
      ├── 3. Checkpoint.reset(projector_name)      → set position to -1 (origin)
      ├── 4. Run per-projection migrations (Ecto.Migrator.run/4) if schema changed
      └── 5. Restart projector GenServer
                │
                ▼ subscribes from position -1 (all events from beginning)
                ▼ processes all historical events in order
                ▼ checkpoints as it goes (crash-safe: resumes from last checkpoint on restart)
                ▼ reaches head → transitions to live mode
```

### Supervision Tree Placement

```
Application.start/2
  └── Supervisor (one_for_one)
        ├── MyApp.Repo (existing)
        ├── Orkestra.MessageBus adapter (existing)
        ├── Orkestra.EventStore adapter (existing)
        ├── MyApp.SomeCommandHandler (existing)
        ├── MyApp.SomeEventHandler  (existing)
        └── Orkestra.Projection.Supervisor (new, one_for_one)
              ├── MyApp.Projections.OrderSummary.Repo     (per-projection Repo)
              ├── MyApp.Projections.OrderSummary.Projector (GenServer, restart: :transient)
              ├── MyApp.Projections.UserIndex.Repo
              └── MyApp.Projections.UserIndex.Projector
```

The `Orkestra.Projection.Supervisor` is a plain `Supervisor` with `strategy: :one_for_one`. Each child projector uses `restart: :transient` — it is restarted on crashes (unexpected exits) but NOT on deliberate halts (`GenServer.stop(:halted)` exits with `:normal` or `{:shutdown, :halted}`). The per-projection Repo is started before its projector because the projector's checkpoint read requires the Repo.

## Scaling Considerations

| Scale | Architecture Adjustments |
|-------|--------------------------|
| Single node, few projections | Plain `Supervisor` with static children. No changes needed. |
| Many projections (10+) | `DynamicSupervisor` for the projectors only. Repos remain statically supervised. Enables runtime add/remove for rebuild. |
| Multi-node (distributed) | One projector process per projection per node is incorrect — each would consume the same EventStore subscription. Use a `{:via, Horde.Registry, name}` to ensure only one projector per name cluster-wide, or use EventStoreDB's built-in competing consumers. |
| High event throughput | Batch acknowledgment (ack every N events instead of per-event) and buffered `Ecto.Multi` writes. The storage behaviour's `write/4` can be changed to `write_batch/4` in a future iteration. |

## Anti-Patterns

### Anti-Pattern 1: Subscribing via MessageBus Instead of EventStore

**What people do:** Use `use Orkestra.EventHandler, event: MyEvent` for projections, which subscribes via PubSub or RabbitMQ.

**Why it's wrong:** PubSub delivers only live events. Events published before the projector started (including all historical events on a new deployment or after a rebuild) are permanently lost to the projector. The read model is permanently incomplete.

**Do this instead:** Subscribe directly to the EventStore from the last checkpoint. The EventStore delivers missed events in order first (catch-up), then transitions to live.

### Anti-Pattern 2: Skipping Events on Error to Avoid Halting

**What people do:** On a failed `handle_event`, log the error and advance the checkpoint anyway to keep the projector running.

**Why it's wrong:** The read model now has a permanent gap. Queries that depend on the skipped event return stale or incorrect data with no indication of the problem. This is a silent data integrity failure.

**Do this instead:** Retry the failed event up to `max_retries`, park it to `projection_dead_letters`, and halt the projector. A halted projector is visible (telemetry, logs, dead-letter table); a silently corrupted read model is not.

### Anti-Pattern 3: Writing Checkpoint and Read Model in Separate Transactions (Ecto)

**What people do:** First commit the Ecto changes, then update the checkpoint in a second call.

**Why it's wrong:** If the process crashes between the two writes, the read model is updated but the checkpoint is not. On restart, the event is replayed and applied again — double-write. For non-idempotent operations (e.g., incrementing a counter), this corrupts the read model.

**Do this instead:** Use `Ecto.Multi` to include the checkpoint upsert in the same transaction as the read-model writes. See Pattern 2.

### Anti-Pattern 4: Per-Projection Tables in the App's Main Repo Migration History

**What people do:** Add projection table migrations to `priv/repo/migrations/` alongside the main app migrations.

**Why it's wrong:** Dropping and rebuilding a projection requires deleting migration rows from `schema_migrations`, which pollutes the migration history. You cannot roll back just one projection. The projection is tightly coupled to the app's migration lifecycle.

**Do this instead:** Each projection has its own `Ecto.Repo`, `migration_source` config, and `priv/` directory. Its migration history is completely isolated.

### Anti-Pattern 5: Mixing Write-Side EventHandlers and Projectors in the Same GenServer Module

**What people do:** Add read-model update logic to an existing `EventHandler` GenServer that also triggers side effects.

**Why it's wrong:** EventHandlers and projectors have different lifecycle needs: EventHandlers are fire-and-forget (no checkpoint, no replay, restart-on-crash is fine); projectors need ordered delivery, checkpointing, and halt-on-exhaustion. Mixing them means neither concern is handled correctly.

**Do this instead:** Keep projectors as distinct `Orkestra.Projector` GenServers. They may subscribe to the same events as EventHandlers but operate on a separate subscription with their own checkpoint.

## Integration Points

### Internal Boundaries

| Boundary | Communication | Notes |
|----------|---------------|-------|
| Projector.Server ↔ EventStore | EventStore subscription (push, handle_info) | EventStore must expose a `subscribe/3` API accepting from_position; InMemory adapter needs this added |
| Projector.Server ↔ Projection.Checkpoint | Direct function call (same DB as per-projection Repo) | Checkpoint.load/1 on init; Checkpoint.upsert/3 inside Ecto.Multi for atomic writes |
| Projector.Server ↔ Projection.DeadLetter | Direct function call on halt | DeadLetter.park/3 before GenServer.stop |
| Projector.Server ↔ Storage adapter | Calls Storage.write/4, Storage.reset/1 | Storage adapter is configured per-projector (like EventStore/MessageBus impl()) |
| Storage.Ecto ↔ per-projection Repo | Ecto.Multi + Repo.transaction/1 | Per-projection Repo must be started before the projector GenServer |
| Projection.Supervisor ↔ App Supervisor | Plain child spec | Orkestra.Projection.Supervisor is added to the user's application.ex |
| Projector.Server ↔ Telemetry | OTel spans (existing Telemetry module) | Reuse OTel.with_span for event processing; emit lag metric, checkpoint position, error count |

### External Services

| Service | Integration Pattern | Notes |
|---------|---------------------|-------|
| PostgreSQL | Ecto.Repo + Ecto.Migrator (per-projection Repo) | Same DB as main app; only migration table is separate |
| EventStoreDB | Spear persistent subscription from position | Existing Spear dep; needs `subscribe_to_all_streams` or per-stream subscribe |
| MongoDB (future) | `mongodb` Hex dep (optional), Storage.Mongo adapter | Optional dep, same pattern as `:amqp` for RabbitMQ |
| Elasticsearch (future) | `req` or `httpoison` HTTP client, Storage.Elasticsearch adapter | No Ecto; index mapping migrations are ES-specific, not Ecto migrations |

## Build Order

Dependencies flow strictly downward. Build in this order:

1. **`Orkestra.Projection.Checkpoint` + `Orkestra.Projection.DeadLetter`** — shared Ecto schemas and their Orkestra-owned migrations. No projector logic depends on storage adapters; these are pure data structures. Required by: Projector.Server, Storage.Ecto.

2. **`Orkestra.Projection.Storage` behaviour** — define the behaviour contract before writing any adapter. Required by: Storage.Ecto, Projector.Server.

3. **`Orkestra.Projection.Storage.Ecto`** — first adapter implementation. Validates the Storage behaviour is complete and usable. Required by: Projector macro integration.

4. **`Orkestra.Projector.Lifecycle`** — pure functions: classify `handle_event` result, compute next retry delay, decide halt. No I/O. Required by: Projector.Server.

5. **`Orkestra.Projector.Server`** — GenServer lifecycle: subscribe, catch-up, live, retry-loop, halt. Calls Checkpoint, DeadLetter, Storage, Lifecycle, EventStore, Telemetry. Required by: Projector macro.

6. **`Orkestra.Projector` macro** — `use Orkestra.Projector, ...` DSL that wires everything together for the developer. Mirrors `Orkestra.EventHandler`. Required by: application projector modules.

7. **`Orkestra.Projection.Supervisor`** — child spec generator and supervisor. Required by: application supervisor.

8. **Mix tasks** — `mix orkestra.projection.migrate`, `mix orkestra.projection.reset`, `mix orkestra.projection.rebuild`. Required by: developer workflow.

9. **`Orkestra.Projection.Queries` (optional)** — generated `list/1` (paged), `get_by/2` helpers per projection. Depends on: per-projection Repo and Ecto schemas.

10. **EventStore adapter changes** — add `subscribe_to_all_streams/3` (or from-position variant) to `Orkestra.EventStore` behaviour and both adapters (InMemory emulation, EventStoreDB Spear call). This is a cross-cutting change — do it in step 5 when Projector.Server first needs it.

11. **MCP generators** — `gen_projection`, `gen_read_model` after the core is proven end-to-end.

## Sources

- Commanded Elixir CQRS framework — reference implementation for projector lifecycle and error/3 callback pattern (verified via hexdocs.pm)
- Elixir EventStore hexdocs — persistent subscription, checkpoint, catch-up mode (verified via hexdocs)
- Ecto.Migrator hexdocs — `with_repo/3`, `run/4`, `migration_source` config (verified via hexdocs)
- Commanded Ecto Projections README — `projection_versions` table pattern, `project` macro structure (web research, LOW confidence on specifics)
- Orkestra codebase (`.planning/codebase/`) — existing patterns for behaviours, macros, GenServer handlers, OTel integration

---
*Architecture research for: Orkestra projection/read-model subsystem*
*Researched: 2026-06-24*
