# Architecture Research

**Domain:** Orkestra v1.1 — Elasticsearch/OpenSearch Projection Adapter
**Researched:** 2026-06-25
**Confidence:** MEDIUM — Snap library API verified via hexdocs; checkpoint and alias-swap patterns verified against Elasticsearch official docs and community literature; integration design is reasoned from existing Orkestra codebase.

---

## Context: What Already Exists (v1.0)

The following components are **shipping** in the codebase. This file documents only what v1.1 adds and how it integrates.

| Existing Component | Module | Role |
|--------------------|--------|------|
| Storage behaviour | `Orkestra.Projection.Storage` | `write/4 → ops :: term()`, `reset/2` |
| Postgres adapter | `Orkestra.Projection.Storage.Postgres` | Returns `Ecto.Multi.t()` ops; GenServer appends checkpoint Multi |
| Projector GenServer | `Orkestra.Projector.GenServer` | subscribe → catch-up → live → retry → park → halt |
| Projector macro | `Orkestra.Projector` | `use Orkestra.Projector, repo: ...`; `project/2` macro; `__handle__/3` |
| Projection Supervisor | `Orkestra.Projection.Supervisor` | `one_for_one` over all projector GenServers |
| Checkpoint | `Orkestra.Projection.Checkpoint` | Ecto schema: `projector_name`, `last_position`, `halted` |
| DeadLetter | `Orkestra.Projection.DeadLetter` | Ecto schema: parked events per projector |
| Lifecycle | `Orkestra.Projector.Lifecycle` | Pure retry/halt decision functions |
| Mix tasks | `mix orkestra.projection.*` | migrate, rollback, drop, rebuild (Ecto-backed) |

The key architectural constraint inherited from v1.0: `Storage.write/4` returns `ops :: term()` — an adapter-specific data structure, never a Repo-bound closure. For Postgres, `ops` is `Ecto.Multi.t()`. For ES, `ops` will be a list of `Snap.Bulk` action structs or a single-document descriptor. The GenServer decides when and how to commit.

---

## v1.1 System Overview

```
┌────────────────── WRITE SIDE (existing, unchanged) ──────────────────────┐
│  Command → Aggregate.Root → EventStore.append → MessageBus.publish        │
└──────────────────────────────────────────────────────────────────────────┘
                                       │
               ┌───────────────────────▼───────────────────────────────────┐
               │                PROJECTION SUBSYSTEM                        │
               │                                                            │
               │  ┌──────────────────────────────────────────────────────┐ │
               │  │        Orkestra.Projection.Supervisor (existing)      │ │
               │  │                                                       │ │
               │  │  ┌──────────────┐  ┌──────────────┐  ┌───────────┐  │ │
               │  │  │ PG Projector │  │ ES Projector │  │  ...      │  │ │
               │  │  │ (GenServer)  │  │ (GenServer)  │  │           │  │ │
               │  │  └──────┬───────┘  └──────┬───────┘  └───────────┘  │ │
               │  └─────────┼─────────────────┼──────────────────────── ┘ │
               │            │                 │                             │
               │  ┌─────────▼─────────────────▼────────────────────────┐  │
               │  │     Orkestra.Projector.GenServer (shared, existing)  │  │
               │  │     subscribe → catch-up → live → retry → halt      │  │
               │  └─────────┬────────────────────────────────────────── ┘  │
               │            │                                               │
               │  ┌─────────▼────────────────────────────────────────────┐ │
               │  │    Orkestra.Projection.Storage behaviour (existing)   │ │
               │  │    write/4 → ops :: term()   reset/2                  │ │
               │  │                                                       │ │
               │  │  ┌─────────────────┐   ┌──────────────────────────┐  │ │
               │  │  │ Storage.Postgres │   │ Storage.Elasticsearch    │  │ │
               │  │  │ (existing)       │   │ (NEW — v1.1)             │  │ │
               │  │  │ ops: Ecto.Multi  │   │ ops: ES write descriptor │  │ │
               │  │  └────────┬────────┘   └───────────┬──────────────┘  │ │
               │  └──────────┼────────────────────────┼──────────────── ┘  │
               │             │                         │                    │
               │  ┌──────────▼──────┐     ┌───────────▼───────────────┐   │
               │  │  Ecto.Repo      │     │  Snap.Cluster (HTTP pool)  │   │
               │  │  (per-proj Repo)│     │  (per-adapter supervision) │   │
               │  └─────────────────┘     └───────────────────────────┘   │
               │                                                            │
               │  ┌──────────────────────────────────────────────────────┐ │
               │  │   Checkpoint store (Ecto.Repo, existing Postgres)    │ │
               │  │   projection_checkpoints / projection_dead_letters   │ │
               │  │   Written by GenServer AFTER ES confirm (post-write)  │ │
               │  └──────────────────────────────────────────────────────┘ │
               └────────────────────────────────────────────────────────────┘
```

