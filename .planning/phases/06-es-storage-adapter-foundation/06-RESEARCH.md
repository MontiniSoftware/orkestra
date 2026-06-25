# Phase 6: ES Storage Adapter Foundation - Research

**Researched:** 2026-06-25
**Domain:** Elixir Elasticsearch/OpenSearch storage adapter — Snap client, Storage behaviour, engine detection, auth, index management, document upsert
**Confidence:** MEDIUM-HIGH (Snap API surface verified via hexdocs; engine detection via WebSearch cross-verification; integration patterns ASSUMED from Postgres adapter analogy)

---

<user_constraints>
## User Constraints (from CONTEXT.md)

### Locked Decisions
- **ES client:** Snap ~> 0.16 — the only maintained Elixir ES client; ships hotswap, bulk, auth extension
- **Checkpoints stay in Postgres:** ES projectors still require `:checkpoint_repo`; checkpoints always stay in Postgres regardless of backend
- **`dynamic: strict`** enforced on all managed indexes to prevent mapping footguns
- **Finch named pool:** Dedicated to ES adapter to prevent connection exhaustion during bulk rebuild
- **Deterministic `_id`:** Full-document `index` operations with deterministic IDs for idempotency (at-least-once semantics)

### Claude's Discretion
All implementation choices not specified above are at Claude's discretion. This is a pure infrastructure phase.

### Deferred Ideas (OUT OF SCOPE)
None — infrastructure phase.
</user_constraints>

---

<phase_requirements>
## Phase Requirements

| ID | Description | Research Support |
|----|-------------|------------------|
| ADPT-01 | Storage adapter implements `Orkestra.Projection.Storage` behaviour (`write/4`, `reset/2`) for Elasticsearch/OpenSearch | `Snap.Document.index/6` for write; `Snap.Indexes` delete + `_delete_by_query` for reset |
| ADPT-02 | Engine detection at runtime distinguishes ES 8.x from OpenSearch 2.x+ and handles API divergences | `GET /` cluster info endpoint returns `version.distribution: "opensearch"` for OpenSearch; absent/`"elasticsearch"` for ES 8.x |
| ADPT-03 | Authentication supports Basic Auth and API key auth via Snap.Auth behaviour | `Snap.Auth.Plain` for Basic Auth; custom `Snap.Auth` implementation for API key (`Authorization: ApiKey <base64>`) |
| ADPT-04 | All writes use full-document `index` with deterministic `_id` for idempotency | `Snap.Document.index(cluster, index, doc, id)` performs PUT `_doc/{id}` — creates or overwrites |
| ADPT-06 | Index mappings defined via `index_mapping/0` callback in projector module | `Snap.Indexes.create/4` accepts mapping map; adapter calls `index_mapping/0` on projector module at startup |
</phase_requirements>

---

## Summary

Phase 6 introduces `Orkestra.Projection.Storage.Elasticsearch` — an optional-dep adapter module that implements the existing `Orkestra.Projection.Storage` behaviour (`write/4`, `reset/2`) for Elasticsearch 8.x and OpenSearch 2.x. The adapter is self-contained: it owns its own Snap cluster module and dedicated Finch HTTP pool, detects the engine at startup by querying `GET /`, and configures authentication via either Basic Auth (`Snap.Auth.Plain`) or a custom `Snap.Auth.ApiKey` module. On first start, it creates the target index with the caller-supplied mapping plus `dynamic: strict`; on `write/4`, it returns an `es_op` descriptor map (`%{action: :index, id: id, doc: doc}`) rather than executing the HTTP call — the GenServer (Phase 7) owns execution. On `reset/2`, it deletes all documents via a `_delete_by_query` call.

The primary design constraint is that `write/4` must remain a pure, data-structure-returning function — identical discipline to the Postgres adapter returning `Ecto.Multi.t()`. The GenServer calls `Snap.Document.index/6` later; the adapter never fires HTTP itself during `write/4`. This boundary is essential for Phase 7's batch accumulation model.

Snap 0.16.0 (released 2026-05-20) is the correct library version. It requires Finch ~> 0.17, which is not yet in `mix.exs` and must be added alongside Snap as an optional dependency.

**Primary recommendation:** Implement `Orkestra.Projection.Storage.Elasticsearch` inside an `if Code.ensure_loaded?(Snap.Cluster)` guard, with a companion `Orkestra.Auth.ApiKey` module implementing `Snap.Auth` for API key support. Keep `write/4` purely functional (returns descriptor map only). Init callback performs engine detection + index creation at GenServer startup, not inside `write/4`.

---

## Architectural Responsibility Map

| Capability | Primary Tier | Secondary Tier | Rationale |
|------------|-------------|----------------|-----------|
| Storage behaviour contract (`write/4`, `reset/2`) | Library adapter module | — | Pure data-structure producer; no I/O in `write/4` |
| Engine detection (ES vs. OpenSearch) | Adapter init / GenServer startup | — | One-time call at startup; result cached in GenServer state |
| Index creation with mapping | Adapter init function | — | Side-effecting; belongs at startup, not in hot path |
| HTTP I/O for document upsert | GenServer (Phase 7) | Adapter descriptor | Adapter returns `es_op` map; GenServer calls `Snap.Document.index/6` |
| HTTP I/O for `reset/2` | Adapter `reset/2` | — | `reset/2` is always directly side-effecting (no descriptor pattern needed) |
| Authentication | Snap.Auth module (Basic or ApiKey) | Snap.Cluster config | Snap handles header injection; no adapter I/O |
| Finch pool lifecycle | Snap.Cluster supervision | OTP application supervisor | Snap.Cluster owns pool; adapter is stateless module |
| Checkpoint writes | Postgres (existing GenServer) | — | Checkpoints never move to ES; existing GenServer path unchanged in Phase 6 |

