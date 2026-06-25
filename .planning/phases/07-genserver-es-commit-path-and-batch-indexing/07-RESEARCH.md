# Phase 7: GenServer ES Commit Path and Batch Indexing - Research

**Researched:** 2026-06-25
**Domain:** Elixir GenServer / Snap 0.16 bulk indexing / OTel spans / telemetry metrics
**Confidence:** HIGH

---

<user_constraints>
## User Constraints (from CONTEXT.md)

### Locked Decisions

- **Checkpoint ordering:** ES-first, Postgres-second (at-least-once semantics). Write ES document first, then update Postgres checkpoint atomically.
- **Live mode:** Single-document write per event via `Snap.Document.index(cluster, index, doc, id)` — uses the `es_op` descriptor from `Storage.Elasticsearch.write/4`
- **Catch-up/rebuild mode:** Accumulate `es_op` descriptors in GenServer state, flush via `Snap.Bulk.perform/4` at configurable batch_size (default 500)
- **Mode transition:** `:catching_up` → `:live` when caught up to head of stream (needs verification against GenServer state machine — see Open Questions)
- **Partial failure detection:** Parse bulk response body for per-item errors; do NOT advance checkpoint past failed items
- **OTel spans:** Follow existing `Tracer.with_span` pattern from `gen_server.ex` — add ES-specific attributes (index name, doc count, engine)
- **Telemetry metrics:** Follow existing `[:orkestra, :projector, ...]` event pattern — add bulk batch size, bulk flush duration, rebuild progress

### Claude's Discretion

All implementation choices are at Claude's discretion — pure infrastructure phase.

### Deferred Ideas (OUT OF SCOPE)

None — infrastructure phase.

</user_constraints>

<phase_requirements>
## Phase Requirements

| ID | Description | Research Support |
|----|-------------|------------------|
| BULK-01 | During catch-up/rebuild, adapter buffers events and flushes via Snap.Bulk in configurable batch size | `Snap.Bulk.perform/4` streams `Snap.Bulk.Action.Index` structs; buffer as list in GenServer state; flush when `length(buffer) >= batch_size` |
| BULK-02 | In live mode, adapter writes single documents immediately via Snap.Document | `Snap.Document.index(cluster, index, doc, id)` — 4 required + 2 optional args; returns `{:ok, response}` or `{:error, reason}` |
| BULK-03 | Bulk response body inspected per-item for partial failures with structured error reporting | `Snap.Bulk.perform/4` returns `{:error, %Snap.BulkError{errors: [%Snap.ResponseError{...}]}}` when any item fails; each `Snap.ResponseError` carries `:type`, `:message`, `:status`, `:raw` |
| OBSV-01 | OTel spans emitted for ES operations (index, bulk, search, rebuild) with ES-specific attributes | `Tracer.with_span "orkestra.es.single_doc_index"` and `"orkestra.es.bulk_flush"` with attributes: `es.index`, `es.doc_count`, `es.engine`, `orkestra.projector.name` |
| OBSV-02 | Telemetry metrics for bulk batch size, bulk duration, and rebuild progress | `:telemetry.execute([:orkestra, :projector, :es_bulk_flush], ...)` with `%{batch_size: n, duration_ms: d}` and `%{projector_name: name, index: index, engine: engine}` |

</phase_requirements>

---

## Summary

Phase 7 extends `Orkestra.Projector.GenServer` — which today has one commit path (Ecto.Multi transaction for Postgres) — to support a second commit path for Elasticsearch. The core challenge is that the Postgres path is synchronous and transactional (write + checkpoint in one DB transaction), while the ES path is HTTP-based and must sequence: ES write first, then Postgres checkpoint update separately (at-least-once semantics).

Two operating modes must coexist in the same GenServer. In **live mode**, each event produces exactly one `Snap.Document.index/6` call using the `es_op` descriptor returned by `Storage.Elasticsearch.write/4`. In **catch-up/rebuild mode**, the GenServer accumulates `%Snap.Bulk.Action.Index{}` structs in a buffer and flushes via `Snap.Bulk.perform/4` when the buffer reaches the configured `batch_size` (default 500). The mode transition mechanism requires design (see Open Questions).

The key constraint that makes this phase architecturally safe: `Storage.Elasticsearch.write/4` is already purely functional — it returns a descriptor map `%{action: :index, id: id, doc: doc}` without touching HTTP. The GenServer owns all I/O. This phase adds the I/O execution logic to the GenServer, branching on `storage_adapter` type.

**Primary recommendation:** Add `:es_buffer`, `:es_batch_size`, and `:es_mode` fields to GenServer state. Branch in `apply_event/2` on whether `storage_adapter` implements ES or Postgres path. For ES: check mode, either call `Snap.Document.index/6` directly (live) or push to buffer and conditionally flush (catch-up). For bulk flush, convert accumulated descriptors to `Snap.Bulk.Action.Index` structs and call `Snap.Bulk.perform/4`; inspect the return for `{:error, %Snap.BulkError{}}` to detect per-item failures.