**Critical difference from Postgres adapter:** The ES adapter cannot participate in the `Ecto.Multi` + `Repo.transaction` flow. The GenServer must write ES first, then write the Postgres checkpoint. This changes the atomicity model from exactly-once (Postgres) to at-least-once with idempotent retry (ES).

---

## New Components for v1.1

### What is NEW (must be built)

| Component | Module Path | Purpose |
|-----------|-------------|---------|
| ES Storage adapter | `lib/orkestra/projection/storage/elasticsearch.ex` | Implements `Storage` behaviour; returns ES ops descriptor |
| ES ops type | Internal struct or map | Write descriptor: `%{action: :index | :delete, id: term(), doc: map()}` |
| ES-aware projector DSL | Extended `Orkestra.Projector` macro | New `project_es/2` macro or `:backend` option on `use Orkestra.Projector` |
| ES Cluster config | Consumer-defined `use Snap.Cluster` module | HTTP connection pool; child of app supervisor |
| ES Index Mapping DSL | `Orkestra.Projection.ESMapping` (optional helper) | Define index mappings in Elixir; analogous to Ecto.Migration |
| ES rebuild helpers | `mix orkestra.projection.es.rebuild` mix task | alias-swap rebuild flow; replaces Ecto.Migrator-based rebuild |
| ES Query DSL | `Orkestra.Projection.ESQuery` | Composable query builder (match, filter, aggs, sort, pagination) |
| ES checkpoint write in GenServer | Patch to `Orkestra.Projector.GenServer` | Post-write checkpoint path (no Ecto.Multi merge for ES ops) |

### What is MODIFIED (must be patched)

| Component | Change |
|-----------|--------|
| `Orkestra.Projector.GenServer` | Add ES-aware `apply_event` path: after `storage_adapter.write/4` succeeds and ES confirms, write checkpoint via `Checkpoint.upsert` directly (no Ecto.Multi.append). |
| `Orkestra.Projector` macro | Make `:repo` optional when `:backend` is `:elasticsearch`; generate `__handle__/3` that returns `{:ok, ops}` with ES ops descriptor instead of `Ecto.Multi`. |
| `Orkestra.Projection.Checkpoint` | Add `upsert/3` function (direct Repo call, no Multi wrapper) for the ES post-write checkpoint path. |
| `mix.exs` | Add `{:snap, "~> 0.16", optional: true}` to deps. |

### What is UNCHANGED

- `Orkestra.Projection.Storage` behaviour — `write/4` signature stays identical.
- `Orkestra.Projector.Lifecycle` — pure retry logic is adapter-agnostic.
- `Orkestra.Projection.Supervisor` — manages ES projectors identically to Postgres projectors.
- Checkpoint and DeadLetter Ecto schemas — ES adapter still uses Postgres-backed checkpoints; only the write path changes.

---

## Integration Point: Storage.write/4 for ES

### How ops changes between adapters

For the Postgres adapter, `write/4` returns `{:ok, Ecto.Multi.t()}` and the GenServer calls `Ecto.Multi.append(read_model_multi, checkpoint_multi)` followed by `repo.transaction(combined)`.

For the ES adapter, `write/4` returns `{:ok, ops}` where `ops` is an adapter-defined descriptor. Two viable designs:

**Option A — Single-doc descriptor map (RECOMMENDED for live mode):**

```elixir
# ops :: %{action: :index | :update | :delete, id: String.t(), doc: map()} | :skip
{:ok, %{action: :index, id: "order-123", doc: %{status: "placed", total: 99}}}
```

The GenServer calls `Snap.Document.index(cluster, index_name, doc, id)` directly.

**Option B — Snap.Bulk action list (for catch-up/rebuild batch mode):**

```elixir
# ops :: [Snap.Bulk.Action.Index.t() | Snap.Bulk.Action.Delete.t()]
{:ok, [%Snap.Bulk.Action.Index{id: "order-123", doc: %{...}}]}
```

The GenServer accumulates a buffer and flushes via `Snap.Bulk.perform/4`.