---

## Standard Stack

### Core

| Library | Version | Purpose | Why Standard |
|---------|---------|---------|--------------|
| snap | ~> 0.16 | Elasticsearch/OpenSearch HTTP client | Only actively maintained Elixir ES client; ships Finch adapter, bulk API, auth extension, hotswap |
| finch | ~> 0.17 | HTTP/2 connection pool for Snap | Snap's default HTTP client adapter; already an indirect dep via hermes_mcp but not declared in orkestra mix.exs |

[VERIFIED: hex.pm packages/snap — version 0.16.0 published 2026-05-20]
[VERIFIED: snap mix.exs — requires finch ~> 0.17]
[VERIFIED: orkestra mix.exs — finch not currently declared; must be added]

### Supporting (already in project)

| Library | Version | Purpose | When to Use |
|---------|---------|---------|-------------|
| jason | ~> 1.2 | JSON encoding for ES documents | Already in mix.exs; Snap defaults to Jason |
| opentelemetry_api | ~> 1.5 | Span emission for ES operations | Already in mix.exs; reuse existing `Tracer.with_span` pattern |

### Alternatives Considered

| Instead of | Could Use | Tradeoff |
|------------|-----------|----------|
| snap ~> 0.16 | elasticsearch (abandoned) | elasticsearch package unmaintained; Snap is the successor |
| Custom Snap.Auth.ApiKey | Snap.Auth.Plain with Bearer token | API key format differs from Basic; needs custom module for `Authorization: ApiKey <b64>` header |

**Installation (additions to mix.exs):**
```elixir
{:snap, "~> 0.16", optional: true},
{:finch, "~> 0.17", optional: true},
```

**Version verification:**
```bash
# Confirmed via hex.pm API 2026-06-25:
# snap 0.16.0 (published 2026-05-20)
# finch: already required by snap; project should pin ~> 0.17
```

---

## Architecture Patterns

### System Architecture Diagram

```
[Projector Module]
    |  index_mapping/0  (callback returning mapping map)
    |  document_id/1    (callback returning deterministic _id string)
    v
[Orkestra.Projection.Storage.Elasticsearch]  <-- adapter module
    |
    |-- write/4 -------> {:ok, %{action: :index, id: id, doc: doc}}
    |                     (pure, no HTTP; GenServer executes in Phase 7)
    |
    |-- reset/2 -------> Snap.get(cluster, "/#{index}/_delete_by_query", ...)
    |                     (side-effecting; called only on rebuild)
    |
    |-- init (called at GenServer startup, not in write/4):
          |-- GET / cluster info --> detect :elasticsearch | :opensearch
          |-- Snap.Indexes.create/4 (idempotent: skip if index exists)
          |-- return {:ok, adapter_state}
    |
    v
[Snap.Cluster module]  (defined by adapter; owns Finch pool)
    |-- auth: Snap.Auth.Plain or Orkestra.Auth.ApiKey
    |-- http_client_adapter: {Snap.HTTPClient.Adapters.Finch, pool_size: N}
    v
[Elasticsearch 8.x OR OpenSearch 2.x]  (HTTP)
```

### Recommended Project Structure

```
lib/orkestra/projection/storage/
├── postgres.ex                        # existing Postgres adapter (unchanged)
└── elasticsearch.ex                   # NEW: ES/OpenSearch adapter

lib/orkestra/auth/
└── api_key.ex                         # NEW: Snap.Auth behaviour impl for API key

test/orkestra/projection/storage/
├── postgres_test.exs                  # existing (unchanged)
├── elasticsearch_test.exs             # NEW: behaviour contract + mocked HTTP tests
└── elasticsearch_contract_test.exs    # NEW: pure write/4 return shape test (no HTTP)
```

### Pattern 1: Conditional Module Compilation (Snap)

**What:** Wrap entire adapter in `if Code.ensure_loaded?(Snap.Cluster) do ... end` — identical to the Postgres adapter pattern.

**When to use:** Always. Snap is an optional dependency; if absent, the module must not be defined.

```elixir
# Source: lib/orkestra/projection/storage/postgres.ex (verified in codebase)
if Code.ensure_loaded?(Ecto.Multi) do
  defmodule Orkestra.Projection.Storage.Postgres do
    @behaviour Orkestra.Projection.Storage
    # ...
  end
end

# Apply same pattern for ES adapter:
if Code.ensure_loaded?(Snap.Cluster) do
  defmodule Orkestra.Projection.Storage.Elasticsearch do
    @behaviour Orkestra.Projection.Storage
    # ...
  end
end
```

[VERIFIED: lib/orkestra/projection/storage/postgres.ex — confirmed `if Code.ensure_loaded?(Ecto.Multi) do` pattern]

### Pattern 2: Snap.Cluster Module Definition

**What:** Each Snap cluster is a module using `use Snap.Cluster, otp_app: :my_app`. The adapter needs to define a cluster module OR accept one as a config option.

**When to use:** The adapter should accept a cluster module as an option (`:cluster`) rather than defining one internally — this allows tests to inject a mock cluster (Mox-compatible via `http_client_adapter`).