---

## Architectural Responsibility Map

| Capability | Primary Tier | Secondary Tier | Rationale |
|------------|-------------|----------------|-----------|
| ES single-doc write (live mode) | GenServer (OTP process) | Snap.Document (HTTP client) | GenServer owns all I/O; adapter is pure |
| ES bulk flush (catch-up mode) | GenServer (OTP process) | Snap.Bulk (streaming HTTP) | GenServer controls flush triggers; Snap owns wire format |
| Buffer accumulation | GenServer state | — | OTP mailbox guarantees in-order, single-consumer; buffer lives in state map |
| Postgres checkpoint update | GenServer (OTP process) | Ecto.Repo | Checkpoint always stays in Postgres regardless of ES backend |
| Partial failure detection | GenServer (OTP process) | Snap.BulkError struct | GenServer inspects `%Snap.BulkError{errors: [...]}` and decides not to advance checkpoint |
| OTel spans | GenServer (OTP process) | Telemetry module | `Tracer.with_span` wraps each ES operation; follows existing `apply_event` pattern |
| Telemetry metrics | GenServer (OTP process) | `:telemetry.execute/3` | Emitted after successful flush; follows existing `[:orkestra, :projector, :lag]` pattern |
| Mode detection (live vs catch-up) | GenServer state | — | `:es_mode` field in state, set at init/load-checkpoint time |

---

## Standard Stack

### Core (already in project)

| Library | Version | Purpose | Why Standard |
|---------|---------|---------|--------------|
| Snap | 0.16.0 | ES HTTP client | Only maintained Elixir ES client; ships bulk, document, auth [VERIFIED: mix.lock] |
| OpenTelemetry API | 1.5.0 | OTel spans | Already used in `gen_server.ex` via `Tracer.with_span` [VERIFIED: mix.lock] |
| Telemetry | 1.4.1 | Metrics events | Already used for `[:orkestra, :projector, ...]` events [VERIFIED: mix.lock] |
| Mox | 1.2.0 | HTTP mock in tests | `Snap.MockHTTPClient` already defined in `test/support/es_cluster_mock.ex` [VERIFIED: Phase 06-01 SUMMARY] |

### Key Snap Sub-Modules

| Module | Purpose | How Used |
|--------|---------|---------|
| `Snap.Document` | Single document upsert | `Snap.Document.index(cluster, index, doc, id)` — live mode [VERIFIED: source] |
| `Snap.Bulk` | Streaming bulk operations | `Snap.Bulk.perform(stream, cluster, index, opts)` — catch-up mode [VERIFIED: source] |
| `Snap.Bulk.Action.Index` | Bulk index action struct | `%Snap.Bulk.Action.Index{id: id, doc: doc}` — one per buffered es_op [VERIFIED: source] |
| `Snap.BulkError` | Aggregate failure exception | `%Snap.BulkError{errors: [%Snap.ResponseError{...}]}` — partial failure detection [VERIFIED: source] |
| `Snap.ResponseError` | Per-item error struct | Fields: `:type`, `:message`, `:status`, `:raw` — structured error detail [VERIFIED: source] |

**No new dependencies needed.** All required libraries are already in `mix.exs` and `mix.lock` from Phase 6.

---

## Architecture Patterns

### System Architecture Diagram

```
Event arrives via handle_info
        │
        ▼
apply_event/2 (gen_server.ex)
        │
        ├─── storage_adapter == Postgres ──► [existing Ecto.Multi path — unchanged]
        │
        └─── storage_adapter == Elasticsearch
                │
                ▼
         storage_adapter.write/4
         returns {:ok, %{action: :index, id: id, doc: doc}}
                │
                ├─── state.es_mode == :live
                │        │
                │        ▼
                │   Snap.Document.index(cluster, index, doc, id)
                │   [OTel span: "orkestra.es.single_doc_index"]
                │        │
                │        ├─► {:ok, _} → update Postgres checkpoint
                │        └─► {:error, _} → handle_failure (retry/park)
                │
                └─── state.es_mode == :catching_up
                         │
                         ▼
                    push to es_buffer
                         │
                    length(buffer) >= batch_size?
                         │
                    YES ─┤
                         ▼
                  flush_bulk_buffer/2
                  Snap.Bulk.perform(buffer_as_actions, cluster, index, [page_wait: 0])
                  [OTel span: "orkestra.es.bulk_flush"]
                         │
                    ├─► :ok → update Postgres checkpoint for last position
                    │         emit [:orkestra, :projector, :es_bulk_flush] telemetry
                    └─► {:error, %Snap.BulkError{}} → handle_failure (partial errors)
```

### GenServer State Extension

The existing `state` map (defined as `@type state` in `gen_server.ex`) must gain three new fields:

```elixir
# Existing fields (unchanged):
#   repo, projector_name, storage_adapter, event_store,
#   lifecycle_config, adapter_opts, subscription_ref,
#   attempts, halted, last_seen_position,
#   rebuild_total, rebuild_events_replayed

# New ES-specific fields:
es_buffer: [],               # list of {position, %Snap.Bulk.Action.Index{}} pairs
es_batch_size: 500,          # configurable; read from Map.get(config, :es_batch_size, 500)
es_mode: :live               # :live | :catching_up — set at load_checkpoint time
```

The `:es_mode` field defaults to `:live`. If the GenServer is started with `rebuild_total` set in config, it starts in `:catching_up` mode. Mode transition to `:live` happens when events stop arriving in the mailbox — this needs careful design (see Open Questions).

### Snap.Bulk.perform/4 — Verified API

```elixir
# Source: /data/progetti/orkestra/deps/snap/lib/snap/bulk/bulk.ex (VERIFIED)

# Signature:
@spec perform(
  stream :: Enumerable.t(),
  cluster :: module(),
  index :: String.t(),
  opts :: Keyword.t()
) :: :ok | Snap.Cluster.error() | {:error, Snap.BulkError.t()}

# Usage — convert buffer to Action.Index structs, then flush:
actions = Enum.map(es_buffer, fn {_position, action} -> action end)

result = Snap.Bulk.perform(
  actions,
  cluster,
  index,
  page_size: length(actions),  # single page — buffer is already bounded by batch_size
  page_wait: 0                  # no inter-page delay for bounded buffers
)

# Return values:
# :ok                         — all items succeeded
# {:error, %Snap.BulkError{}} — one or more items failed (partial or total)
# {:error, other}             — connection/HTTP error
```

**Critical detail from source code inspection:** `Snap.Bulk.perform/4` continues to the end of the stream even if errors occur. It collects all errors into `%Snap.BulkError{errors: [%Snap.ResponseError{...}]}`. The GenServer must check the return and treat `{:error, %Snap.BulkError{}}` as a failure, calling `handle_failure/3`. Do NOT advance the Postgres checkpoint past the last successfully-flushed batch position.

### Snap.Bulk.Action.Index — Verified Struct

```elixir
# Source: /data/progetti/orkestra/deps/snap/lib/snap/bulk/action.ex (VERIFIED)

%Snap.Bulk.Action.Index{
  doc: %{"order_id" => "123", "status" => "placed"},  # required
  id: "order-123",                                      # optional — set for deterministic _id
  index: nil,                                           # nil = use index from perform/4 call
  require_alias: nil,
  routing: nil
}
```

The `:doc` field is the only enforced key (`@enforce_keys [:doc]`). Set `:id` from the `es_op` descriptor for deterministic document identity (ADPT-04).

### Snap.Document.index/6 — Verified API

```elixir
# Source: /data/progetti/orkestra/deps/snap/lib/snap/document.ex (VERIFIED)

# Signature (4 required, 2 optional):
Snap.Document.index(cluster, index, document, id, params \\ [], opts \\ [])

# Creates or updates document — full upsert (idempotent on replay)
# Returns {:ok, response_map} or {:error, reason}

# Usage in live mode:
case Snap.Document.index(cluster, index, doc, id) do
  {:ok, _} -> update_checkpoint_and_emit_lag(state, position)
  {:error, reason} -> handle_failure(event, reason, state)
end
```

### Partial Failure Detection — Verified Pattern

```elixir
# Source: /data/progetti/orkestra/deps/snap/lib/snap/exceptions/bulk_error.ex (VERIFIED)

# BulkError structure:
%Snap.BulkError{
  message: "3 errors occurred",
  errors: [
    %Snap.ResponseError{
      type: "document_parsing_exception",
      message: "failed to parse field [status]",
      status: 400,
      raw: %{"index" => %{"_id" => "123", "error" => %{...}}}
    },
    ...
  ]
}

# Pattern for GenServer bulk failure handling:
case Snap.Bulk.perform(actions, cluster, index, opts) do
  :ok ->
    # Update checkpoint, emit telemetry, clear buffer
    update_checkpoint_for_bulk(state, last_position)

  {:error, %Snap.BulkError{errors: errors} = bulk_err} ->
    # Log structured error detail, do NOT advance checkpoint
    Logger.warning("ES bulk flush partial failure",
      projector: projector_name,
      error_count: length(errors),
      errors: Enum.map(errors, fn e -> %{type: e.type, message: e.message, status: e.status} end),
      orkestra: :projector
    )
    handle_failure(last_event, bulk_err, state)

  {:error, reason} ->
    # HTTP/connection error
    handle_failure(last_event, reason, state)
end
```

**Key insight from source:** Snap.Bulk internally checks `{"errors" => true, "items" => items}` in the bulk response body. Per-item errors are collected into `Snap.ResponseError` structs via `Snap.ResponseError.exception_from_json/1`. The GenServer does NOT need to parse raw JSON — it just matches on `{:error, %Snap.BulkError{}}`.

### OTel Span Pattern (ES Operations)

