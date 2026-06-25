# Feature Research — ES/OpenSearch Projection Adapter

**Domain:** Elasticsearch / OpenSearch storage adapter for Orkestra's projection subsystem
**Researched:** 2026-06-25
**Confidence:** MEDIUM-HIGH (Snap API verified via hexdocs; ES/OpenSearch Bulk API verified via official docs; query DSL patterns cross-verified against Python elasticsearch-dsl, Ruby elasticsearch-dsl, and ExlasticSearch for Elixir)

---

## Scope Note

This document covers only the **new features** required for the v1.1 milestone: an
Elasticsearch/OpenSearch storage adapter on top of the already-shipped projection
subsystem (v1.0). All v1.0 table-stakes (projector DSL, checkpointing, lifecycle, retry/halt,
OTel, Mix tasks, MCP generators) are already built and are **dependencies**, not features to
build here. References to them appear only to clarify interface contracts.

---

## What the ES Adapter Must Plug Into

The existing `Orkestra.Projection.Storage` behaviour requires two callbacks:

```elixir
@callback write(projector_name(), event(), non_neg_integer(), opts()) ::
            {:ok, ops()} | {:error, term()}

@callback reset(projector_name(), opts()) :: :ok | {:error, term()}
```

The Postgres adapter returns an `Ecto.Multi.t()` from `write/4` — a composable descriptor that
the projector GenServer merges with the checkpoint upsert before committing. The ES adapter
**cannot** use the same pattern because ES has no multi-table transactions. Its `write/4`
must return an ES-specific descriptor that the projector commits, then the checkpoint is
written separately (post-confirmation, same at-least-once semantics as Mongo). The existing
architecture doc (ARCHITECTURE.md, Pattern 2) already anticipated this: "ES adapter (post-write):
1. HTTP index call 2. Checkpoint.upsert."

---

## Table Stakes

Features users expect. Missing any of these = the adapter is not usable as a projection backend.

| Feature | Why Expected | Complexity | Notes |
|---------|--------------|------------|-------|
| **`Storage` behaviour implementation** | The projector GenServer calls `write/4` and `reset/2` on whatever adapter is configured. ES adapter must implement these two callbacks to plug into the existing lifecycle without modification. | LOW | `Orkestra.Projection.Storage.Elasticsearch` (or `Storage.ES`) implements `write/4` and `reset/2`. Guard with `Code.ensure_loaded?(Snap.Cluster)`. `write/4` returns an ES-specific descriptor (index name + document map). `reset/2` deletes all documents by projector name or deletes + recreates the index. |
| **Snap cluster integration** | Snap is the selected ES/OpenSearch client (STACK.md). The adapter needs a configured `Snap.Cluster` module to make HTTP calls. | LOW | Consumer configures `MyApp.Cluster` via `use Snap.Cluster, otp_app: :my_app`. Adapter accepts `:cluster` and `:index` opts in `write/4` opts. Snap manages connection pooling and authentication transparently. |
| **Single-document index on live events** | During live (caught-up) mode the projector processes one event at a time. Each call to `write/4` must result in exactly one ES index/upsert operation per document. Batching here is incorrect — it would delay visibility and complicate retry semantics. | LOW | Call `Snap.Document.index/5` or `Snap.Document.create/5` per event. Return `{:ok, ops}` where `ops` is the ES write descriptor. On HTTP error, return `{:error, reason}` so the projector lifecycle triggers retry. |
| **Index existence check on projector start** | If the target ES index does not exist when the projector starts, the first `write/4` call will return a 404. The projector must either create the index (with mapping) or fail with a clear error before processing any events. | LOW | Add a `setup/1` step (or enforce via adapter `init`): call `Snap.Indexes.create/4` with the `index_mapping/0` callback result if the index does not exist yet. Log a clear error if creation fails. |
| **`index_mapping/0` callback on projector** | ES index mappings must be defined before indexing documents — auto-mapping produces wrong field types (e.g., text where keyword is needed, long where boolean is needed). Without an explicit mapping callback, developers have no way to declare field types, analyzers, or dynamic settings. | MEDIUM | Add `@callback index_mapping() :: map()` to `Orkestra.Projector`. ES projectors implement this to return the ES `mappings` object. The adapter uses it at index creation time and during versioned rebuild. Non-ES projectors use `@optional_callbacks`. |
| **Document ID strategy** | ES requires a document ID for upserts. Without an explicit ID strategy, every write creates a new document instead of updating the existing one, causing unbounded index growth and incorrect read-model state. | LOW | Add `@callback document_id(event :: map()) :: String.t()` as an optional callback on `Orkestra.Projector` (or on the ES adapter module). Default: derive from event's aggregate ID or stream ID. Allow override per projector. |
| **Post-write checkpoint advance** | ES has no transactions. After a successful `write/4`, the projector GenServer must write the checkpoint separately. The existing architecture already handles this (at-least-once semantics, same as Mongo). Handlers must be idempotent. | LOW | No new code needed in the adapter itself — the projector GenServer already handles post-write checkpoint for non-Ecto adapters. Adapter `write/4` just returns `:ok` after confirming the ES HTTP call. Document that ES handlers must be idempotent (e.g., upsert by document ID rather than insert). |