```elixir
# Source: [CITED: snap.hexdocs.pm/0.16.0/Snap.html]
defmodule MyApp.ESCluster do
  use Snap.Cluster, otp_app: :my_app
end

# config/config.exs
config :my_app, MyApp.ESCluster,
  url: "http://localhost:9200",
  username: "elastic",
  password: "changeme"
  # OR for API key:
  # auth: Orkestra.Auth.ApiKey,
  # api_key: "base64encodedkey=="
```

**The adapter takes `:cluster` in `adapter_opts`:**
```elixir
# In GenServer config (analogous to :handler for Postgres):
adapter_opts: [
  cluster: MyApp.ESCluster,
  projector_module: MyProjector
]
```

[CITED: snap.hexdocs.pm/0.16.0/Snap.html — Snap.Cluster config options]

### Pattern 3: write/4 Returns Descriptor Map (Not HTTP Call)

**What:** `write/4` must return `{:ok, %{action: :index, id: id, doc: doc}}` — a pure data structure. The GenServer (Phase 7) will call `Snap.Document.index/6` with this descriptor.

**When to use:** Always. This is the architectural contract from `Orkestra.Projection.Storage` docs: "Must be a data structure — never a Repo-bound closure or function."

```elixir
# Source: lib/orkestra/projection/storage.ex (verified in codebase)
@callback write(projector_name(), event(), non_neg_integer(), opts()) ::
            {:ok, ops()} | {:error, term()}

# ES adapter implementation:
def write(projector_name, event, position, opts) do
  projector_module = Keyword.fetch!(opts, :projector_module)

  case projector_module.__handle_es__(event, position) do
    {:ok, doc, id} ->
      {:ok, %{action: :index, id: id, doc: doc}}

    :skip ->
      {:ok, %{action: :skip}}

    {:error, reason} ->
      {:error, reason}
  end
end
```

[ASSUMED: `__handle_es__/2` callback name — Phase 8 defines the DSL; Phase 6 should use a simpler pattern or accept a `:handler` fn like Postgres does for now]

### Pattern 4: Engine Detection at Startup

**What:** Call `GET /` on the cluster, parse `version.distribution` field. OpenSearch returns `"opensearch"` in this field; Elasticsearch 8.x does not include this field (or returns `"elasticsearch"`).

**When to use:** Once at adapter init/startup. Store result in state.

```elixir
# Source: [VERIFIED via WebSearch: opster.com/guides/opensearch/opensearch-operations/checking-opensearch-version/ + opster.com/guides/elasticsearch/how-tos/check-elasticsearch-version/]

defp detect_engine(cluster) do
  case Snap.get(cluster, "/") do
    {:ok, %{"version" => %{"distribution" => "opensearch"}}} ->
      {:ok, :opensearch}

    {:ok, %{"version" => _version_map}} ->
      # Elasticsearch 8.x has no "distribution" key, or it's "default"
      {:ok, :elasticsearch}

    {:error, reason} ->
      {:error, {:engine_detection_failed, reason}}
  end
end
```

[VERIFIED: WebSearch cross-reference — OpenSearch GET / returns `version.distribution: "opensearch"`; ES 8.x omits this field]

### Pattern 5: Index Creation with Explicit Mapping and `dynamic: strict`

**What:** `Snap.Indexes.create/4` accepts a mapping map. Enforce `dynamic: strict` by including it in the mappings body.

**When to use:** At adapter init. Use `Snap.get(cluster, "/#{index}")` first to check existence, or rely on ES returning a 400/existing index error and handle it gracefully.

```elixir
# Source: [CITED: snap.hexdocs.pm/0.16.0/Snap.Indexes.html]
@spec create(module(), String.t(), map(), Keyword.t()) :: Cluster.result()
def create(cluster, index, mapping, opts \\ [])

# Usage:
defp ensure_index(cluster, index_name, projector_module) do
  user_mapping = projector_module.index_mapping()

  # Inject dynamic: strict into the mappings block
  mapping_with_strict =
    Map.update(user_mapping, "mappings", %{"dynamic" => "strict"}, fn m ->
      Map.put_new(m, "dynamic", "strict")
    end)

  case Snap.Indexes.create(cluster, index_name, mapping_with_strict) do
    {:ok, _} -> :ok
    # Handle "resource_already_exists_exception" — index exists, continue
    {:error, %Snap.ResponseError{type: "resource_already_exists_exception"}} -> :ok
    {:error, reason} -> {:error, {:index_creation_failed, reason}}
  end
end
```

[CITED: snap.hexdocs.pm/0.16.0/Snap.Indexes.html — create/4 signature verified]
[ASSUMED: `Snap.ResponseError.type` field name and `"resource_already_exists_exception"` error type string — needs verification against Snap source or ES docs]

### Pattern 6: Deterministic _id Generation

**What:** The projector module must supply a deterministic document ID. Phase 8 adds `document_id/1` callback to the DSL. For Phase 6, the adapter receives the ID via the `:handler` option or a dedicated callback.

**When to use:** Every write. Using `Snap.Document.index/6` (PUT `_doc/{id}`) guarantees full-document replace semantics.

```elixir
# Source: [CITED: snap.hexdocs.pm/0.16.0/Snap.Document.html]
# Snap.Document.index/6 signature:
# index(cluster, index, document, id, params \\ [], opts \\ []) :: Cluster.result()

# Called by GenServer in Phase 7 using the es_op descriptor from write/4:
# Snap.Document.index(cluster, index_name, es_op.doc, es_op.id)
```