```elixir
# Source: gen_server.ex lines 230-232, telemetry.ex (VERIFIED — following existing convention)

# Existing pattern in gen_server.ex:
Tracer.with_span "orkestra.projector.apply_event",
  attributes: OTel.projector_span_attrs(projector_name, event, position) do
  ...
end

# New ES-specific span for live mode single doc write:
Tracer.with_span "orkestra.es.single_doc_index",
  %{
    "es.index" => index,
    "es.engine" => to_string(engine),
    "orkestra.projector.name" => projector_name,
    "orkestra.projector.position" => position
  } do
  case Snap.Document.index(cluster, index, doc, id) do
    {:ok, _} -> :ok
    {:error, reason} ->
      Tracer.set_status(:error, inspect(reason))
      {:error, reason}
  end
end

# New ES-specific span for catch-up bulk flush:
Tracer.with_span "orkestra.es.bulk_flush",
  %{
    "es.index" => index,
    "es.engine" => to_string(engine),
    "es.doc_count" => length(actions),
    "orkestra.projector.name" => projector_name
  } do
  case Snap.Bulk.perform(actions, cluster, index, opts) do
    :ok -> :ok
    {:error, reason} ->
      Tracer.set_status(:error, inspect(reason))
      {:error, reason}
  end
end
```

### Telemetry Event Pattern (ES Operations)

```elixir
# Source: gen_server.ex lines 265-288 (VERIFIED — following existing convention)

# Existing pattern:
:telemetry.execute(
  [:orkestra, :projector, :lag],
  %{lag: lag},
  %{projector_name: projector_name}
)

# New ES bulk flush telemetry (OBSV-02):
:telemetry.execute(
  [:orkestra, :projector, :es_bulk_flush],
  %{batch_size: length(actions), duration_ms: elapsed_ms},
  %{projector_name: projector_name, index: index, engine: engine}
)

# Rebuild progress is ALREADY emitted by the existing rebuild_total mechanism.
# Phase 7 does NOT need to add a new rebuild_progress event — the existing
# [:orkestra, :projector, :rebuild_progress] fires after each event commit.
# However: in catch-up mode with bulk flushing, progress fires per-flush, not
# per-event. The planner must decide whether to emit it per-flush or per-event.
```

### Checkpoint Update Path for ES (ES-First Semantics)

```elixir
# ES commit path diverges from Postgres path.
# Postgres: atomic Ecto.Multi (read-model + checkpoint in one transaction)
# ES: sequential — ES write first, then Postgres checkpoint update separately

# After successful ES write (live mode):
defp update_es_checkpoint(repo, projector_name, position) do
  now = DateTime.utc_now()
  checkpoint = %Checkpoint{
    projector_name: projector_name,
    last_position: position,
    halted: false,
    updated_at: now
  }

  checkpoint_multi =
    Ecto.Multi.new()
    |> Ecto.Multi.insert(:checkpoint, checkpoint,
      on_conflict: [set: [last_position: position, halted: false, updated_at: now]],
      conflict_target: :projector_name
    )

  repo.transaction(checkpoint_multi)
end
```

This is the existing `checkpoint_multi` pattern from `gen_server.ex` lines 236-248, extracted for the ES path. The key difference: for Postgres, the combined multi is `Ecto.Multi.append(read_model_multi, checkpoint_multi)`. For ES, the checkpoint multi runs standalone after the ES write succeeds.

### Recommended Project Structure (New/Modified Files)

```
lib/orkestra/projector/
├── gen_server.ex       # MODIFIED — ES commit path, bulk buffer, mode detection
lib/orkestra/telemetry.ex  # MODIFIED — es_span_attrs/4 helper (optional)
test/orkestra/projector/
├── gen_server_es_test.exs  # NEW — ES-specific GenServer integration tests
```

### Anti-Patterns to Avoid

- **Shared Mox state across processes:** The `Orkestra.Test.ESHTTPAdapter` pattern from Phase 6 (delegates to `Snap.MockHTTPClient`, returns `:skip` from `child_spec`) must be reused unchanged. Do NOT configure `Snap.MockHTTPClient` directly as the http_client_adapter.
- **Ecto.Multi for ES writes:** The ES commit path must NOT use `Ecto.Multi.append` with a read-model multi. There is no `Ecto.Multi` for ES — only the checkpoint update is wrapped in a transaction.
- **page_wait in catch-up flush:** Use `page_wait: 0` when calling `Snap.Bulk.perform/4` with a single bounded page. The default 15-second wait is designed for multi-page streaming over large datasets, not for GenServer-buffered batches.
- **Advancing checkpoint on bulk partial failure:** A `%Snap.BulkError{}` must trigger `handle_failure/3`. The checkpoint must NOT advance. Some items may have succeeded in ES (ES is not transactional), but the checkpoint must stay behind to allow retry/replay.
- **Mode transition via atom comparison:** Do NOT compare `storage_adapter == Orkestra.Projection.Storage.Elasticsearch`. Instead, check for presence of `:es_mode` in state — or better, branch in `apply_event` on whether `storage_adapter.write/4` returns `%{action: :index}` vs `%Ecto.Multi{}`.