---

## Differentiators

Features that make the ES adapter meaningfully better than a manual Snap integration, and that no existing Elixir CQRS library ships.

| Feature | Value Proposition | Complexity | Notes |
|---------|-------------------|------------|-------|
| **Zero-downtime rebuild via alias swap (hotswap)** | Rebuilding an ES index naively requires deleting the current index (making it unavailable during replay), replaying all events, then recreating. With an alias swap, the old index remains live for reads while a new versioned index is built in the background; the alias is switched atomically when the new index is fully caught up. No downtime, no read gaps. `Snap.Indexes.hotswap/5` implements exactly this. | HIGH | During rebuild: (1) create new versioned index (e.g., `orders_v2_20260625`), (2) replay all events into the new index via `Snap.Bulk` stream, (3) call `Snap.Indexes.alias/4` to atomically redirect the alias. Projectors in normal mode point to the alias, not the versioned index. See `Snap.Indexes.hotswap/5` — it takes an `Enumerable` of `Snap.Bulk.Action.*` structs, creates/loads/refreshes/aliases atomically. |
| **Automatic batch indexing during catch-up / rebuild** | Projecting events one-at-a-time into ES during catch-up or rebuild is 10–100x slower than bulk. At 5,000 events/batch (Snap.Bulk default) with 100K events, the difference is seconds vs minutes. Without batching, large event stores make ES projectors impractical to rebuild. | MEDIUM | During catch-up/rebuild mode: buffer events into a batch of configurable size (default 500, configurable via `batch_size` opt). Flush via `Snap.Bulk.perform/4` when batch is full or on a time deadline. Switch to single-document mode once caught up with live stream. The projector GenServer must expose a `mode` field (`:catching_up` vs `:live`) that the adapter checks to decide batch vs single write. |
| **Versioned index naming** | Without versioned index names, a rebuild requires deleting the live index — there is no way to build the new version alongside the old one. Versioned names (e.g., `orders_v2_20260625T120000`) enable blue-green rebuild: create new, fill it, swap alias, drop old. They also make it trivial to roll back to the previous index version if the new mapping has a bug. | LOW | Naming convention: `{base_index_name}_{YYYYMMDDTHHMMSS}`. `Snap.Indexes.list_starting_with/3` lists all versioned indexes for a prefix. `Snap.Indexes.cleanup/4` deletes old ones (preserves last N, default 2). The adapter wraps these in `Orkestra.Projection.ES.Index.create_versioned/2` and `cleanup/2`. |
| **Elixir query DSL for ES queries** | Reading from an ES-backed projection requires composing ES Query DSL JSON. Without a helper DSL, developers must write nested maps by hand — verbose, error-prone, and not idiomatic Elixir. A pipe-based builder that produces the ES JSON structure makes ES-backed queries as ergonomic as Ecto queries. | HIGH | `Orkestra.Projection.ES.Query` module: builder functions returning maps that compose via `|>`. Pattern: `search() |> must(match(:title, "foo")) |> filter(term(:status, :active)) |> aggs(:count, terms(:category)) |> to_query()`. Produces `%{"query" => %{"bool" => %{"must" => [...], "filter" => [...]}}, "aggs" => {...}}`. No new deps — pure Elixir map manipulation. See Python elasticsearch-dsl and ExlasticSearch for Elixir (pipe-pattern) as design references. |
| **Optional `Queries` module for ES projections** | Mirrors the existing Ecto `Queries` module (v1.0 feature). ES-specific `list/1` and `search/1` helpers that emit OTel spans and wrap the query DSL. Removes boilerplate common ES queries. | MEDIUM | `use Orkestra.Projection.ES.Queries, cluster: MyApp.Cluster, index: "orders"` generates `search(query_map)`, `get(id)`, `list(opts)` as thin wrappers over `Snap.Search.search/4`. Consistent with the Ecto Queries generator in approach. |
| **MCP generators for ES projections** | Consistent with existing `gen_projection` (already shipped for Ecto). An ES-specific variant would generate: projector module with `index_mapping/0`, `document_id/1`, `project/2` callbacks; Snap cluster config; optional `Queries` module; and a test stub using Snap's Mox-based mock adapter. | MEDIUM | New MCP tool `gen_es_projection` or ES-mode flag on `gen_projection`. Generates conforming module structure. Lower priority than the core adapter. |