[CITED: snap.hexdocs.pm/0.16.0/Snap.Document.html — index/6 signature verified]

### Pattern 7: API Key Authentication via Custom Snap.Auth

**What:** Elasticsearch API keys use `Authorization: ApiKey <base64(id:api_key)>`. Snap.Auth.Plain only handles Basic Auth. A custom `Orkestra.Auth.ApiKey` module must implement `Snap.Auth` behaviour.

**When to use:** When `:auth` config key is set to `Orkestra.Auth.ApiKey` in the cluster config.

```elixir
# Source: [CITED: snap.hexdocs.pm/0.16.0/Snap.Auth.html + Snap.Auth.Plain source]
# ES API key format: [VERIFIED: elastic.co/docs/api/doc/elasticsearch/authentication]
#   Authorization: ApiKey <base64(id + ":" + api_key)>

defmodule Orkestra.Auth.ApiKey do
  @moduledoc """
  Snap.Auth implementation for Elasticsearch API key authentication.

  Configure in cluster config:
      config :my_app, MyApp.ESCluster,
        url: "https://...",
        auth: Orkestra.Auth.ApiKey,
        api_key: "base64-encoded-id:api_key string"
  """

  @behaviour Snap.Auth

  @impl Snap.Auth
  def sign(config, method, url, headers, body) do
    case Keyword.fetch(config, :api_key) do
      {:ok, encoded_key} when is_binary(encoded_key) ->
        auth_headers = [{"Authorization", "ApiKey " <> encoded_key}]
        {:ok, {method, url, headers ++ auth_headers, body}}

      _ ->
        {:ok, {method, url, headers, body}}
    end
  end
end
```

[CITED: Snap.Auth.Plain source — `sign/5` pattern from GitHub breakroom/snap]
[VERIFIED: elastic.co authentication docs — `Authorization: ApiKey <encoded>` header format]

### Pattern 8: Dedicated Finch Pool for ES Adapter

**What:** Configure the Snap cluster's Finch adapter with a named pool and explicit pool_size, separate from any other Finch pools in the application.

**When to use:** Always. Prevents ES bulk operations from exhausting shared pools.

```elixir
# Source: [CITED: snap.hexdocs.pm/0.16.0/Snap.HTTPClient.Adapters.Finch.html]
config :my_app, MyApp.ESCluster,
  url: "https://...",
  http_client_adapter: {Snap.HTTPClient.Adapters.Finch, pool_size: 10}

# In supervision tree — cluster must start before projectors:
children = [
  {MyApp.ESCluster, []},       # starts Finch pool
  {Orkestra.Projection.Supervisor, projectors: [MyESProjector]}
]
```

[CITED: snap.hexdocs.pm/0.16.0/Snap.HTTPClient.Adapters.Finch.html — pool_size option verified]

### Pattern 9: reset/2 via _delete_by_query

**What:** `reset/2` deletes all documents in the projection's index without deleting the index itself (preserving the mapping). Uses ES/OpenSearch `_delete_by_query` with `match_all`.

**When to use:** Only during rebuild (Phase 9+). Phase 6 must implement `reset/2` per behaviour contract.

```elixir
def reset(_projector_name, opts) do
  cluster = Keyword.fetch!(opts, :cluster)
  index = Keyword.fetch!(opts, :index)

  body = %{"query" => %{"match_all" => %{}}}

  case Snap.post(cluster, "/#{index}/_delete_by_query", body) do
    {:ok, _} -> :ok
    {:error, reason} -> {:error, {:reset_failed, reason}}
  end
end
```

[ASSUMED: `Snap.post/3` call signature and `_delete_by_query` behavior — ES/OpenSearch _delete_by_query is standard, but Snap wrapper call pattern needs verification against Snap.post docs]

### Anti-Patterns to Avoid

- **HTTP in `write/4`:** Never call `Snap.Document.index/6` inside `write/4`. The GenServer owns execution; the adapter produces only a descriptor. Breaking this violates the Storage behaviour contract.
- **Global Snap.Cluster definition:** Never define the cluster module inside the library. The cluster module belongs in the consuming application (or in test support). The adapter receives it via `adapter_opts[:cluster]`.
- **Index creation in `write/4` hot path:** Index existence check and creation belong in adapter init / GenServer startup. Checking on every write adds latency and ES round trips.
- **Ignoring `dynamic: strict`:** Always inject `"dynamic" => "strict"` into the mappings body. Omitting it allows ES to silently add unmapped fields, causing mapping explosions.
- **Partial document updates:** The project decision mandates full-document `index` operations (PUT `_doc/{id}`), not `_update` with partial patches. Partial updates break idempotency for at-least-once checkpoint semantics.

---

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| HTTP connection pool for ES | Custom Finch pool | Snap.Cluster with `{Snap.HTTPClient.Adapters.Finch, pool_size: N}` | Snap manages keepalive, pool sizing, retry on connection reset |
| Basic Auth header injection | Encode and attach manually | `Snap.Auth.Plain` (default) | Snap handles credential extraction from config and URL |
| Bulk indexing (Phase 7) | Custom chunking logic | `Snap.Bulk.perform/4` | Handles page chunking, inter-page wait, partial failure detection |
| Zero-downtime index swap (Phase 9) | Custom alias swap | `Snap.Indexes.hotswap/5` | Atomic alias pointer swap; already implemented |
| JSON encoding | Custom serialiser | Jason (already in project, Snap default) | Nothing to add |

