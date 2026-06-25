# Stack Research

**Domain:** Elixir CQRS/ES — Elasticsearch/OpenSearch projection storage adapter (v1.1)
**Researched:** 2026-06-25
**Confidence:** HIGH (verified against hex.pm, hexdocs, GitHub, and official ES/OpenSearch docs as of June 2026)

---

## Context

Orkestra v1.0 already ships the following (DO NOT re-add or duplicate):

| Already present | Version in mix.lock |
|----------------|---------------------|
| jason | 1.4.4 |
| finch (via hermes_mcp) | — (in orkestra_mcp/ only) |
| opentelemetry_api | 1.5.0 |
| telemetry | 1.4.2 |
| ecto (optional) | 3.13.6 |
| ecto_sql (optional) | 3.13.5 |
| postgrex (optional) | 0.22.2 |
| mint | 1.7.1 |

This research covers **only what is ADDED** for the ES/OpenSearch adapter.

---

## Recommended Stack

### Core Technologies (ES/OpenSearch adapter additions)

| Technology | Version | Purpose | Why Recommended |
|------------|---------|---------|-----------------|
| snap | ~> 0.16 | ES/OpenSearch HTTP client, index management, bulk indexing | v0.16.0, updated May 2026, actively maintained. The only Elixir ES client that is current, actively maintained, and ships zero-downtime alias swap (`hotswap/4-5`) and streaming bulk operations as first-class APIs. Supports both Elasticsearch (tested ≥ 7.x, compatible with 8.x) and OpenSearch via the same REST API surface. Requires Elixir ~> 1.16 — no conflict with Orkestra's ~> 1.18. |
| finch | ~> 0.17 | HTTP/1.1 + HTTP/2 connection pool | v0.23.0 as of June 2026. Snap requires Finch as its HTTP transport (it declares `{:finch, "~> 0.17", optional: true}`). Orkestra's core does not depend on Finch directly — it lives only in orkestra_mcp/. Adding Finch to the core library for the ES adapter is additive and does not conflict. |
| castore | ~> 1.0 | CA certificate store for TLS | v1.0.19, updated May 2026. Required by Finch for HTTPS connections to ES/OpenSearch clusters. Snap declares `{:castore, "~> 1.0"}` as a direct dependency — consumers get it transitively. |

### Supporting Libraries (brought in transitively by snap)

| Library | Version | Purpose | Notes |
|---------|---------|---------|-------|
| process_tree | ~> 0.2 | Process-local state without global state | Snap dependency; avoids global config tables. No action needed — comes in with snap. |

---

## HTTP Client Strategy: Use Snap (not raw Req/Finch)

The question was "Req vs Finch vs raw" — the answer for this codebase is **neither directly**. Use **Snap**, which wraps Finch internally.

**Why not raw Req:**
Req 0.6.2 (Jun 2026) is excellent for general HTTP work and supports all auth types (basic, bearer, API key via custom steps). However, building an ES adapter on raw Req means reimplementing index management, alias swap, bulk API pagination, scroll, and response deserialization — all of which Snap already provides. The maintenance burden outweighs the flexibility gain.

**Why not raw Finch:**
Same argument amplified. Finch is a pooling layer, not an ES client. Building on Finch directly is lower-level than building on Req.

**Why Snap:**
- `Snap.Indexes.hotswap/4-5` is exactly the zero-downtime rebuild primitive needed: creates a new timestamped index, bulk-loads via a stream of actions, refreshes, atomically swaps the alias, and deletes old versions.
- `Snap.Bulk` handles streaming bulk actions with configurable `page_size` (default 5000) and `page_wait` (default 15000ms) — maps directly to the batch-indexing-during-catch-up requirement.
- `Snap.Indexes.create/3-4` accepts a mapping body — covers index mapping management.
- `Snap.Indexes.alias/3-4` and the underlying `_aliases` atomic update give alias swap for zero-downtime rebuild.
- `Snap.Auth` is an extensible behaviour — API key auth can be implemented as a custom module (see below) since Snap ships only `Snap.Auth.Plain` (Basic Auth) out of the box.
- `Snap.HTTPClient` is also a pluggable behaviour — custom adapters are possible for testing without a live cluster.
- Telemetry events are emitted natively, integrating cleanly with Orkestra's existing OTel instrumentation.

---

## Authentication

### Built-in: Basic Auth (username/password)

Snap.Auth.Plain is the default. It reads `username`/`password` from cluster config and injects `Authorization: Basic <base64>`. Works with:
- Self-hosted Elasticsearch with security enabled
- OpenSearch with HTTP basic auth
- Elastic Cloud (username/password)

```elixir
config :my_app, MyApp.ESCluster,
  url: "https://my-cluster.es.io:9243",
  username: "elastic",
  password: System.fetch_env!("ES_PASSWORD")
```