---

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| Bulk HTTP encoding | Custom NDJSON serializer | `Snap.Bulk.perform/4` | Snap handles chunking, serialization, inter-page waits, error collection |
| Per-item error detection | Manual JSON parsing of bulk response | `%Snap.BulkError{errors: [...]}` return from `Snap.Bulk.perform/4` | Snap already parses `{"errors": true, "items": [...]}` and maps each error to `%Snap.ResponseError{}` |
| ES document upsert | Manual `PUT /{index}/_doc/{id}` | `Snap.Document.index/6` | Snap handles URL encoding, namespace, auth header injection |
| Connection error handling | Custom retry on HTTP errors | `handle_failure/3` (existing in GenServer) | Already implemented with exponential backoff, park-and-halt |

---

## Common Pitfalls

### Pitfall 1: Snap.Bulk.Action.Index Struct Field Names

**What goes wrong:** Building the action struct with `:document` key instead of `:doc`.
**Why it happens:** The Elasticsearch bulk API spec uses "document" in some docs; Snap uses `:doc`.
**How to avoid:** Always use `%Snap.Bulk.Action.Index{doc: doc, id: id}` — `:doc` is the enforced key.
**Warning signs:** `KeyError` or `ArgumentError` on struct construction at test time.

### Pitfall 2: BulkError is an Exception, Not a Tagged Tuple

**What goes wrong:** Pattern matching `{:error, %{errors: errors}}` on bulk result.
**Why it happens:** Elixir exceptions are structs; `%Snap.BulkError{}` is `defexception`, not a plain map.
**How to avoid:** Match `{:error, %Snap.BulkError{errors: errors}}` explicitly.
**Warning signs:** Match falls through to generic `{:error, reason}` clause; `reason` is a `%Snap.BulkError{}` struct.

### Pitfall 3: Bulk Default page_size is 5000, page_wait is 15000ms

**What goes wrong:** Calling `Snap.Bulk.perform(actions, cluster, index, [])` with default opts during tests. Tests hang for 15 seconds between pages.
**Why it happens:** `@default_page_wait 15_000` in `Snap.Bulk`. Default `page_size: 5000` means a buffer of 500 still triggers inter-page waits if misused.
**How to avoid:** Always pass `page_size: length(actions), page_wait: 0` when flushing a bounded GenServer buffer (not streaming from an external source).
**Warning signs:** Tests that take 15+ seconds; ExUnit timeout failures.

### Pitfall 4: Mox inter-process ownership (existing pattern)

**What goes wrong:** Setting `Snap.MockHTTPClient` expectations from the test process; the GenServer process calling the mock gets `Mox.UnexpectedCallError`.
**Why it happens:** Mox owns expectations per-process. GenServer runs in a different process.
**How to avoid:** Use `Mox.allow(Snap.MockHTTPClient, self(), pid)` after `start_supervised!` but before event delivery. Same pattern as `Ecto.Adapters.SQL.Sandbox.allow/3` in existing tests.
**Warning signs:** `Mox.UnexpectedCallError` or `Mox.VerificationError` in ES tests.

### Pitfall 5: ES Checkpoint Must Run Standalone (Not via Ecto.Multi.append)

**What goes wrong:** Calling `Ecto.Multi.append(es_result, checkpoint_multi)` — `es_result` is not an `Ecto.Multi.t()`.
**Why it happens:** The Postgres path appends two `Ecto.Multi` structs. The ES path has no `Ecto.Multi` from the storage adapter.
**How to avoid:** In the ES branch, call `repo.transaction(checkpoint_multi)` directly after successful ES write/flush.
**Warning signs:** `Protocol.UndefinedError` for `Ecto.Multi` on non-Multi value; type mismatch at compile time if specs are enforced.

### Pitfall 6: Bulk Buffer Must Track Last Position for Checkpoint

**What goes wrong:** Flushing the buffer successfully but updating the checkpoint to the wrong position.
**Why it happens:** The buffer contains multiple events at different positions; only the last position should advance the checkpoint.
**How to avoid:** Buffer each entry as `{position, action_struct}` tuple. After flush, use `List.last(es_buffer)` position for the checkpoint update.
**Warning signs:** Checkpoint advances further than expected; some events replayed on restart.

---

## Code Examples

### ES Branch in apply_event/2

```elixir
# Source: gen_server.ex (existing apply_event logic — VERIFIED); ES extension is new

defp apply_event(event, state) do
  %{
    projector_name: projector_name,
    storage_adapter: storage_adapter,
    adapter_opts: adapter_opts
  } = state

  position = event.global_position

  Tracer.with_span "orkestra.projector.apply_event",
    attributes: OTel.projector_span_attrs(projector_name, event, position) do
    case storage_adapter.write(projector_name, event, position, adapter_opts) do
      {:ok, %{action: :index} = es_op} ->
        apply_es_event(event, es_op, position, state)

      {:ok, %{action: :skip}} ->
        # ES skip — still must update checkpoint to not stall
        update_es_checkpoint_only(event, position, state)

      {:ok, read_model_multi} ->
        # Existing Postgres path (Ecto.Multi) — unchanged
        apply_postgres_event(event, read_model_multi, position, state)

      {:error, reason} ->
        Tracer.set_status(:error, inspect(reason))
        Logger.warning("Projector storage_adapter.write/4 failed", ...)
        handle_failure(event, reason, state)
    end
  end
end
```