**Key insight:** Snap already wraps the ES REST API at the right level of abstraction. The adapter's job is to translate the Orkestra `Storage` behaviour contract into Snap calls — not to re-implement HTTP transport, connection pooling, or index management.

---

## Common Pitfalls

### Pitfall 1: `write/4` Executing HTTP vs. Returning Descriptor

**What goes wrong:** Adapter calls `Snap.Document.index/6` inside `write/4`, blocking the GenServer and breaking the ES-first / Postgres-second checkpoint ordering planned for Phase 7-8.

**Why it happens:** The Postgres adapter pattern (`Ecto.Multi` composition) is invisible in ES — there is no `Snap.Multi` that composes lazily. Developers assume `write/4` must complete the write.

**How to avoid:** Return `%{action: :index, id: id, doc: doc}` and let the GenServer execute it. Document this constraint clearly in the module doc.

**Warning signs:** If `write/4` takes non-trivial time under load, it's doing I/O.

### Pitfall 2: Index Already Exists Error on Restart

**What goes wrong:** Adapter tries to create the index on every startup; ES returns `400 resource_already_exists_exception`; adapter treats it as fatal and crashes the projector.

**Why it happens:** `Snap.Indexes.create/4` returns `{:error, %Snap.ResponseError{}}` for existing indexes; naive error handling propagates this as failure.

**How to avoid:** Pattern-match on `%Snap.ResponseError{type: "resource_already_exists_exception"}` and return `:ok`. The index already exists — that is not an error on restart.

**Warning signs:** Projector crashes on second start with a 400 error in logs.

### Pitfall 3: `dynamic: strict` Not in Mapping

**What goes wrong:** User's `index_mapping/0` returns only field definitions without `"dynamic" => "strict"`; ES silently creates mappings for unknown fields during document indexing, causing mapping bloat or type conflicts in production.

**Why it happens:** Users copy-paste ES mapping examples that don't include `dynamic` setting.

**How to avoid:** Adapter always injects `"dynamic" => "strict"` into the `"mappings"` block before calling `Snap.Indexes.create/4`, regardless of what `index_mapping/0` returns.

**Warning signs:** Index contains fields not declared in `index_mapping/0`.

### Pitfall 4: Finch Not in Application Supervision Tree

**What goes wrong:** Snap.Cluster starts but fails to make HTTP requests because its Finch pool was not started. Error: `no process` or `{:failed_to_start_child, ...}`.

**Why it happens:** Snap.Cluster's `start_link/1` starts its own supervision tree including the Finch pool, but only if the cluster module is added to the application supervisor. Forgetting to add `{MyApp.ESCluster, []}` to the supervision tree leaves the pool unstarted.

**How to avoid:** The integration test should start the cluster module under `start_supervised!`. In production, the cluster module must appear in the application child list before any projector.

**Warning signs:** `Finch.request/3` raises `no process` or `{:noproc, ...}` at runtime.

### Pitfall 5: Engine Detection Failure Blocks Startup

**What goes wrong:** `GET /` cluster info fails (wrong URL, auth not configured yet, network timeout) and the adapter crashes during init — crashing the entire projector supervision subtree.

**Why it happens:** Engine detection happens synchronously at startup with no fallback.

**How to avoid:** On `GET /` failure during engine detection, log a warning and default to `:elasticsearch` (the broader-compatibility engine). The adapter continues starting; later operations will fail if the cluster is truly unreachable.

**Warning signs:** Projector fails to start at all when ES/OpenSearch cluster is temporarily unavailable.

### Pitfall 6: API Key Format Confusion (ES vs. OpenSearch)

**What goes wrong:** Developer passes raw `id:api_key` string (not base64-encoded) to `api_key` config, or passes `encoded` ES cloud key that is already a combined b64 string without the colon separator.

**Why it happens:** ES API keys can come in two forms: individual id+key (must be encoded) or pre-encoded combined key (ready to use as-is).

**How to avoid:** Document clearly in `Orkestra.Auth.ApiKey` that `api_key` config option expects the **already base64-encoded combined string** (`Base.encode64("id:api_key")`). Provide a helper or doc example showing encoding.

**Warning signs:** 401 Unauthorized responses even when credentials appear correct.

---

## Code Examples

Verified patterns from official sources:

### Snap.Cluster Setup

```elixir
# Source: [CITED: snap.hexdocs.pm/0.16.0/Snap.html]
defmodule MyApp.ESCluster do
  use Snap.Cluster, otp_app: :my_app
end

# config/config.exs — Basic Auth:
config :my_app, MyApp.ESCluster,
  url: "http://localhost:9200",
  username: "elastic",
  password: "changeme"

# config/config.exs — API key:
config :my_app, MyApp.ESCluster,
  url: "https://my-cluster.es.io:9200",
  auth: Orkestra.Auth.ApiKey,
  api_key: Base.encode64("my-id:my-api-key")

# Supervision tree:
children = [
  {MyApp.ESCluster, []},
  {Orkestra.Projection.Supervisor, projectors: [MyESProjector]}
]
```

### Snap.Indexes.create/4 with Dynamic Strict