---

## Anti-Features

Features that seem like obvious additions but create correctness, complexity, or semantic mismatch problems. Explicitly do not build these.

| Anti-Feature | Why Requested | Why Problematic | What to Do Instead |
|--------------|---------------|-----------------|-------------------|
| **Transactional checkpoint co-write with ES** | "I want the same atomicity guarantee as the Ecto adapter." | ES HTTP API has no transactions. An ES index call and a Postgres checkpoint write cannot be atomic. Attempting to fake this (e.g., using XA transactions or two-phase commit) adds enormous complexity with no guarantee — ES and Postgres are separate systems. | Accept at-least-once semantics: write to ES, confirm success, then write checkpoint. All ES `project/2` handlers must be idempotent (upsert by document ID, not insert). Document this clearly. |
| **Uniform cross-backend query API (Ecto + ES under one interface)** | "I want to query both SQL and ES projections the same way." | ES queries (full-text, scoring, aggregations) have fundamentally different semantics from SQL. A least-common-denominator API hides ES's key strengths (scoring, suggest, aggs) and SQL's key strengths (JOINs, window functions). Both become worse. | Provide idiomatic, adapter-specific query helpers. The ES `Queries` module uses ES query DSL. The Ecto `Queries` module uses Ecto.Query. Developers choose the right backend for the query. |
| **ES as a primary event store (appending events to ES)** | "ES has full-text, so why not store events there too?" | ES is not designed as a primary event store: no strict ordering guarantee, no optimistic concurrency, no server-side event stream semantics, expensive to scan sequentially. The existing EventStoreDB and InMemory adapters are the write side. | ES is a read-model store only. Events flow: EventStore → Projector → ES index. Never from ES back to the write side. |
| **Per-document ES checkpoint tracking** | "Track a checkpoint field on every document so I know which position each document is at." | Adds a hidden field to every document that leaks infrastructure state into the read model schema. Queries must filter it out. The checkpoint (projector-level, not document-level) belongs in the existing `projection_checkpoints` table. | Use the existing Postgres-backed `projection_checkpoints` table for the projector-level position. The ES index contains only domain read-model fields. |
| **`dynamic: true` mapping (auto-mapping)** | "Let ES infer the mapping, less configuration." | ES will guess field types from the first document it sees. `text` vs `keyword`, `long` vs `boolean`, nested vs object — wrong defaults are impossible to fix without a full reindex. Auto-mapping is a footgun in production. | Require `index_mapping/0` callback. Use `dynamic: "strict"` in the mapping to fail loudly on unexpected fields rather than silently creating wrong-type fields. |
| **Synchronous alias swap during a live projector** | "I want to do a schema migration without stopping the projector." | If the alias swap happens while the live projector is writing to the old versioned index (pre-alias pointing), documents written after the swap go to the old (now unaliased) index and are lost. | Use the hotswap/rebuild flow: stop or shadow the live projector, replay into the new index, swap alias, then start the live projector against the new index. The hotswap must happen during a full rebuild cycle, not inline. |

---

## Feature Dependencies