### Custom: API Key Auth

ES 8.x and Elastic Cloud strongly prefer API key auth (`Authorization: ApiKey <base64(id:key)>`). OpenSearch 2.x also supports it. Snap does **not** ship a built-in API key module, but the `Snap.Auth` behaviour makes implementation trivial — a single `sign/5` callback that injects one header:

```elixir
defmodule Orkestra.Projection.Storage.Elasticsearch.Auth.APIKey do
  @behaviour Snap.Auth

  @impl true
  def sign(config, method, url, headers, body) do
    api_key_id  = Keyword.fetch!(config, :api_key_id)
    api_key_val = Keyword.fetch!(config, :api_key)
    encoded = Base.encode64("#{api_key_id}:#{api_key_val}")
    auth_header = {"Authorization", "ApiKey #{encoded}"}
    {:ok, {method, url, [auth_header | headers], body}}
  end
end
```

Configured as:

```elixir
config :my_app, MyApp.ESCluster,
  url: "https://...",
  auth: Orkestra.Projection.Storage.Elasticsearch.Auth.APIKey,
  api_key_id:  System.fetch_env!("ES_API_KEY_ID"),
  api_key:     System.fetch_env!("ES_API_KEY")
```

Orkestra should ship this module as part of the ES adapter — it is simple enough to include and covers the primary production auth pattern for Elastic Cloud and ES 8.x.

### OpenSearch Service (AWS): IAM / SigV4

AWS OpenSearch Service requires request signing (SigV4). This is out of scope for v1.1. If a consumer needs it, they implement a `Snap.Auth` module that calls AWS SDK signing — Snap's pluggable auth behaviour makes this possible without library changes. Document as a known extension point.

---

## ES 8.x and OpenSearch 2.x Compatibility

**Wire protocol:** Both ES 8.x and OpenSearch 2.x expose a JSON-over-HTTP REST API. The core indexing/search/alias APIs are compatible at the wire level for the operations Orkestra uses:
- `PUT /<index>` — create index with mappings
- `POST /_bulk` — bulk index/update/delete
- `POST /_aliases` — atomic alias swap
- `GET /<alias>/_search` — search
- `DELETE /<index>` — drop index

**Divergence points to be aware of:**
- ES 8.x dropped mapping types (`_type`) from index URLs. Snap 0.11.0 explicitly handled this (set `type` field to `nil` in `Snap.Hit`). No action required — Snap handles it.
- ES 8.x requires `Content-Type: application/json` on all requests. Snap sets this.
- OpenSearch 2.x uses the same REST semantics as ES 7.10 for these endpoints — no known incompatibilities for the APIs Orkestra uses.
- Snap is described as "An Elasticsearch/OpenSearch client" and is used in production with both. A community forum thread showed Snap working with OpenSearch without compatibility issues.

**Confidence:** MEDIUM — the specific ES 8.x + OpenSearch 2.x combination is documented as compatible for the APIs used, but integration tests against both are the definitive verification. Flag in PITFALLS.

---

## JSON Encoding

Jason is already a project dependency (`{:jason, "~> 1.2"}`). Snap's JSON library is pluggable (`json_library` config key) and defaults to Jason. No change needed — Snap will use Orkestra's existing Jason installation automatically.

---

## Connection Pooling

Snap creates a named Finch pool per `Snap.Cluster` module as part of its supervision tree. The pool is started when the cluster's `start_link/1` is called (in the consuming application's supervision tree). Key characteristics:

- **Per-cluster pools:** Each `Snap.Cluster` module gets its own Finch pool — no shared state with other Finch users (e.g., hermes_mcp in orkestra_mcp).
- **HTTP/1.1 default:** Finch uses NimblePool for HTTP/1.1, one pool per `{scheme, host, port}`.
- **HTTP/2:** If the ES cluster supports HTTP/2, Finch automatically uses multiplexed connections without pooling overhead.
- **Configuration:** Pool size and timeouts are inherited from Finch options. Snap passes `http_client_adapter` config to its Finch instance.

No explicit connection pool configuration is needed in Orkestra's library code. The consuming application starts the cluster (which starts the pool) in its supervision tree.

---

## Index Mapping Management

`Snap.Indexes.create/3-4` accepts a map as the third argument — this map is the full index settings + mappings body. Orkestra's ES adapter should:

1. Define mapping schema as an Elixir map in the projector module (similar to how Ecto schemas define table structure).
2. Call `Snap.Indexes.create/3-4` on projector startup if the index/alias does not exist.
3. Use `Snap.Indexes.update_mapping/3-4` for non-breaking mapping additions (new fields).

Breaking mapping changes (changed field types, removed fields) require a full reindex via `Snap.Indexes.hotswap/4-5`.