**Resolution:** The adapter returns Option A (single-doc descriptor) always. The GenServer switches between single-doc (live mode) and batch accumulation (catch-up/rebuild mode) transparently, without the adapter knowing which mode is active. In batch mode, the GenServer converts single-doc descriptors to `Snap.Bulk.Action.*` structs before flushing. This keeps the adapter simple and the batching logic in one place (GenServer).

### The ops type for ES

```elixir
@type es_op :: %{
  action: :index | :update | :delete,
  id: String.t() | integer(),
  doc: map(),     # omitted for :delete
  index: String.t() | nil  # override; nil means use adapter default
}
```

The GenServer detects whether `ops` is `Ecto.Multi.t()` or an `es_op` map by module type and dispatches accordingly.

---

## Integration Point: Checkpoint Co-Write Without Transactions

The Postgres adapter gets atomic exactly-once semantics by including the checkpoint upsert in the same `Ecto.Multi`. The ES adapter cannot do this — ES has no cross-store transactions.

### ES checkpoint write flow

```
1. storage_adapter.write/4 returns {:ok, es_op}
2. Snap.Document.index(cluster, index, doc, id)  ← ES HTTP call
   ├── {:ok, _}  → proceed to step 3
   └── {:error, _} → handle_failure (retry/park/halt as usual)
3. Checkpoint.upsert(repo, projector_name, position)  ← Postgres write
   ├── :ok     → event complete, state.attempts = 0
   └── {:error, _} → log warning; checkpoint not advanced; event will replay on restart
```

**Consequence:** If the process crashes between step 2 (ES confirmed) and step 3 (checkpoint written), the event replays on restart. ES will receive a duplicate index call. This is at-least-once semantics — projector handler functions must be idempotent.

**Idempotency mechanism:** Use the event's global position as the ES document `_id` when possible, or include it in the document and use `Snap.Document.index/6` (which is an upsert by id). Duplicate index calls with the same id and identical content are safe. For operations that accumulate state (counters, aggregations), the handler must be designed to accept replay.

**Checkpoint store placement:** Checkpoint and DeadLetter remain in Postgres (via existing Ecto.Repo), even when the read model is in ES. This is intentional — the checkpoint store needs ACID semantics; ES does not provide them.

---

## Integration Point: Alias Swap and Rebuild Flow

### Zero-downtime rebuild via alias swap

The Postgres rebuild flow (v1.0) uses `Ecto.Migrator` to drop/recreate tables, then replays events. For ES, the equivalent is an alias-swap rebuild:

```
Rebuild Flow (ES adapter):
  1. stop projector GenServer
  2. create new versioned index with updated mapping
     Snap.Indexes.create(cluster, "<alias>_v<timestamp>", mapping)
  3. replay all events from position 0 into the NEW index
     (projector writes to new index, not the alias target)
  4. once caught up to head:
     Snap.Indexes.alias(cluster, "<alias>_v<timestamp>", alias)
     → atomically updates alias to point to new index
     → old index still queryable until cleanup
  5. delete old index (optional, or keep N versions back)
     Snap.Indexes.delete(cluster, "<alias>_v<old_timestamp>")
  6. restart projector GenServer pointing at alias
```

Snap provides `Snap.Indexes.hotswap/5` which executes steps 2–5 automatically when given an enumerable of bulk actions. However, Orkestra needs streaming integration with the EventStore replay, so the rebuild task should call the steps individually rather than delegating to `hotswap/5` (which expects all documents upfront).

### Index naming convention

Snap uses timestamp-based versioned index names. Recommended convention:

```
alias:       orders_v1       (permanent alias, what queries use)
index names: orders_v1_<unix_timestamp>   (e.g., orders_v1_1750828800)
```

The projector DSL accepts an `:index` option (the alias name). The ES adapter resolves the current write target at runtime.

### Alias swap during live projection (mapping migration)

When a developer changes the index mapping (field added/removed/retyped), they run:

```
mix orkestra.projection.es.rebuild MyApp.OrderEsProjector
```

This triggers the alias-swap rebuild described above. Unlike Postgres projections, there is no `migrate up/down` sequence — mappings are replaced wholesale with each rebuild.

---

## Integration Point: HTTP Client Pool (Snap.Cluster)

### Where the pool lives

Snap.Cluster is an OTP supervision tree wrapping Finch connection pools. The consumer application defines their cluster module and adds it to their supervision tree:

```elixir
# lib/my_app/search_cluster.ex  (consumer-defined, not Orkestra-owned)
defmodule MyApp.SearchCluster do
  use Snap.Cluster, otp_app: :my_app
end

# config/config.exs
config :my_app, MyApp.SearchCluster,
  url: "http://localhost:9200",
  username: "elastic",
  password: "changeme"

# lib/my_app/application.ex
children = [
  MyApp.SearchCluster,
  {Orkestra.Projection.Supervisor, projectors: [MyApp.OrderEsProjector]}
]
```

The `Snap.Cluster` module is passed to the ES projector as a config parameter:

```elixir
defmodule MyApp.OrderEsProjector do
  use Orkestra.Projector,
    backend: :elasticsearch,
    cluster: MyApp.SearchCluster,
    index: "orders",
    checkpoint_repo: MyApp.CheckpointRepo,
    event_store: Orkestra.EventStore.InMemory
  ...
end
```

### No per-projector pool

Unlike Postgres (where each projector owns its own `Ecto.Repo` and connection pool), multiple ES projectors can share a single `Snap.Cluster`. The cluster is named by the consumer and injected per-projector. This matches the pattern for how EventStoreDB (Spear) and RabbitMQ (AMQP) are handled — shared, injected connection.

---

## Integration Point: Index Mappings vs Ecto Migrations

### Differences from Ecto migrations

Ecto migrations are versioned, reversible, and tracked in a `schema_migrations` table. ES index mappings work differently:

- You **cannot alter** an existing index mapping (changing field type requires reindex).
- You **can add** new fields to an existing mapping without reindex.
- Mapping **versions** are managed by the alias-swap pattern, not a migration table.

### Mapping definition approach

Orkestra provides a helper module (not a full DSL) for defining mappings as Elixir maps:

```elixir
# In the projector module or a separate mapping file
def es_mapping do
  %{
    "mappings" => %{
      "properties" => %{
        "order_id"   => %{"type" => "keyword"},
        "status"     => %{"type" => "keyword"},
        "total"      => %{"type" => "float"},
        "created_at" => %{"type" => "date"},
        "customer"   => %{
          "type" => "object",
          "properties" => %{
            "name" => %{"type" => "text"}
          }
        }
      }
    }
  }
end
```

This map is passed to `Snap.Indexes.create/4` during the rebuild flow. The consumer app owns the mapping definition; Orkestra provides the plumbing to apply it.

### No `mix orkestra.projection.migrate` for ES

The Postgres mix tasks (`migrate`, `rollback`) have no meaningful equivalent for ES. The ES operational workflow is:

- **Schema change** → run `mix orkestra.projection.es.rebuild` (alias-swap rebuild)
- **Data fix** → run `mix orkestra.projection.es.rebuild` (full replay)
- **Drop** → `Snap.Indexes.delete(cluster, index_name)` (no Ecto.Migrator needed)

The existing `mix orkestra.projection.rebuild` task is Ecto-specific. A new `mix orkestra.projection.es.rebuild` task handles the alias-swap flow.

---

## Integration Point: Batch Accumulation in GenServer Lifecycle

### Why batching matters for ES

ES has a bulk indexing API that is significantly more efficient than single-document indexing for high-throughput catch-up replay. Snap's default `page_wait` is 15 seconds — too long for a projector rebuild. The GenServer controls batching, not the adapter.

### Batch mode activation

The GenServer enters batch mode when `state.rebuild_total` is set (during a rebuild) or when the catch-up subscription is delivering events faster than a configurable threshold. In batch mode:

1. Each call to `storage_adapter.write/4` returns an `es_op` descriptor (same as live mode).
2. The GenServer accumulates ops in a buffer (`state.batch_buffer`).
3. The buffer is flushed to ES via `Snap.Bulk.perform/4` when:
   - Buffer reaches `:batch_size` (default: 500 ops), OR
   - A configurable `batch_timeout_ms` elapses (default: 5_000ms), OR
   - The projector transitions from catch-up to live.
4. After a successful flush, checkpoints are advanced to the last-flushed event position.

### GenServer state additions for ES

```elixir
# Added to existing state map for ES-backend projectors
batch_buffer: [],             # accumulated es_op descriptors
batch_positions: [],          # corresponding event positions
batch_size: 500,              # max ops before auto-flush
batch_timeout_ms: 5_000,      # max wait before auto-flush
batch_timer_ref: nil          # Process.send_after ref for timeout flush
```

### Batch flush and checkpoint atomicity