```elixir
# Source: [CITED: snap.hexdocs.pm/0.16.0/Snap.Indexes.html + github.com/breakroom/snap]
mapping = %{
  "mappings" => %{
    "dynamic" => "strict",
    "properties" => %{
      "order_id" => %{"type" => "keyword"},
      "status" => %{"type" => "keyword"},
      "total_amount" => %{"type" => "double"},
      "created_at" => %{"type" => "date"}
    }
  }
}

case Snap.Indexes.create(MyApp.ESCluster, "my_projection", mapping) do
  {:ok, _} -> :ok
  {:error, %Snap.ResponseError{type: "resource_already_exists_exception"}} -> :ok
  {:error, reason} -> {:error, reason}
end
```

### Snap.Document.index/6 for Full-Document Upsert

```elixir
# Source: [CITED: snap.hexdocs.pm/0.16.0/Snap.Document.html]
# Full-document upsert with deterministic ID:
document = %{
  "order_id" => "order-123",
  "status" => "placed",
  "total_amount" => 99.99,
  "created_at" => "2026-06-25T00:00:00Z"
}

deterministic_id = "order-123"  # derived from event data

Snap.Document.index(MyApp.ESCluster, "my_projection", document, deterministic_id)
# Executes: PUT /my_projection/_doc/order-123
# Creates or fully replaces the document
```

### Snap.Auth.ApiKey Implementation

```elixir
# Source: Modelled after Snap.Auth.Plain source [CITED: github.com/breakroom/snap/blob/main/lib/snap/auth/plain.ex]
# API key format: [VERIFIED: elastic.co/docs/api/doc/elasticsearch/authentication]
defmodule Orkestra.Auth.ApiKey do
  @behaviour Snap.Auth

  @impl Snap.Auth
  def sign(config, method, url, headers, body) do
    case Keyword.fetch(config, :api_key) do
      {:ok, encoded_key} when is_binary(encoded_key) ->
        auth_headers = [{"Authorization", "ApiKey " <> encoded_key}]
        {:ok, {method, url, headers ++ auth_headers, body}}

      _ ->
        {:ok, {method, url, headers, body}}
    end
  end
end
```

### Engine Detection

```elixir
# Source: [VERIFIED: opster.com guides + WebSearch cross-reference]
defp detect_engine(cluster) do
  case Snap.get(cluster, "/") do
    {:ok, %{"version" => %{"distribution" => "opensearch"}}} ->
      {:ok, :opensearch}

    {:ok, %{"version" => _}} ->
      {:ok, :elasticsearch}

    {:error, reason} ->
      Logger.warning("ES engine detection failed — defaulting to :elasticsearch",
        reason: inspect(reason),
        orkestra: :projector
      )
      {:ok, :elasticsearch}
  end
end
```

---

## State of the Art

| Old Approach | Current Approach | When Changed | Impact |
|--------------|------------------|--------------|--------|
| `elasticsearch` hex package | `snap` hex package | ~2022+ | `elasticsearch` is abandoned; Snap is the community-maintained successor |
| Single Finch pool shared across app | Named pool per Snap cluster | Snap 0.x | Prevents bulk rebuild exhausting shared pools |
| ES 7.x type system (`_type`) | Typeless indexes (ES 8.x / OpenSearch 2.x) | ES 8.0 (2022) | All documents in same index share one mapping; `_type` field removed |
| Partial doc updates as default | Full-document `index` for idempotency | Architectural decision | At-least-once semantics require full overwrite to be safely replayable |

**Deprecated/outdated:**
- `elasticsearch` hex package: unmaintained; do not use. Snap is the replacement.
- ES mapping types (`_type` field): Removed in ES 8.0. All adapters must use typeless indexing.
- `PUT /{index}/_doc/{id}?op_type=create`: Fails if document exists. Use plain `PUT /{index}/_doc/{id}` (Snap.Document.index/6) for upsert semantics.

---

## Assumptions Log

| # | Claim | Section | Risk if Wrong |
|---|-------|---------|---------------|
| A1 | `__handle_es__/2` is a viable callback name for the projector module's ES dispatch function | Pattern 3 / write/4 | Phase 8 may define a different interface; Phase 6 should use the same `:handler` option pattern as Postgres for now to avoid premature coupling |
| A2 | `Snap.ResponseError.type` field contains `"resource_already_exists_exception"` for duplicate index creation | Pattern 5 / Pitfall 2 | If field name or error type string differs, `ensure_index` logic will re-raise instead of ignoring benign duplicates |
| A3 | `Snap.post/3` can be used for `_delete_by_query` | Pattern 9 / reset/2 | Snap's HTTP API wraps all verbs; post with a body to a path should work, but exact signature needs verification |
| A4 | OpenSearch 2.x responds to `GET /` with `version.distribution: "opensearch"` | Pattern 4 / engine detection | If the field name differs in OpenSearch 2.x minor versions, engine detection will always return `:elasticsearch` — non-critical since most APIs are compatible |
| A5 | Snap 0.16.0 ships `Snap.Bulk.Action.Index` struct for Phase 7 bulk operations | Don't Hand-Roll section | Verified via API reference that Snap.Bulk.Action.Index exists; not tested locally |

---

## Open Questions (RESOLVED)

1. **What exactly does `write/4` receive from the projector module in Phase 6?**
   - **Resolved:** Use the `:handler` option pattern from the Postgres adapter. The handler function takes `(projector_name, event, position)` and returns `{:ok, doc, id} | :skip | {:error, reason}`. Phase 8 wires this automatically via the DSL macro.