### ES Buffer Accumulation and Flush

```elixir
# New private helper for catch-up mode

defp apply_es_event(event, %{action: :index, id: id, doc: doc}, position, state) do
  action = %Snap.Bulk.Action.Index{id: id, doc: doc}

  case state.es_mode do
    :live ->
      commit_es_single_doc(event, action, position, state)

    :catching_up ->
      new_buffer = state.es_buffer ++ [{position, action}]

      if length(new_buffer) >= state.es_batch_size do
        flush_es_buffer(event, new_buffer, %{state | es_buffer: []})
      else
        {:noreply, %{state | es_buffer: new_buffer}}
      end
  end
end

defp flush_es_buffer(last_event, buffer, state) do
  %{adapter_opts: adapter_opts, projector_name: projector_name} = state
  cluster = Keyword.fetch!(adapter_opts, :cluster)
  index = Keyword.fetch!(adapter_opts, :index)
  engine = Keyword.get(adapter_opts, :engine, :elasticsearch)
  actions = Enum.map(buffer, fn {_pos, action} -> action end)
  {last_position, _} = List.last(buffer)

  started_at = System.monotonic_time(:millisecond)

  result =
    Tracer.with_span "orkestra.es.bulk_flush",
      %{
        "es.index" => index,
        "es.engine" => to_string(engine),
        "es.doc_count" => length(actions),
        "orkestra.projector.name" => projector_name
      } do
      Snap.Bulk.perform(actions, cluster, index,
        page_size: length(actions),
        page_wait: 0
      )
    end

  elapsed_ms = System.monotonic_time(:millisecond) - started_at

  case result do
    :ok ->
      :telemetry.execute(
        [:orkestra, :projector, :es_bulk_flush],
        %{batch_size: length(actions), duration_ms: elapsed_ms},
        %{projector_name: projector_name, index: index, engine: engine}
      )
      commit_es_checkpoint(last_event, last_position, %{state | es_buffer: []})

    {:error, reason} ->
      Tracer.set_status(:error, inspect(reason))
      handle_failure(last_event, reason, %{state | es_buffer: []})
  end
end
```

### Mox Setup Pattern for ES GenServer Tests

```elixir
# Source: test/support/es_cluster_mock.ex (VERIFIED — existing pattern)
# Use ESHTTPAdapter + Mox.allow after start_supervised!

setup do
  # Mox expectations must be set before event delivery
  Mox.stub(Snap.MockHTTPClient, :request, fn _cluster, method, url, _headers, _body, _opts ->
    cond do
      method == :put and String.contains?(url, "_doc") ->
        {:ok, %Snap.HTTPClient.Response{status: 200, body: ~s({"result":"updated"})}}
      method == :post and String.contains?(url, "_bulk") ->
        {:ok, %Snap.HTTPClient.Response{status: 200, body: ~s({"errors":false,"items":[]})}}
      true ->
        {:error, %Snap.HTTPClient.Error{reason: :unexpected_call}}
    end
  end)

  {:ok, _} = start_supervised(InMemory)
  :ok
end

# After start_supervised!:
pid = start_supervised!({ProjectorGenServer, es_config(projector_name)})
Mox.allow(Snap.MockHTTPClient, self(), pid)
```

---

## Runtime State Inventory

This is a greenfield addition (new code paths in existing module), not a rename/refactor. No runtime state migration required. Omitted per instructions.

---

## Open Questions

### 1. Mode Transition: When Does :catching_up Flip to :live?

**What we know:** The GenServer receives events from `event_store.subscribe_from_position/3`. The InMemory adapter pushes events as they arrive; there is no explicit "caught up" signal in the current implementation. `rebuild_total` in config is set by external callers for rebuild mode. The CONTEXT.md mentions "caught up to head of stream" as the trigger but notes this "needs verification against GenServer state machine."

**What's unclear:** The event store subscription does not send a "no more events" message. In the InMemory adapter, events are sent via `send(pid, event)`. There is no `:subscription_caught_up` message type currently handled by the GenServer.

**Recommendation:** For Phase 7, use `:es_mode` driven by whether `rebuild_total` is set in config at startup. If `rebuild_total` is set → `:catching_up`. If not → `:live`. This avoids a "caught up" signal mechanism entirely. The planner should confirm this interpretation matches the Phase 7 success criteria ("during catch-up/rebuild"). The more general mode-transition mechanism (live subscription catching up on restart) can be deferred to Phase 9 (rebuild).

**Impact:** If the planner selects a different mechanism (e.g., position-based comparison), the buffer flush logic at mode transition needs to be specified.