After `Snap.Bulk.perform/4` succeeds, the GenServer writes the checkpoint for the highest position in the flushed batch. This remains at-least-once — a crash after bulk confirm but before checkpoint write causes replay of the entire batch. Handlers must be idempotent.

### Live mode stays single-doc

Once the projector catches up to head and transitions to live mode, it reverts to single-doc indexing via `Snap.Document.index/6`. Latency per event matters more than throughput in live mode.

---

## Data Flow

### Live mode (single event, post-write checkpoint)

```
EventStore subscription delivers event
      │
      ▼
Projector.GenServer.handle_info/2
      │
      ├── storage_adapter.write/4 → {:ok, es_op}
      │       (ES adapter calls user's project_es/2 callback, returns doc descriptor)
      │
      ├── Snap.Document.index(cluster, index, doc, id)
      │       ├── {:ok, _}  → proceed
      │       └── {:error, _} → Lifecycle.classify → retry / park+halt
      │
      ├── Checkpoint.upsert(repo, projector_name, position)
      │       ├── :ok  → event complete
      │       └── {:error, _} → log warning; checkpoint stays stale; event replays on restart
      │
      └── {:noreply, %{state | attempts: 0, last_seen_position: position}}
```

### Catch-up / rebuild mode (batch)

```
EventStore subscription delivers events (burst during catch-up)
      │
      ▼
Projector.GenServer.handle_info/2 (per event)
      │
      ├── storage_adapter.write/4 → {:ok, es_op}
      ├── append es_op to state.batch_buffer
      ├── if length(batch_buffer) >= batch_size → flush
      │       │
      │       └── Snap.Bulk.perform(actions, cluster, index)
      │               ├── :ok → Checkpoint.upsert(repo, name, last_position_in_batch)
      │               └── {:error, %Snap.BulkError{}} → handle_failure
      │
      └── {:noreply, state}  (buffer accumulates)

Transition to live mode:
      │
      ├── flush remaining batch_buffer
      ├── write checkpoint for last position
      └── clear batch_buffer, enter single-doc mode
```

### Rebuild flow (alias-swap)

```
mix orkestra.projection.es.rebuild MyApp.OrderEsProjector
      │
      ├── 1. Supervisor.terminate_child → stop projector
      ├── 2. Snap.Indexes.create(cluster, "<index>_<ts>", mapping)
      ├── 3. Reset checkpoint: Checkpoint.reset(repo, projector_name)
      ├── 4. Supervisor.restart_child
      │       → projector subscribes from -1 (all events)
      │       → GenServer sets rebuild target index = "<index>_<ts>" (not alias)
      │       → catch-up batch replay into new index
      ├── 5. (on caught up signal) Snap.Indexes.alias(cluster, "<index>_<ts>", alias)
      └── 6. Snap.Indexes.delete old index (deferred or immediate)
```

Steps 4–6 require the GenServer to know it is in rebuild-to-new-index mode. This is passed in the restart config (similar to how `rebuild_total` is set today).

---

## Recommended Project Structure (additions for v1.1)

```
lib/orkestra/
├── projector.ex                      # MODIFIED: :backend option, project_es/2 macro
├── projector/
│   ├── gen_server.ex                 # MODIFIED: ES post-write checkpoint path, batch mode
│   └── lifecycle.ex                  # unchanged
├── projection/
│   ├── storage.ex                    # unchanged
│   ├── checkpoint.ex                 # MODIFIED: add upsert/3 direct function
│   ├── dead_letter.ex                # unchanged
│   ├── supervisor.ex                 # unchanged
│   └── storage/
│       ├── postgres.ex               # unchanged (renamed from ecto.ex in v1.0 research)
│       └── elasticsearch.ex          # NEW: ES/OpenSearch adapter

lib/mix/tasks/
├── orkestra.projection.migrate.ex    # unchanged
├── orkestra.projection.rollback.ex   # unchanged
├── orkestra.projection.drop.ex       # unchanged
├── orkestra.projection.rebuild.ex    # unchanged (Postgres only)
└── orkestra.projection.es.rebuild.ex # NEW: alias-swap rebuild for ES
```

---

## Architectural Patterns

### Pattern 1: Adapter-Specific ops Type Detection in GenServer

**What:** The GenServer receives `ops :: term()` from `storage_adapter.write/4`. It dispatches to the correct commit path by pattern-matching on the `ops` type:

```elixir
defp commit_ops(%Ecto.Multi{} = multi, state) do
  # Postgres path: append checkpoint Multi and transact
  checkpoint_multi = build_checkpoint_multi(state)
  combined = Ecto.Multi.append(multi, checkpoint_multi)
  state.repo.transaction(combined)
end

defp commit_ops(%{action: action} = es_op, state) when action in [:index, :update, :delete] do
  # ES live path: HTTP call, then checkpoint
  with {:ok, _} <- snap_apply(es_op, state),
       :ok <- Checkpoint.upsert(state.repo, state.projector_name, state.last_seen_position) do
    {:ok, :es_committed}
  end
end

defp commit_ops(:skip, state) do
  # No read-model write; still advance checkpoint (both adapters)
  Checkpoint.upsert(state.repo, state.projector_name, state.last_seen_position)
end
```

**When to use:** Every time `storage_adapter.write/4` returns. The dispatch is internal to the GenServer; the Storage behaviour does not change.

**Trade-offs:** Couples the GenServer to knowledge of ES-specific op shapes. The alternative (a second callback `commit/4` on the behaviour) would keep the GenServer clean but makes the behaviour wider. Given only two adapters and a clear shape difference, pattern matching in the GenServer is simpler and avoids over-engineering the behaviour.

### Pattern 2: Idempotent ES Writes via Event Position as Document ID

**What:** Use the event's global position (or a deterministic derivative like `"#{stream_id}-#{revision}"`) as the ES document `_id`. When the same event replays due to an at-least-once checkpoint miss, `Snap.Document.index/6` overwrites the document with identical content — safe no-op.

**When to use:** Always for ES projections. Document IDs must be stable and deterministic from the event, not auto-generated by ES.

**Trade-offs:** Requires the domain event to carry a stable, unique identifier. For events that update existing documents (e.g., order status updates), the document id is the domain entity id, not the event position — the update is naturally idempotent.

**Example:**

```elixir
project_es MyApp.Events.OrderPlaced, fn event ->
  %{
    action: :index,
    id: event.data.order_id,
    doc: %{
      order_id: event.data.order_id,
      status: "placed",
      total: event.data.total,
      placed_at: event.data.placed_at
    }
  }
end
```

### Pattern 3: Shared Checkpoint Store (Postgres) for ES Projections

**What:** Even when the read model lives in ES, checkpoints and dead letters are persisted in Postgres (the existing `Ecto.Repo`). The ES projector is configured with a `:checkpoint_repo` that is an `Ecto.Repo` — this may be a dedicated lightweight Repo or the app's existing main Repo.

**When to use:** Always for ES adapter. ES is not a reliable checkpoint store because ES writes have no ACID guarantees and ES itself cannot participate in the same transaction as the checkpoint write.

**Trade-offs:** Requires the consumer app to have a Postgres database available even for an "ES-only" projection. This is an intentional constraint — the alternative (checkpoint in ES) loses reliability guarantees.

**Configuration:**

```elixir
defmodule MyApp.OrderEsProjector do
  use Orkestra.Projector,
    backend: :elasticsearch,
    cluster: MyApp.SearchCluster,
    index: "orders",
    checkpoint_repo: MyApp.Repo,   # existing app repo; OR a dedicated lightweight repo
    event_store: Orkestra.EventStore.InMemory
  ...
end
```

### Pattern 4: ES Index Mapping as Elixir Map (No Migration DSL)

**What:** Index mappings are plain Elixir maps returned by a `mapping/0` callback on the projector module. No migration versioning or reversibility is needed because ES mapping changes require a full reindex (via alias swap). The mapping is the source of truth, applied at rebuild time.

**When to use:** Every ES projector defines a `mapping/0` callback. The ES rebuild mix task reads this mapping and passes it to `Snap.Indexes.create/4`.

**Trade-offs:** No incremental migration path — any mapping change requires a full rebuild. For ES projections, this is expected and correct; it is not a limitation but a design characteristic.

### Pattern 5: Optional Snap Dependency Guard

**What:** The ES adapter module is wrapped in `if Code.ensure_loaded?(Snap.Cluster) do ... end`, matching the existing pattern for `Ecto.Multi` (Postgres adapter) and `AMQP.Channel` (RabbitMQ bus).

**Example:**

```elixir
if Code.ensure_loaded?(Snap.Cluster) do
  defmodule Orkestra.Projection.Storage.Elasticsearch do
    @behaviour Orkestra.Projection.Storage
    # ...
  end
end
```

**When to use:** Always — Snap is an optional dependency. The library must compile cleanly without it.

---

## Anti-Patterns

### Anti-Pattern 1: Transactional Checkpoint for ES (Ecto.Multi.append on ES ops)