```
[ES Storage.write/4 (single-doc live mode)]
    └──requires──> [Snap cluster integration]
    └──requires──> [document_id/1 callback]
    └──requires──> [index_mapping/0 callback]  (index must exist before write)
    └──plugs into──> [Orkestra.Projection.Storage behaviour]  (existing)

[ES Storage.reset/2 (rebuild prep)]
    └──requires──> [Snap cluster integration]
    └──enables──>  [Zero-downtime rebuild via alias swap]

[Batch indexing during catch-up/rebuild]
    └──requires──> [ES Storage.write/4 (single-doc live mode)]
    └──requires──> [Snap.Bulk.perform/4]  (Snap built-in)
    └──requires──> [Projector GenServer mode flag (:catching_up vs :live)]  (existing lifecycle)
    └──enables──>  [Zero-downtime rebuild via alias swap]  (hotswap uses a Bulk stream)

[Zero-downtime rebuild via alias swap]
    └──requires──> [Batch indexing during catch-up/rebuild]
    └──requires──> [Versioned index naming]
    └──requires──> [Snap.Indexes.hotswap/5]  (Snap built-in)
    └──requires──> [Full rebuild / replay]  (existing, v1.0)
    └──requires──> [index_mapping/0 callback]

[Versioned index naming]
    └──requires──> [Snap.Indexes.list_starting_with/3]  (Snap built-in)
    └──requires──> [Snap.Indexes.cleanup/4]  (Snap built-in)
    └──enables──>  [Zero-downtime rebuild via alias swap]

[Elixir query DSL for ES queries]
    └──requires──> [Snap.Search.search/4]  (Snap built-in)
    └──independent of──> write-path features (query-only, no write coupling)

[Optional ES Queries module]
    └──requires──> [Elixir query DSL for ES queries]
    └──requires──> [Snap cluster integration]

[MCP gen_es_projection]
    └──requires──> [ES Storage.write/4]
    └──requires──> [index_mapping/0 callback]
    └──enhances──> [Optional ES Queries module]
```

### Critical Dependency: Projector Mode Flag

The batch indexing feature requires the projector GenServer to expose whether it is in
`:catching_up` or `:live` mode. The existing v1.0 projector lifecycle already tracks
`:status` (`:starting`, `:catching_up`, `:running`). The ES adapter must be able to inspect
this mode to decide between buffered bulk writes and single-document writes. This is the
key integration point between the new adapter and the existing lifecycle code.

### Checkpoint Semantics Difference (No Ecto.Multi)

The Ecto adapter returns an `Ecto.Multi.t()` from `write/4` that includes the checkpoint
upsert — atomic in one transaction. The ES adapter cannot do this. Two options:

1. **`write/4` returns `{:ok, :applied}` after completing the ES HTTP call.** The projector
   GenServer then calls `Checkpoint.upsert/3` separately. This is the pattern already
   documented in ARCHITECTURE.md and requires no change to the projector GenServer.

2. **`write/4` returns an ES write descriptor without committing.** The GenServer commits and
   then writes the checkpoint. This option reduces coupling but requires the GenServer to know
   how to commit an ES descriptor.

Option 1 is simpler and matches existing documentation. The projector GenServer already has
conditional logic for adapter type (Ecto uses `Ecto.Multi`, others do post-write checkpoint).

---

## MVP Definition for v1.1 ES Adapter

### Must Have (Core adapter — enables any ES projection)

- `Orkestra.Projection.Storage.Elasticsearch` implementing `write/4` (single-doc upsert) and `reset/2` (delete-all or drop+recreate)
- `index_mapping/0` optional callback added to `Orkestra.Projector` behaviour
- `document_id/1` optional callback added to `Orkestra.Projector` behaviour (default from event aggregate ID)
- Index existence check + creation on projector start (using `Snap.Indexes.create/4`)
- Versioned index naming convention (`base_YYYYMMDDTHHMMSS`)
- `Snap` added as optional dep in `mix.exs` (same pattern as `:amqp`, `:spear`)

### Should Have (Makes the adapter production-ready)

- Batch indexing during catch-up/rebuild via `Snap.Bulk.perform/4` (configurable `batch_size`, default 500)
- Zero-downtime rebuild via `Snap.Indexes.hotswap/5` wrapping the replay stream
- `Snap.Indexes.cleanup/4` integration to drop old versioned indexes after alias swap
- OTel spans for: single-doc write, bulk flush, alias swap, cleanup (consistent with existing Telemetry module)

### Nice to Have (Developer ergonomics — add after core is proven)

- `Orkestra.Projection.ES.Query` — pipe-based query DSL builder producing ES Query DSL maps
- Optional `ES.Queries` module (`search/1`, `get/1`, `list/1`)
- MCP `gen_es_projection` generator
- Mix task `mix orkestra.projection.es.rebuild ProjectorName` that triggers hotswap rebuild

---

## Feature Prioritization Matrix