---

## Zero-Downtime Rebuild via Alias Swap

Snap provides `Snap.Indexes.hotswap/4-5` which:
1. Creates a new timestamped index (e.g., `orders_20260625120000`).
2. Accepts an enumerable of `Snap.Bulk.Action` structs — the caller streams all documents.
3. Refreshes the new index.
4. Atomically updates the alias (e.g., `orders`) to point to the new index using ES `_aliases` API.
5. Deletes the previous index.

The Orkestra rebuild flow maps to:
- **Catch-up replay** → stream events → generate `Snap.Bulk.Action.Index` per event → pass enumerable to `hotswap`.
- **Live mode** → single-document writes via `Snap.Document.index/4-5` or `Snap.Document.upsert/4-5`.

During a rebuild, the alias continues to serve reads from the old index until the swap completes. Zero downtime is guaranteed by the atomic `_aliases` update.

---

## Batch Indexing During Catch-Up/Rebuild

`Snap.Bulk` handles batch indexing with two relevant parameters:
- `page_size` — actions per bulk request, default 5000 (configurable per-call).
- `page_wait` — milliseconds between pages, default 15000ms (should be tuned or set to 0 for internal rebuilds where ES backpressure is acceptable).

For the projector adapter, the batch mode should apply during `hotswap` rebuild (stream all events → bulk) and single-document mode in live operation (post-catch-up). The page size and wait should be configurable in the projector DSL.

---

## Query DSL

Snap takes **raw Elixir maps** for queries — it does not impose a query DSL. This is the correct choice:

```elixir
query = %{
  query: %{
    bool: %{
      must: [%{match: %{status: "active"}}],
      filter: [%{term: %{tenant_id: tenant_id}}]
    }
  },
  aggs: %{
    by_status: %{terms: %{field: "status"}}
  }
}

Snap.Search.search(MyCluster, "orders", query)
```

Orkestra's ES adapter should expose the query API through Snap.Search directly, providing thin helper functions (e.g., `search/2`, `count/2`) that wrap Snap.Search and handle response unwrapping. Do NOT add a query DSL layer — the ES JSON query language is already well-understood by developers and adding an abstraction over it adds friction.

The existing DSL libraries (tirexs, elastix, elaxto) are all unmaintained (last updates 2017–2021). Do not use them.

---

## Alternatives Considered

| Recommended | Alternative | When to Use Alternative |
|-------------|-------------|-------------------------|
| snap ~> 0.16 | elastix ~> 0.10 | Never — elastix last updated May 2021, effectively abandoned |
| snap ~> 0.16 | elasticsearch-elixir (danielberkompas) | Never — last updated Sep 2023, no versioned index management, less active |
| snap ~> 0.16 | Raw Req + custom ES client | Only if Snap's abstractions become a blocker (unlikely); Snap's source is small and forkable |
| Snap.Auth module (custom) | Embedded API key in URL | Never — credentials in URLs appear in logs; always use auth headers |
| snap ~> 0.16 | Official Elastic client (none for Elixir) | Elastic does not publish an official Elixir client — community clients only |

---

## What NOT to Use