**What people do:** Try to include the ES checkpoint write in an `Ecto.Multi` alongside the ES API call.

**Why it's wrong:** ES is an HTTP call, not a database transaction participant. `Ecto.Multi` cannot wrap an HTTP request. The `Ecto.Multi.append` pattern from the Postgres adapter does not apply.

**Do this instead:** Write to ES first (HTTP), then write the Postgres checkpoint. Accept at-least-once semantics and make handlers idempotent.

### Anti-Pattern 2: Generating ES Document IDs from Auto-increment or UUID at Write Time

**What people do:** Generate a new UUID or use `System.unique_integer()` as the ES document id inside the `project_es/2` handler.

**Why it's wrong:** On replay, a new random id is generated, creating duplicate documents instead of overwriting. The projection grows unbounded with each rebuild.

**Do this instead:** Derive the document id deterministically from the domain entity id or the event's unique identifier.

### Anti-Pattern 3: Writing to ES Index Directly (Bypassing Alias)

**What people do:** Configure the projector with `:index` pointing to a physical index name (e.g., `"orders_v1_1750828800"`) instead of an alias (e.g., `"orders"`).

**Why it's wrong:** After a rebuild, the alias points to a new physical index but queries still use the old physical name. Zero-downtime alias swap only works if both reads and writes go through the alias.

**Do this instead:** Always configure `:index` as the alias name. Only during an active rebuild does the GenServer temporarily write to the new physical index directly.

### Anti-Pattern 4: Using Snap.Indexes.hotswap/5 Directly for Rebuild

**What people do:** Collect all events first, build a stream, and call `Snap.Indexes.hotswap/5` once with the full document set.

**Why it's wrong:** `hotswap/5` requires all documents upfront — you must materialize the full projection before swapping. For large event stores, this buffers the entire read model in memory. It also bypasses Orkestra's checkpoint-based crash recovery.

**Do this instead:** Use `Snap.Indexes.create/4` to create the new index, stream events through the normal GenServer catch-up path writing into the new index, then call `Snap.Indexes.alias/4` once caught up.

### Anti-Pattern 5: One Snap.Cluster per ES Projector

**What people do:** Create a separate `Snap.Cluster` module per projector for isolation.

**Why it's wrong:** Each `Snap.Cluster` manages its own Finch connection pool. Multiple clusters to the same ES host multiply connections unnecessarily.

**Do this instead:** Share one `Snap.Cluster` across all ES projectors pointing to the same ES cluster. Use Snap.Cluster.Namespace if index isolation is needed.

---

## Scaling Considerations

| Scale | Architecture Notes |
|-------|--------------------|
| Single node, low event rate | Single-doc live indexing; no batching needed. |
| Single node, rebuild of large history | Enable batch mode (configurable `batch_size`); set `page_wait: 0` in bulk options for speed. |
| High event rate, multiple ES projectors | Shared `Snap.Cluster` with adequate pool size; batch mode activates automatically during catch-up. |
| Multi-node | Same constraint as Postgres projectors: one projector process per projection name across the cluster (use Horde or EventStoreDB competing consumers). ES itself scales independently. |

---

## Build Order for v1.1

Dependencies flow strictly downward. Phases are ordered by dependency graph:

**Phase 1: ES Storage Adapter + ops type**
- Add `{:snap, "~> 0.16", optional: true}` to `mix.exs`
- Define `es_op` type in `Storage.Elasticsearch`
- Implement `Orkestra.Projection.Storage.Elasticsearch`: `write/4` calls `project_es` handler, returns `{:ok, es_op}`; `reset/2` deletes all docs via `Snap.Document.delete` or index deletion
- Guard with `if Code.ensure_loaded?(Snap.Cluster) do`
- No GenServer changes yet; can be tested in isolation

**Phase 2: GenServer ES commit path + Checkpoint.upsert/3**
- Add `upsert/3` direct function to `Orkestra.Projection.Checkpoint` (non-Multi path)
- Patch `GenServer.apply_event` to detect `es_op` ops and route to post-write checkpoint path
- Patch `GenServer.apply_event` to route `Ecto.Multi` ops to existing Ecto.Multi path (unchanged)
- Test: ES projector commits to ES then writes checkpoint; crash between the two causes replay