| Feature | User Value | Cost | Priority |
|---------|------------|------|----------|
| `Storage` behaviour implementation (write/4, reset/2) | HIGH | LOW | P1 |
| `index_mapping/0` + `document_id/1` callbacks | HIGH | LOW | P1 |
| Index existence check on start | HIGH | LOW | P1 |
| Versioned index naming | HIGH | LOW | P1 |
| Snap optional dep wiring | HIGH | LOW | P1 |
| Batch indexing during catch-up | HIGH | MEDIUM | P1 |
| Zero-downtime alias swap rebuild | HIGH | HIGH | P1 |
| OTel spans for ES operations | MEDIUM | LOW | P1 |
| ES query DSL builder | MEDIUM | HIGH | P2 |
| Optional ES Queries module | MEDIUM | MEDIUM | P2 |
| Mix task `es.rebuild` | MEDIUM | LOW | P2 |
| MCP `gen_es_projection` | LOW | MEDIUM | P3 |

**Priority key:**
- P1: Required for v1.1 milestone launch
- P2: Should have; add before calling v1.1 complete if time allows
- P3: Defer to v1.2 or standalone PR after v1.1

---

## Technical Reference: Snap API Surface (Verified HIGH confidence)

### Bulk Operations (`Snap.Bulk`)

```elixir
# perform/4 signature
Snap.Bulk.perform(stream :: Enumerable.t(), cluster :: module(), index :: String.t(), opts :: keyword())
# Returns: :ok | {:error, Snap.BulkError.t()}

# Action types (all implement Snap.Bulk.Action protocol)
%Snap.Bulk.Action.Index{id: "doc-id", doc: %{field: "value"}}    # create or replace
%Snap.Bulk.Action.Create{id: "doc-id", doc: %{field: "value"}}   # create only (fails if exists)
%Snap.Bulk.Action.Update{id: "doc-id", doc: %{field: "value"}}   # partial update
%Snap.Bulk.Action.Delete{id: "doc-id"}                            # delete

# Key opts
# page_size: 5_000 (default) — actions per batch
# page_wait: 15_000 (default) — ms between batches
# max_errors: nil (default, run to completion)
```

For Orkestra's ES adapter, use a smaller `page_size` (e.g., 500) and set `page_wait: 0`
during bulk replay to maximize throughput. The Snap default of 5,000 is generous; 500 is
safer for document-heavy projections.

### Index / Alias Management (`Snap.Indexes`)

```elixir
# Zero-downtime hotswap
Snap.Indexes.hotswap(stream, cluster, alias_name, mapping, opts)
# Takes: Enumerable of Snap.Bulk.Action structs
# Does: create versioned index → bulk load → refresh → alias swap → cleanup old indexes
# Returns: :ok | Snap.Cluster.error() | {:error, Snap.BulkError.t()}

# Alias management
Snap.Indexes.alias(cluster, versioned_index_name, alias_name, opts)
# Creates alias, removing any existing aliases on other indexes for that alias name

# Versioned index listing
Snap.Indexes.list_starting_with(cluster, prefix, opts)
# Returns: {:ok, [String.t()]} — all indexes whose name starts with prefix

# Cleanup old versioned indexes
Snap.Indexes.cleanup(cluster, alias_name, preserve :: non_neg_integer(), opts)
# Deletes all but the most recent `preserve` (default 2) versioned indexes

# Create index with explicit mapping
Snap.Indexes.create(cluster, index_name, mapping, opts)
# mapping is %{"mappings" => %{"dynamic" => "strict", "properties" => %{...}}}
```

### Single-Document Operations (`Snap.Document`)

```elixir
# Index (create or replace)
Snap.Document.index(cluster, index, type \\ nil, id, body, opts)

# Get
Snap.Document.get(cluster, index, type \\ nil, id, opts)
```

### Search (`Snap.Search`)

```elixir
Snap.Search.search(cluster, index, query_map, opts)
# query_map is a plain Elixir map matching ES Query DSL structure
# Returns: {:ok, response_map} | {:error, reason}
```

---

## ES Query DSL Design Reference

The proposed `Orkestra.Projection.ES.Query` module should follow the pipe-pattern established
by ExlasticSearch (the most Elixir-idiomatic existing library) and the immutable-builder
pattern from Python elasticsearch-dsl. No external dep required — pure Elixir map building.

Proposed API sketch (not authoritative, for roadmap scoping only):

```elixir
# Builder pattern (pipe-based, idiomatic Elixir)
import Orkestra.Projection.ES.Query

result =
  search()
  |> must(match(:title, "elixir"))
  |> must(term(:status, :active))
  |> filter(range(:inserted_at, gte: ~D[2026-01-01]))
  |> aggs(:by_status, terms(:status))
  |> size(20)
  |> from(0)
  |> to_query()

# Produces:
# %{
#   "query" => %{
#     "bool" => %{
#       "must" => [
#         %{"match" => %{"title" => "elixir"}},
#         %{"term" => %{"status" => "active"}}
#       ],
#       "filter" => [%{"range" => %{"inserted_at" => %{"gte" => "2026-01-01"}}}]
#     }
#   },
#   "aggs" => %{"by_status" => %{"terms" => %{"field" => "status"}}},
#   "size" => 20,
#   "from" => 0
# }

# Then execute via Snap
Snap.Search.search(MyApp.Cluster, "orders", result)
```