| Avoid | Why | Use Instead |
|-------|-----|-------------|
| elastix | Last updated May 2021, abandoned | snap ~> 0.16 |
| elasticsearch-elixir (danielberkompas) | Last updated Sep 2023, no alias swap, stale | snap ~> 0.16 |
| tirexs | Last updated Apr 2017, Elixir 1.0 era | snap + raw maps |
| elaxto | Unmaintained DSL library | snap + raw maps |
| Any query DSL library | All unmaintained; ES JSON maps are readable enough | snap + raw Elixir maps |
| Credentials in URL (http://user:pass@host) | Credentials appear in logs, error messages | Snap.Auth.Plain or custom APIKey auth module |
| finch directly (bypassing snap) | Would require reimplementing ES API surface | snap |

---

## Stack Patterns by Variant

**If using Elastic Cloud or self-hosted ES 8.x with security:**
- Use the custom `Snap.Auth` API key module (ship it in Orkestra's ES adapter module)
- API key auth is preferred over basic auth for production

**If using AWS OpenSearch Service:**
- Need SigV4 signing — implement custom `Snap.Auth` module using AWS SDK
- Out of scope for v1.1; document as extension point

**If using self-hosted OpenSearch 2.x with basic auth:**
- Use `Snap.Auth.Plain` (default)
- No special configuration needed

**If running tests without a live cluster:**
- Use Snap's `http_client_adapter` config option to inject a mock adapter
- Snap.Test provides test helpers — verify in implementation phase

---

## mix.exs Changes Required

In `orkestra/mix.exs`, add to `defp deps`:

```elixir
# Projection adapter: Elasticsearch / OpenSearch (optional)
{:snap,   "~> 0.16", optional: true},
{:finch, "~> 0.17", optional: true},
```

Note: `castore` comes in transitively through `snap`. Do not declare it explicitly in Orkestra's mix.exs.

Consumer application's mix.exs:

```elixir
{:orkestra, "~> 0.1"},
{:snap,    "~> 0.16"},
{:finch,   "~> 0.17"},
```

The adapter module guard follows the existing pattern:

```elixir
if Code.ensure_loaded?(Snap.Cluster) do
  defmodule Orkestra.Projection.Storage.Elasticsearch do
    @behaviour Orkestra.Projection.Storage
    # ...
  end
end
```

---

## Version Compatibility

| Package | Compatible With | Notes |
|---------|-----------------|-------|
| snap ~> 0.16 | Elixir ~> 1.16 | Orkestra requires ~> 1.18, no conflict |
| snap ~> 0.16 | finch ~> 0.17 | snap declares optional finch ~> 0.17; use 0.17+ |
| snap ~> 0.16 | castore ~> 1.0 | Comes transitively; castore 1.0.19 current |
| snap ~> 0.16 | jason ~> 1.0 | Orkestra already has jason 1.4.4 — no conflict |
| snap ~> 0.16 | telemetry ~> 1.0 | Orkestra has telemetry 1.4.2 — no conflict |
| finch ~> 0.17 | mint ~> 1.0 | Orkestra already has mint 1.7.1 — no conflict |

All new dependencies are compatible with the existing lock file. No version conflicts are expected.

---

## Sources

- [hex.pm/packages/snap](https://hex.pm/packages/snap) — v0.16.0, updated May 2026 — HIGH confidence
- [snap.hexdocs.pm/readme.html](https://snap.hexdocs.pm/readme.html) — features list, Elixir requirement — HIGH confidence
- [snap.hexdocs.pm/Snap.Indexes.html](https://snap.hexdocs.pm/Snap.Indexes.html) — hotswap/4-5, alias/3-4, create/3-4, update_mapping — HIGH confidence
- [snap.hexdocs.pm/Snap.Bulk.html](https://snap.hexdocs.pm/Snap.Bulk.html) — page_size, page_wait, action types — HIGH confidence
- [snap.hexdocs.pm/Snap.Auth.html](https://snap.hexdocs.pm/Snap.Auth.html) — sign/5 callback, extensibility — HIGH confidence
- [snap.hexdocs.pm/Snap.HTTPClient.html](https://snap.hexdocs.pm/Snap.HTTPClient.html) — pluggable adapter, child_spec/1 — HIGH confidence
- [snap.hexdocs.pm/Snap.Search.html](https://snap.hexdocs.pm/Snap.Search.html) — raw map query API — HIGH confidence
- [github.com/breakroom/snap mix.exs](https://github.com/breakroom/snap/blob/main/mix.exs) — v0.16.0, deps: finch ~> 0.17 optional, castore ~> 1.0, jason ~> 1.0, process_tree ~> 0.2, telemetry — HIGH confidence
- [github.com/breakroom/snap CHANGELOG.md](https://github.com/breakroom/snap/blob/main/CHANGELOG.md) — ES 8.x compat fix in 0.11.0, feature history — HIGH confidence
- [hex.pm/packages/finch](https://hex.pm/packages/finch) — v0.23.0, Jun 2026 — HIGH confidence
- [hex.pm/packages/castore](https://hex.pm/packages/castore) — v1.0.19, May 2026 — HIGH confidence
- [hex.pm/packages/req](https://hex.pm/packages/req) — v0.6.2, Jun 2026 (considered, not used) — HIGH confidence
- [hex.pm/packages/elastix](https://hex.pm/packages/elastix) — v0.10.0, last updated May 2021 (avoided) — HIGH confidence
- [hex.pm/packages/elasticsearch](https://hex.pm/packages/elasticsearch) — v1.1.0, last updated Sep 2023 (avoided) — HIGH confidence
- [hex.pm/packages/tirexs](https://hex.pm/packages/tirexs) — v0.8.15, last updated Apr 2017 (avoided) — HIGH confidence
- [Elixir Forum: Snap + OpenSearch startup thread](https://elixirforum.com/t/create-opensearch-index-on-startup-with-snap/70419) — no compatibility issues reported — MEDIUM confidence
- Context7 `/wojtekmach/req` — Req auth options (basic, bearer, custom), connection pooling via Finch — HIGH confidence
- Snap CHANGELOG 0.11.0: "Allow nil for `type` in Snap.Hit since ElasticSearch >= 8 does not return this" — confirmed ES 8.x compat — HIGH confidence

---

*Stack research for: Orkestra v1.1 Elasticsearch/OpenSearch projection storage adapter*
*Researched: 2026-06-25*