**Phase 3: Batch accumulation in GenServer**
- Add `batch_buffer`, `batch_size`, `batch_timer_ref` to state
- Accumulate es_op descriptors during catch-up; flush via `Snap.Bulk.perform/4`
- After flush: `Checkpoint.upsert` for highest position in batch
- Transition to single-doc mode on catch-up → live
- Test: large replay fills buffer, flushes, checkpoints correctly

**Phase 4: Projector macro + DSL changes**
- Add `:backend` option to `use Orkestra.Projector`
- Add `project_es/2` macro that accumulates `{event_module, handler_fn}` pairs
- Generated `__handle__/3` returns `{:ok, es_op}` for ES backend
- Make `:repo` optional when `:backend == :elasticsearch` (required: `:cluster`, `:index`, `:checkpoint_repo`)
- Modify `child_spec/1` to set `storage_adapter: Orkestra.Projection.Storage.Elasticsearch`

**Phase 5: ES rebuild mix task + alias-swap flow**
- `mix orkestra.projection.es.rebuild` task
- Steps: stop projector → create new versioned index → reset checkpoint → restart with new index target → on caught up signal → alias swap → optional old index cleanup

**Phase 6: ES Query DSL**
- `Orkestra.Projection.ESQuery` composable builder (match, filter, range, aggs, pagination)
- Returns plain ES JSON-compatible map passed to `Snap.Search.query/4`
- No code generation required for query DSL (unlike Postgres Queries module)

**Phase 7: MCP generators for ES projections**
- `gen_es_projection` generator in `orkestra_mcp`
- Scaffolds: projector module, cluster module, mapping function, sample query
- Follows existing `gen_projection` pattern

---

## Integration Points Summary

| Boundary | Communication | Atomicity | Notes |
|----------|---------------|-----------|-------|
| GenServer ↔ ES adapter | `Storage.write/4` → `es_op` | None (HTTP) | Adapter returns descriptor; GenServer executes HTTP |
| GenServer ↔ Snap.Cluster | `Snap.Document.index/6` or `Snap.Bulk.perform/4` | None | HTTP; confirmed on `{:ok, _}` response |
| GenServer ↔ Checkpoint | `Checkpoint.upsert/3` | Postgres single-row upsert | Post-ES-write; at-least-once |
| GenServer ↔ DeadLetter | `Ecto.Multi` halt transaction (existing) | Postgres transaction | Unchanged from Postgres adapter |
| ES projector ↔ Snap.Cluster | Config injection via `:cluster` | N/A | Shared across projectors; started separately in supervision tree |
| ES projector ↔ Checkpoint Repo | Config injection via `:checkpoint_repo` | Postgres | Separate from ES; can be app's existing Repo |

---

## Sources

- [snap v0.16.0 hexdocs — Snap.Indexes](https://snap.hexdocs.pm/Snap.Indexes.html) — `create/4`, `alias/4`, `hotswap/5` signatures — MEDIUM confidence
- [snap v0.16.0 hexdocs — Snap.Bulk](https://snap.hexdocs.pm/Snap.Bulk.html) — `perform/4`, page_size, page_wait — MEDIUM confidence
- [snap v0.16.0 hexdocs — Snap.Document](https://snap.hexdocs.pm/Snap.Document.html) — `index/6`, `update/6`, `delete/5` — MEDIUM confidence
- [snap v0.16.0 hexdocs — Snap.Cluster](https://snap.hexdocs.pm/Snap.Cluster.html) — supervision, `use Snap.Cluster`, HTTP delegates — MEDIUM confidence
- [GitHub breakroom/snap](https://github.com/breakroom/snap) — Finch-backed HTTP pool, zero-downtime hotswap — MEDIUM confidence
- [Elasticsearch Optimistic Concurrency Control (Elastic docs)](https://www.elastic.co/docs/reference/elasticsearch/rest-apis/optimistic-concurrency-control) — `_seq_no`, external versioning, idempotent writes — HIGH confidence
- [Zero Downtime Reindex (Elastic blog)](https://www.elastic.co/blog/changing-mapping-with-zero-downtime) — alias swap pattern for zero-downtime reindex — MEDIUM confidence
- [Domaincentric.net — Deduplication strategies for ES read models](https://domaincentric.net/blog/event-sourcing-projection-patterns-deduplication-strategies) — external versioning for idempotency — LOW confidence (single source)
- Orkestra v1.0 codebase — existing Storage behaviour, GenServer state machine, Checkpoint/DeadLetter schemas — HIGH confidence (direct read)

---
*Architecture research for: Orkestra v1.1 Elasticsearch/OpenSearch projection adapter*
*Researched: 2026-06-25*
