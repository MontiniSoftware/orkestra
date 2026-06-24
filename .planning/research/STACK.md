# Stack Research

**Domain:** Elixir CQRS/ES — event-sourced projection / read-model subsystem
**Researched:** 2026-06-24
**Confidence:** MEDIUM (verified against hex.pm, hexdocs, and GitHub; versions confirmed current as of June 2026)

---

## Context

Orkestra already ships: Elixir 1.18+, Phoenix.PubSub 2.2, Jason 1.4.4, OpenTelemetry API 1.5, AMQP 4.1.0 (optional), Spear 1.4.1 (optional). This research covers only what is ADDED for the projection subsystem. Do not re-add or duplicate existing deps.

---

## Recommended Stack

### Core Technologies (projection subsystem)

| Technology | Version | Purpose | Why Recommended |
|------------|---------|---------|-----------------|
| ecto | ~> 3.14 | Schema definition, query API, changeset validation | Current stable (3.14.0, May 2026). The Elixir standard for relational DB access. Provides the schema/changeset layer that developers use to define and query read models. |
| ecto_sql | ~> 3.14 | SQL adapter layer + Ecto.Migrator for programmatic migrations | Separate from ecto core; required for SQL databases and migrations. 3.14.0 released same day as ecto 3.14. Provides `Ecto.Migrator.run/4` for runtime migration execution — critical for per-projection isolated migration runs. |
| postgrex | ~> 0.22 | PostgreSQL wire-protocol driver | Current stable (0.22.2, May 2026). Used transparently by ecto_sql — consumers rarely call it directly. Must be declared in mix.exs alongside ecto_sql. |

### Optional Adapters (follow-on milestones — not this milestone)

| Technology | Version | Purpose | Why Recommended |
|------------|---------|---------|-----------------|
| mongodb_driver | ~> 1.5 | MongoDB read-model writes and queries | v1.6.3 (May 2026), actively maintained. Modern, DBConnection-backed pooling. The correct package — do NOT use the legacy `mongodb` hex package which is unmaintained. API: `Mongo.insert_one/3`, `Mongo.find/3` (returns Enumerable stream), `Mongo.update_one/4`. |
| snap | ~> 0.16 | Elasticsearch / OpenSearch indexing and search | v0.16.0 (May 2026), actively maintained. Provides versioned index management with zero-downtime alias swap, streaming bulk operations, Telemetry events, Snap.Cluster supervision tree. Requires Elixir 1.16+. The clear 2026 choice. |

### Supporting Libraries

| Library | Version | Purpose | When to Use |
|---------|---------|---------|-------------|
| db_connection | ~> 2.7 | Connection pooling primitives | Pulled transitively by postgrex and mongodb_driver. Explicit pin only if conflict resolution is needed. |

---

## How Commanded Structures Projections (reference pattern)

Commanded + commanded_ecto_projections is the most widely-referenced Elixir CQRS projection stack. Orkestra does NOT use Commanded, but these design decisions are the community consensus and should directly inform Orkestra's design.

### commanded_ecto_projections v1.4.0

**Projection DSL** — a `project/2,3` macro appends operations to an `Ecto.Multi` struct:

```elixir
defmodule MyProjector do
  use Commanded.Projections.Ecto,
    application: MyApp,
    repo: MyApp.Repo,
    name: "MyProjector"

  project %OrderPlaced{order_id: id, total: total}, fn multi ->
    Ecto.Multi.insert(multi, :order_summary, %OrderSummary{
      order_id: id,
      total: total
    })
  end
end
```

All operations in one `project` clause execute in a single DB transaction.

**Checkpoint persistence** — a `projection_versions` table is the standard:

```sql
CREATE TABLE projection_versions (
  projection_name TEXT PRIMARY KEY,
  last_seen_event_number BIGINT,
  inserted_at TIMESTAMP,
  updated_at TIMESTAMP
);
```

- `projection_name` is the unique projector name (e.g., `"MyProjector"`).
- `last_seen_event_number` is the global event store sequence number of the last successfully processed event.
- The checkpoint is written atomically in the same `Ecto.Multi` transaction as the read-model update — so a crash between events never leaves a partial state without a matching checkpoint advance.
- On restart, the projector reads its checkpoint and tells the event store to replay from `last_seen_event_number + 1`.

**Error handling** — `error/3` callback with four responses:
- `{:retry, context}` — retry immediately
- `{:retry, delay_ms, context}` — retry after delay
- `:skip` — acknowledge and skip the failed event
- `{:stop, reason}` — halt the handler

**Rebuild** — projectors expose a `reset/0` that clears the projection_versions row and signals the event store subscription to replay from `:origin`.