### 2. Bulk Flush on Mode Transition or Shutdown

**What we know:** If the GenServer accumulates a partial buffer (< batch_size) and the process terminates, buffered events are lost. The existing `terminate/2` callback only unsubscribes from the event store.

**Recommendation:** Add a final flush in `terminate/2` for ES mode. Or: make the buffer flush deterministic by flushing on `:load_checkpoint` completion, not only at batch_size. The planner should specify the partial-buffer behavior.

### 3. Checkpoint Update for Skipped ES Events (:skip)

**What we know:** `Storage.Elasticsearch.write/4` can return `{:ok, %{action: :skip}}` when the handler returns `:skip`. In the Postgres path, `__handle__/3` translates `:skip` to `{:ok, Ecto.Multi.new()}` (empty multi), which still advances the checkpoint. In the ES path, `apply_event` receives `{:ok, %{action: :skip}}` directly.

**Recommendation:** For skip events, still advance the checkpoint (ES-first semantics = no ES write needed, so the checkpoint can advance immediately). The planner should specify whether skip events in catch-up mode should flush the buffer first.

---

## Validation Architecture

### Test Framework

| Property | Value |
|----------|-------|
| Framework | ExUnit (built-in Elixir) |
| Config file | None — `mix test` with ExUnit.start in test_helper.exs |
| Quick run command | `mix test test/orkestra/projector/gen_server_es_test.exs --include elasticsearch` |
| Full suite command | `mix test --include elasticsearch` |

### Phase Requirements → Test Map

| Req ID | Behavior | Test Type | Automated Command | File Exists? |
|--------|----------|-----------|-------------------|-------------|
| BULK-02 | Live mode: single doc write per event via Snap.Document.index | unit (Mox) | `mix test test/orkestra/projector/gen_server_es_test.exs --include elasticsearch` | ❌ Wave 0 |
| BULK-01 | Catch-up mode: buffer accumulates, flushes at batch_size | unit (Mox) | `mix test test/orkestra/projector/gen_server_es_test.exs --include elasticsearch` | ❌ Wave 0 |
| BULK-03 | Partial failure: `%Snap.BulkError{}` triggers handle_failure, no checkpoint advance | unit (Mox) | `mix test test/orkestra/projector/gen_server_es_test.exs --include elasticsearch` | ❌ Wave 0 |
| OBSV-01 | OTel spans emitted for single-doc and bulk-flush operations | manual (OTel mock or span capture) | manual or `mix test` with span assertions | ❌ Wave 0 |
| OBSV-02 | Telemetry events for bulk batch_size and duration | unit (telemetry attach) | `mix test test/orkestra/projector/gen_server_es_test.exs --include elasticsearch` | ❌ Wave 0 |

### Sampling Rate

- **Per task commit:** `mix test test/orkestra/projector/gen_server_es_test.exs --include elasticsearch`
- **Per wave merge:** `mix test --include elasticsearch`
- **Phase gate:** Full suite green before `/gsd-verify-work`

### Wave 0 Gaps

- [ ] `test/orkestra/projector/gen_server_es_test.exs` — covers BULK-01, BULK-02, BULK-03, OBSV-02
- [ ] Framework already installed — ExUnit, Mox, ESHTTPAdapter all available from Phase 6

*(No framework install needed — existing test infrastructure from Phase 6 is sufficient)*

---

## Security Domain

`security_enforcement: true` in config.json.

### Applicable ASVS Categories

| ASVS Category | Applies | Standard Control |
|---------------|---------|-----------------|
| V2 Authentication | No | — |
| V3 Session Management | No | — |
| V4 Access Control | No | — |
| V5 Input Validation | Yes (partial) | ES document content comes from projector handler — validated by `dynamic: strict` index mapping (enforced in Phase 6) |
| V6 Cryptography | No | — |

### Known Threat Patterns for ES/Elixir

| Pattern | STRIDE | Standard Mitigation |
|---------|--------|---------------------|
| ES bulk injection via malformed doc | Tampering | `dynamic: strict` (enforced Phase 6) prevents new fields; document content sanitized by projector handler |
| Checkpoint not advanced on partial failure (silent data loss) | Tampering | BULK-03: inspect `%Snap.BulkError{}`, do NOT advance checkpoint, call `handle_failure/3` |
| Buffer growth unbounded in catch-up mode | Denial of Service | `es_batch_size` cap (default 500) enforced before each append; configurable |
| ES credentials in structured logs | Information Disclosure | OTel span attributes must NOT include credentials; `adapter_opts` (which carries cluster module) must not be logged |

**Note on ADPT-07:** The ES-first checkpoint ordering (ES write, then Postgres checkpoint) provides at-least-once delivery semantics. A crash between ES write and checkpoint update will cause event replay on restart, but ES writes are idempotent (deterministic `_id` + full `index` upsert), so replay is safe.

---

## Environment Availability