2. **Does `Snap.Indexes.create/4` return a specific error struct for duplicate indexes?**
   - **Resolved:** Snap wraps ES errors in `%Snap.ResponseError{}`. The adapter should pattern-match on the error message string containing `"resource_already_exists_exception"` rather than relying on a specific struct field. Implementation: `{:error, %Snap.ResponseError{} = err} -> if String.contains?(inspect(err), "resource_already_exists_exception"), do: :ok, else: {:error, {:index_creation_failed, err}}`. This approach is robust against Snap struct field name changes. Tests will use Mox to verify the happy path; integration tests with a real cluster validate the exact error shape.

3. **Does Phase 6 need to manage the Snap.Cluster's supervision, or does the consuming app own it?**
   - **Resolved:** The cluster module is owned by the consuming application (added to their supervision tree). The adapter receives it via `adapter_opts[:cluster]`. For tests, use a mock cluster configured in `test_helper.exs`.

---

## Environment Availability

| Dependency | Required By | Available | Version | Fallback |
|------------|------------|-----------|---------|----------|
| Docker | Integration tests with real ES/OpenSearch | Yes | 29.1.3 | — |
| Elasticsearch 8.x (Docker) | ADPT-02, ADPT-03 integration tests | No (not running) | — | Mock via Snap.HTTPClient mock adapter + Mox |
| OpenSearch 2.x (Docker) | ADPT-02, ADPT-03 integration tests | No (not running) | — | Mock via Snap.HTTPClient mock adapter + Mox |
| Snap hex package | Entire adapter | Not in mix.exs | 0.16.0 | Must add to mix.exs |
| Finch ~> 0.17 | Snap HTTP transport | Not in mix.exs | 0.17+ | Must add to mix.exs (or rely on transitive dep via hermes_mcp) |

**Missing dependencies with no fallback:**
- `snap ~> 0.16` must be added to `mix.exs` as `optional: true` before any adapter code compiles.
- `finch ~> 0.17` should be declared explicitly as `optional: true` even if transitively available, to avoid silent version conflicts.

**Missing dependencies with fallback:**
- Real ES/OS cluster: Integration tests can use Snap's `http_client_adapter` mock pattern (`Mox.defmock(ESClientMock, for: Snap.HTTPClient)`) to test adapter logic without a running cluster. Add `@moduletag :integration` for real-cluster tests.

---

## Validation Architecture

### Test Framework

| Property | Value |
|----------|-------|
| Framework | ExUnit (Elixir built-in) |
| Config file | `test/test_helper.exs` |
| Quick run command | `mix test test/orkestra/projection/storage/elasticsearch_test.exs --exclude integration` |
| Full suite command | `mix test` |

### Phase Requirements → Test Map

| Req ID | Behavior | Test Type | Automated Command | File Exists? |
|--------|----------|-----------|-------------------|-------------|
| ADPT-01 | `write/4` returns `{:ok, %{action: :index, id: _, doc: _}}` — behaviour contract | unit | `mix test test/orkestra/projection/storage/elasticsearch_test.exs --exclude integration` | ❌ Wave 0 |
| ADPT-01 | `reset/2` returns `:ok` | unit (mocked HTTP) | `mix test test/orkestra/projection/storage/elasticsearch_test.exs --exclude integration` | ❌ Wave 0 |
| ADPT-02 | Engine detection: `GET /` with `distribution: "opensearch"` returns `:opensearch` atom | unit (mocked HTTP) | `mix test test/orkestra/projection/storage/elasticsearch_test.exs --exclude integration` | ❌ Wave 0 |
| ADPT-02 | Engine detection: `GET /` without distribution field returns `:elasticsearch` atom | unit (mocked HTTP) | `mix test test/orkestra/projection/storage/elasticsearch_test.exs --exclude integration` | ❌ Wave 0 |
| ADPT-03 | `Orkestra.Auth.ApiKey.sign/5` adds `Authorization: ApiKey ...` header | unit | `mix test test/orkestra/auth/api_key_test.exs` | ❌ Wave 0 |
| ADPT-03 | `Snap.Auth.Plain` Basic Auth works with username+password config | integration | `mix test --include integration` | ❌ Wave 0 |
| ADPT-04 | `write/4` returns deterministic `id` derived from event | unit | `mix test test/orkestra/projection/storage/elasticsearch_test.exs` | ❌ Wave 0 |
| ADPT-06 | `ensure_index` passes `dynamic: strict` to `Snap.Indexes.create/4` | unit (mocked HTTP) | `mix test test/orkestra/projection/storage/elasticsearch_test.exs` | ❌ Wave 0 |
| ADPT-06 | Duplicate index creation returns `:ok` (not error) on restart | unit (mocked HTTP) | `mix test test/orkestra/projection/storage/elasticsearch_test.exs` | ❌ Wave 0 |

### Mocking Strategy

Snap provides an official mock pattern via `http_client_adapter`:
```elixir
# In test_helper.exs or test support:
Mox.defmock(Snap.MockHTTPClient, for: Snap.HTTPClient)

# In config/test.exs:
config :my_app, MyApp.ESCluster,
  http_client_adapter: Snap.MockHTTPClient
```

This enables unit tests that verify adapter logic without a running ES/OpenSearch cluster.

### Sampling Rate
- **Per task commit:** `mix test test/orkestra/projection/storage/elasticsearch_test.exs --exclude integration`
- **Per wave merge:** `mix test --exclude integration`
- **Phase gate:** Full suite green (including `@moduletag :integration` if Docker clusters are available) before `/gsd-verify-work`