**Schema prefix** — `schema_prefix/1` or `schema_prefix/2` callback allows storing `projection_versions` (and the read model tables) in a separate Postgres schema — useful for tenant isolation.

**Commanded.Event.Handler subscription options** (relevant pattern for Orkestra):
- `start_from: :origin` — replay all historical events (rebuild)
- `start_from: :current` — subscribe from this moment forward
- `start_from: <event_number>` — resume from a specific position

**Key insight for Orkestra**: Commanded stores the subscription position inside the event store itself (EventStore library maintains it); `commanded_ecto_projections` additionally writes `last_seen_event_number` to the read DB. Orkestra should store the checkpoint in a dedicated table within the projector's own Ecto repo so that dropping/rebuilding the read model also resets the checkpoint automatically.

---

## Optional Dependency Pattern

Orkestra's existing pattern (used for `:amqp` and `:spear`) must be replicated exactly for Ecto:

**In `mix.exs`:**

```elixir
defp deps do
  [
    # existing deps...

    # Projection adapter: PostgreSQL (optional)
    {:ecto,         "~> 3.14", optional: true},
    {:ecto_sql,     "~> 3.14", optional: true},
    {:postgrex,     "~> 0.22", optional: true},

    # Projection adapter: MongoDB (optional, future milestone)
    {:mongodb_driver, "~> 1.5", optional: true},

    # Projection adapter: Elasticsearch (optional, future milestone)
    {:snap, "~> 0.16", optional: true},
  ]
end
```

**In adapter module — compile-time guard:**

```elixir
if Code.ensure_loaded?(Ecto) do
  defmodule Orkestra.Projection.Adapters.Ecto do
    @behaviour Orkestra.Projection.Adapter
    # ...
  end
end
```

**Consumer app's mix.exs** must add the concrete deps explicitly (Orkestra does not pull them in automatically):

```elixir
{:orkestra, "~> 0.2"},
{:ecto_sql, "~> 3.14"},
{:postgrex, "~> 0.22"},
```

---

## Per-Projection Migration Isolation

This is a key requirement: each projection owns its tables and migration history independently.

**Mechanism** — one Ecto.Repo per projection (or shared read-model repo with isolated priv directory per projector module):

```elixir
defmodule MyApp.Projections.OrderSummaryRepo do
  use Ecto.Repo,
    otp_app: :my_app,
    adapter: Ecto.Adapters.Postgres
end
```

```elixir
# config/config.exs
config :my_app, MyApp.Projections.OrderSummaryRepo,
  database: "my_app_read",
  hostname: "localhost",
  priv: "priv/order_summary_repo"    # <-- isolated migrations directory
```

Each projection's migrations live in `priv/<repo_name>/migrations/`. They are completely independent — `mix ecto.migrate --repo MyApp.Projections.OrderSummaryRepo` migrates only that projection, and `Ecto.Migrator.run/4` can be called at projector startup to auto-migrate.

**Alternative** — single shared read-model repo with a custom schema prefix per projection (Postgres schemas). Simpler operationally but less isolated. Commanded_ecto_projections uses this approach via `schema_prefix`. Orkestra should offer both but default to separate repos for full isolation.

---

## Checkpoint Table Design (Orkestra)

Recommend a `projection_checkpoints` table (not reusing `projection_versions` to avoid confusion with Commanded) owned by each projector's repo:

```elixir
defmodule Orkestra.Projection.Adapters.Ecto.Migrations.CreateCheckpoints do
  use Ecto.Migration

  def change do
    create table(:projection_checkpoints, primary_key: false) do
      add :projection_name, :text, primary_key: true
      add :last_seen_position, :bigint, null: false, default: 0
      add :rebuilt_at, :utc_datetime
      timestamps(type: :utc_datetime_usec)
    end
  end
end
```

- `last_seen_position` is the event store global sequence number (maps to Spear's `revision` or InMemory's position).
- Written atomically with the read-model row in the same `Ecto.Multi` transaction.
- Dropping and recreating a projection also drops the checkpoints table, so rebuild is fully clean.

---

## Alternatives Considered

| Recommended | Alternative | Why Not |
|-------------|-------------|---------|
| ecto + ecto_sql | Raw Postgrex | No migration system, no DSL, no changeset validation. Ecto is the standard. |
| ecto_sql ~> 3.14 | pinning 3.11 | 3.11 is what commanded_ecto_projections requires as minimum; 3.14 is current and compatible. Use latest. |
| snap ~> 0.16 | elastix ~> 0.10 | elastix was last updated May 2021 — abandoned. Snap is actively maintained with zero-downtime reindex support built-in. |
| snap ~> 0.16 | elasticsearch-elixir | Less maintained than snap; no versioned index management. |
| mongodb_driver ~> 1.5 | mongodb (legacy) | The legacy `mongodb` hex package is unmaintained. `mongodb_driver` is the community-maintained successor. |
| separate Ecto.Repo per projection | Single shared app Repo | A shared Repo makes projections dependent on the consuming app's migration history. Separate repos provide the isolation required by the "independently migratable / droppable / rebuildable" requirement. |