---

## ES/OpenSearch Compatibility Notes (MEDIUM confidence)

Snap explicitly claims ES and OpenSearch support. The key compatibility constraints:

- **ES 8.x vs OpenSearch 2.x+:** Both removed mapping types (typeless). The adapter should
  never include a `_type` field. Use `PUT /{index}/_doc/{id}` not `PUT /{index}/{type}/{id}`.
- **Security APIs differ:** Orkestra does not call security APIs. Snap authentication is
  header-based (Basic Auth), which works identically on both.
- **Index template API:** Snap uses `_index_template` (composable, ES 7.8+/OS 1.x+). Not a
  concern for the Orkestra adapter which manages indexes directly, not via templates.
- **OpenSearch 2.x** is compatible with the ES 7.10 API surface that Snap targets. No known
  incompatibilities for the operations Orkestra needs (index create, bulk, alias, search).
- **AWS OpenSearch Service:** Uses HTTP(S) with SigV4 auth. Snap's `Snap.Auth` is pluggable;
  an SigV4 auth module would be needed for AWS deployments. Out of scope for v1.1 but the
  pluggable auth design accommodates it.

---

## Sources

- [Snap v0.16.0 Hexdocs — Snap.Indexes](https://snap.hexdocs.pm/Snap.Indexes.html) — hotswap, alias, versioned index, cleanup — HIGH confidence
- [Snap v0.16.0 Hexdocs — Snap.Bulk](https://snap.hexdocs.pm/Snap.Bulk.html) — perform/4, action types, page_size, page_wait — HIGH confidence
- [Snap v0.16.0 Hexdocs — README](https://snap.hexdocs.pm/readme.html) — cluster setup, Finch dep, OpenSearch support — HIGH confidence
- [Snap GitHub — breakroom/snap](https://github.com/breakroom/snap) — overview, features, OpenSearch claim — MEDIUM confidence
- [Elasticsearch Bulk API docs](https://www.elastic.co/docs/api/doc/elasticsearch/operation/operation-bulk) — NDJSON format, action types, response format, `require_alias` param — HIGH confidence
- [OpenSearch Bulk API docs](https://docs.opensearch.org/latest/api-reference/document-apis/bulk/) — compatibility confirmation — HIGH confidence
- [Python elasticsearch-dsl Search DSL](https://elasticsearch-dsl.readthedocs.io/en/latest/search_dsl.html) — immutable builder pattern, must/filter/aggs API design — HIGH confidence
- [ExlasticSearch GitHub (Frameio)](https://github.com/Frameio/exlasticsearch) — Elixir pipe-based query DSL pattern: `must(match(...))`, `filter(term(...))` — MEDIUM confidence
- [Hex.pm elasticsearch packages](https://hex.pm/packages?search=elasticsearch) — confirmed Snap is most actively maintained (46K downloads, 1 month ago); elastix abandoned — HIGH confidence
- [Zero Downtime Reindex in Elasticsearch](https://tuleism.github.io/blog/2021/elasticsearch-zero-downtime-reindex/) — alias swap pattern rationale — LOW confidence (web, 2021)
- [Projecting Marten events to Elasticsearch](https://event-driven.io/en/projecting_from_marten_to_elasticsearch/) — ES projection pattern in .NET (batch on catch-up, single-doc on live) — MEDIUM confidence
- [ES Bulk API performance — Opster](https://opster.com/guides/elasticsearch/how-tos/optimizing-elasticsearch-bulk-indexing-high-performance/) — batch size guidance (1K–5K ops, 5–15 MB) — LOW confidence (web)
- [Orkestra ARCHITECTURE.md](/.planning/research/ARCHITECTURE.md) — existing at-least-once checkpoint semantics for non-Ecto adapters — HIGH confidence (first-party)
- [Orkestra STACK.md](/.planning/research/STACK.md) — Snap selection rationale, optional dep pattern — HIGH confidence (first-party)

---

*Feature research for: Orkestra v1.1 — Elasticsearch/OpenSearch Projection Adapter*
*Researched: 2026-06-25*