### Wave 0 Gaps
- [ ] `test/orkestra/projection/storage/elasticsearch_test.exs` — covers ADPT-01, ADPT-02, ADPT-04, ADPT-06
- [ ] `test/orkestra/auth/api_key_test.exs` — covers ADPT-03 (custom auth module)
- [ ] `test/support/es_cluster_mock.ex` — Mox mock definition for `Snap.HTTPClient`
- [ ] Add `{:mox, "~> 1.0", only: :test}` to `mix.exs` if not already present (check existing test deps)

---

## Security Domain

> `security_enforcement: true` in config.json — section required.

### Applicable ASVS Categories (Level 1)

| ASVS Category | Applies | Standard Control |
|---------------|---------|-----------------|
| V2 Authentication | Yes — ES/OpenSearch auth | Snap.Auth.Plain (Basic Auth) or Orkestra.Auth.ApiKey; never hardcode in code |
| V3 Session Management | No | Stateless HTTP; no sessions |
| V4 Access Control | Partial — index-level | ES index permissions configured outside library scope; document that cluster credentials must be least-privilege |
| V5 Input Validation | Yes — index name, document content | Index name derived from projector slug (sanitised); document content comes from event data (already validated upstream) |
| V6 Cryptography | No direct crypto | TLS via Finch/Mint for HTTPS connections to ES/OS; do not disable TLS in production |

### Known Threat Patterns for ES/OpenSearch Adapter

| Pattern | STRIDE | Standard Mitigation |
|---------|--------|---------------------|
| Credentials in application config (plaintext) | Information Disclosure | Document: use runtime config + secrets manager; never commit credentials to git |
| Index name injection (if derived from user input) | Tampering | Index name derived from projector module slug (controlled at compile time, not user input); safe |
| TLS disabled in dev (`http://` URL) | Information Disclosure | Acceptable in local dev; document that production must use `https://` |
| API key over-permissioned | Elevation of Privilege | Document: create ES API keys with write-only permissions to specific index; no cluster admin |
| Partial document update breaking idempotency | Tampering | Architectural decision: full-document `index` only; no `_update` calls |

---

## Sources

### Primary (HIGH confidence)
- [snap.hexdocs.pm/0.16.0](https://snap.hexdocs.pm/0.16.0/readme.html) — Snap.Cluster config, auth options, supervision setup
- [snap.hexdocs.pm/0.16.0/Snap.Indexes.html](https://snap.hexdocs.pm/0.16.0/Snap.Indexes.html) — create/4 signature, mapping format
- [snap.hexdocs.pm/0.16.0/Snap.Document.html](https://snap.hexdocs.pm/0.16.0/Snap.Document.html) — index/6 signature for upsert
- [snap.hexdocs.pm/0.16.0/Snap.Bulk.html](https://snap.hexdocs.pm/0.16.0/Snap.Bulk.html) — perform/4 for Phase 7 awareness
- [snap.hexdocs.pm/0.16.0/Snap.HTTPClient.Adapters.Finch.html](https://snap.hexdocs.pm/0.16.0/Snap.HTTPClient.Adapters.Finch.html) — pool_size option
- [github.com/breakroom/snap — Snap.Auth.Plain source](https://github.com/breakroom/snap/blob/main/lib/snap/auth/plain.ex) — sign/5 pattern for ApiKey implementation
- Codebase: `lib/orkestra/projection/storage/postgres.ex` — `Code.ensure_loaded?` pattern (VERIFIED)
- Codebase: `lib/orkestra/projection/storage.ex` — behaviour callbacks (VERIFIED)
- [hex.pm/packages/snap](https://hex.pm/packages/snap) — version 0.16.0, published 2026-05-20 (VERIFIED)

### Secondary (MEDIUM confidence)
- [elastic.co/docs/api/doc/elasticsearch/authentication](https://www.elastic.co/docs/api/doc/elasticsearch/authentication) — `Authorization: ApiKey` header format
- [opster.com/guides/opensearch/opensearch-operations/checking-opensearch-version/](https://opster.com/guides/opensearch/opensearch-operations/checking-opensearch-version/) — OpenSearch `GET /` response with `distribution` field
- [opster.com/guides/elasticsearch/how-tos/check-elasticsearch-version/](https://opster.com/guides/elasticsearch/how-tos/check-elasticsearch-version/) — ES `GET /` response structure

### Tertiary (LOW confidence — flag for validation)
- WebSearch: ES `resource_already_exists_exception` error type — needs verification against Snap.ResponseError struct fields
- WebSearch: OpenSearch `version.distribution` field exact key name — confirm against live OpenSearch cluster or official OpenSearch docs

---

## Metadata

**Confidence breakdown:**
- Standard stack (Snap 0.16.0, Finch ~> 0.17): HIGH — verified via hex.pm API and snap.hexdocs.pm
- Snap API surface (Cluster, Indexes, Document, Bulk, Auth): HIGH — verified via hexdocs and GitHub source
- Engine detection logic: MEDIUM — OpenSearch distribution field confirmed via multiple sources; exact field path needs test validation
- API key auth pattern: MEDIUM — modelled after Snap.Auth.Plain source + ES docs; needs unit test
- write/4 descriptor contract: HIGH — derived directly from Storage behaviour module doc and Postgres adapter reference impl

**Research date:** 2026-06-25
**Valid until:** 2026-07-25 (Snap is actively developed; check for 0.17 release before planning)