---

## What NOT to Use

| Avoid | Why | Use Instead |
|-------|-----|-------------|
| elastix | Last updated 2021, effectively abandoned | snap ~> 0.16 |
| mongodb (hex package) | Unmaintained legacy package | mongodb_driver ~> 1.5 |
| commanded or commanded_ecto_projections | Orkestra is not a Commanded application; adding Commanded would bring a competing CQRS framework as a dep. Only the patterns are borrowed, not the code. | Orkestra's own projection behaviour + adapter |
| Synchronous / inline projection writes | Violates the write-read separation design decision; rejected in PROJECT.md | Async via message bus + replay |
| Single migration directory shared with app | Prevents per-projection independent migrations/rollbacks | Per-projection :priv directory or schema prefix |

---

## Version Compatibility

| Package | Compatible With | Notes |
|---------|-----------------|-------|
| ecto ~> 3.14 | ecto_sql ~> 3.14 | Must match major.minor |
| ecto_sql ~> 3.14 | postgrex ~> 0.22 | ecto_sql selects postgrex automatically; pin for reproducibility |
| snap ~> 0.16 | Elixir ~> 1.16 | Requires Elixir 1.16+; Orkestra requires 1.18+, so no conflict |
| mongodb_driver ~> 1.5 | MongoDB 4.x–8.x | Broad server compatibility |
| Orkestra ~> 0.1 | Elixir ~> 1.18 | All above packages are compatible |

---

## Installation (for consuming app, PostgreSQL adapter)

```elixir
# mix.exs — consuming application
defp deps do
  [
    {:orkestra, "~> 0.2"},
    {:ecto_sql, "~> 3.14"},
    {:postgrex, "~> 0.22"},
  ]
end
```

```elixir
# mix.exs — Orkestra library itself
defp deps do
  [
    # existing...
    {:ecto,         "~> 3.14", optional: true},
    {:ecto_sql,     "~> 3.14", optional: true},
    {:postgrex,     "~> 0.22", optional: true},
    {:mongodb_driver, "~> 1.5", optional: true},
    {:snap,         "~> 0.16", optional: true},
  ]
end
```

---

## Sources

- [Ecto v3.14.0 — Ecto.Repo (hexdocs)](https://ecto.hexdocs.pm/Ecto.Repo.html) — multiple repo config, :priv option — MEDIUM confidence
- [hex.pm/packages/ecto](https://hex.pm/packages/ecto) — version 3.14.0, May 2026 — MEDIUM confidence
- [hex.pm/packages/ecto_sql](https://hex.pm/packages/ecto_sql) — version 3.14.0, May 2026 — MEDIUM confidence
- [hex.pm/packages/postgrex](https://hex.pm/packages/postgrex) — version 0.22.2, May 2026 — MEDIUM confidence
- [commanded_ecto_projections mix.exs (GitHub)](https://github.com/commanded/commanded-ecto-projections/blob/master/mix.exs) — dep constraints, version 1.4.0 — MEDIUM confidence
- [Commanded.Projections.Ecto (hexdocs)](https://commanded-ecto-projections.hexdocs.pm/Commanded.Projections.Ecto.html) — project macro, Ecto.Multi, projection_versions table — MEDIUM confidence
- [Commanded.Event.Handler v1.4.10 (hexdocs)](https://commanded.hexdocs.pm/Commanded.Event.Handler.html) — start_from, error/3, before_reset, lifecycle — MEDIUM confidence
- [hex.pm/packages/commanded](https://hex.pm/packages/commanded) — version 1.4.10, May 2026 — MEDIUM confidence
- [mongodb-driver hexdocs readme](https://mongodb-driver.hexdocs.pm/readme.html) — version 1.6.3, API surface — MEDIUM confidence
- [hex.pm/packages/snap](https://hex.pm/packages/snap) — version 0.16.0, May 2026, actively maintained — MEDIUM confidence
- [snap hexdocs readme](https://snap.hexdocs.pm/readme.html) — features, zero-downtime alias swap, bulk — MEDIUM confidence
- [hex.pm/packages/elastix](https://hex.pm/packages/elastix) — version 0.10.0, last updated May 2021 (abandoned) — MEDIUM confidence
- Community pattern: projection_versions checkpoint schema — confirmed via commanded-ecto-projections source and Elixir forum discussions — MEDIUM confidence

---

*Stack research for: Orkestra event-sourced projection / read-model subsystem*
*Researched: 2026-06-24*