| Dependency | Required By | Available | Version | Fallback |
|------------|------------|-----------|---------|----------|
| Snap 0.16.0 | Snap.Bulk.perform, Snap.Document.index | ✓ | 0.16.0 | — |
| Mox 1.2.0 | ES GenServer unit tests | ✓ | 1.2.0 | — |
| Snap.MockHTTPClient (Mox mock) | ES tests | ✓ | Phase 6 | — |
| Orkestra.Test.ESHTTPAdapter | Mox bridge in tests | ✓ | Phase 6 | — |
| Orkestra.Test.ESCluster | Test Snap cluster | ✓ | Phase 6 | — |
| ExUnit | Test framework | ✓ | Built-in | — |
| Live ES/OpenSearch cluster | Integration tests only | Unknown | — | Use `@tag :integration` to exclude |

**Missing dependencies with no fallback:** None — all required for unit tests are present. Integration tests (live cluster) are excluded by default and not required for Phase 7 success criteria.

---

## Assumptions Log

| # | Claim | Section | Risk if Wrong |
|---|-------|---------|---------------|
| A1 | `:es_mode` should default to `:live` and switch to `:catching_up` only when `rebuild_total` is set in config | Open Questions §1 | If mode transition must be position-based, the buffer flush logic needs additional signals; plan tasks could be wrong |
| A2 | `page_wait: 0` is safe for GenServer-buffered batches (< 500 items) because the buffer is bounded and does not stream from a large source | Architecture Patterns | If Snap imposes a minimum page_wait (it doesn't — source verified), tests could be slower than expected |
| A3 | Rebuilding progress is adequately covered by the existing `[:orkestra, :projector, :rebuild_progress]` telemetry + new `[:orkestra, :projector, :es_bulk_flush]` — no additional per-event ES rebuild metric is needed | Phase Requirements OBSV-02 | If OBSV-02 requires a per-event ES metric distinct from the existing rebuild_progress event, an additional event type must be defined |

---

## State of the Art

| Old Approach | Current Approach | When Changed | Impact |
|--------------|------------------|--------------|--------|
| Raw HTTP `/_bulk` calls with NDJSON encoding | `Snap.Bulk.perform/4` with `Snap.Bulk.Action.Index` structs | Snap 0.9+ | No manual NDJSON serialization needed; error aggregation built-in |
| Check `body["errors"]` manually in bulk response | `{:error, %Snap.BulkError{}}` pattern match | Snap 0.9+ | Per-item errors are pre-parsed `%Snap.ResponseError{}` structs |

---

## Sources

### Primary (HIGH confidence)

- `/data/progetti/orkestra/deps/snap/lib/snap/bulk/bulk.ex` — `Snap.Bulk.perform/4` full source, including `process_errors/1`, `process_item/1`, `handle_result/1`
- `/data/progetti/orkestra/deps/snap/lib/snap/document.ex` — `Snap.Document.index/6` signature and implementation
- `/data/progetti/orkestra/deps/snap/lib/snap/bulk/action.ex` — `Snap.Bulk.Action.Index` struct definition with enforced `:doc` key
- `/data/progetti/orkestra/deps/snap/lib/snap/exceptions/bulk_error.ex` — `%Snap.BulkError{errors: [%Snap.ResponseError{}]}` structure
- `/data/progetti/orkestra/deps/snap/lib/snap/exceptions/response_error.ex` — `%Snap.ResponseError{type, message, status, raw}` fields
- `/data/progetti/orkestra/lib/orkestra/projector/gen_server.ex` — existing state type, `apply_event/2`, checkpoint pattern, telemetry events
- `/data/progetti/orkestra/lib/orkestra/projection/storage/elasticsearch.ex` — `write/4` descriptor contract, `init/1` return shape
- `/data/progetti/orkestra/test/support/es_cluster_mock.ex` — `Orkestra.Test.ESHTTPAdapter` Mox bridge pattern
- `/data/progetti/orkestra/test/orkestra/projector/gen_server_test.exs` — existing test patterns for GenServer
- `/data/progetti/orkestra/test/orkestra/projector/telemetry_test.exs` — existing telemetry test patterns

### Secondary (MEDIUM confidence)

- `https://snap.hexdocs.pm/Snap.Bulk.html` — Snap.Bulk.perform/4 API docs (cross-verified against source)
- `https://snap.hexdocs.pm/Snap.Document.html` — Snap.Document.index/6 API docs (cross-verified against source)
- `https://snap.hexdocs.pm/Snap.BulkError.html` — BulkError structure (cross-verified against source)

---

## Metadata

**Confidence breakdown:**
- Standard stack: HIGH — all deps verified via mix.lock and source code in deps/
- Architecture: HIGH — both Snap source and existing GenServer code read directly
- Pitfalls: HIGH — pitfalls 1-5 verified against Snap source; pitfall 6 inferred from buffer design
- Open Questions: MEDIUM — mode transition mechanism needs planner decision

**Research date:** 2026-06-25
**Valid until:** 2026-07-25 (Snap 0.16 is stable; no breaking changes expected in 30 days)
