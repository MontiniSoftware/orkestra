---
phase: 01-foundations
reviewed: 2026-06-24T00:00:00Z
depth: standard
files_reviewed: 9
files_reviewed_list:
  - lib/orkestra/event_store.ex
  - lib/orkestra/event_store/event_store_db.ex
  - lib/orkestra/event_store/in_memory.ex
  - lib/orkestra/projection/checkpoint.ex
  - lib/orkestra/projection/dead_letter.ex
  - lib/orkestra/projection/migration.ex
  - lib/orkestra/projection/storage.ex
  - lib/orkestra/projector/lifecycle.ex
  - mix.exs
findings:
  critical: 5
  warning: 6
  info: 3
  total: 14
status: issues_found
---

# Phase 1: Code Review Report

**Reviewed:** 2026-06-24
**Depth:** standard
**Files Reviewed:** 9
**Status:** issues_found

## Summary

Reviewed the Phase 1 foundation of the projection subsystem: the `EventStore` behaviour, its
InMemory and EventStoreDB adapters, the projection Ecto schemas/migration, the storage behaviour,
and the pure `Lifecycle` retry module.

The pure modules (`Lifecycle`, `Storage`, `Migration`, the two schemas) are largely sound and
well-documented. The serious defects are concentrated in the two event-store adapters:

1. The `EventStore.impl/0` config lookup reads the **wrong OTP application key** (`:ultimus`
   instead of `:orkestra`), so adapter configuration is silently ignored.
2. The EventStoreDB adapter has **three independent correctness bugs** that defeat its own
   contract: revision extraction never matches (always returns `-1`), event metadata is dropped
   on append, and stored event metadata is dropped on read. These pass Phase 1 "compile/wiring"
   tests but produce wrong runtime behavior — exactly the class of defect those deferred tests
   were supposed to catch later.
3. The InMemory adapter's per-stream subscription path is **structurally broken** (events never
   carry a `:stream_id` key, and live push ignores the subscribed stream entirely). It happens to
   work only because every existing test uses `:all`.

These adapters are not safe to build Phase 2 on top of without fixes.

## Critical Issues

### CR-01: `EventStore.impl/0` reads the wrong OTP application key (`:ultimus`)

**File:** `lib/orkestra/event_store.ex:85` (also moduledoc `:11` and `event_store_db.ex:9`)
**Issue:** `impl/0` looks up configuration under the `:ultimus` application, but this library is
`:orkestra` (see `mix.exs:9` and every other module: `message_bus.ex:60`, `message_bus.ex:90`,
`message_bus/pub_sub.ex:29`, `message_bus/rabbit_mq.ex:35` all use `:orkestra`). Any consumer who
configures `config :orkestra, Orkestra.EventStore, adapter: ...` will be silently ignored, and the
adapter will always fall back to `InMemory` even in production. This is a copy-paste leak from a
prior project name and is a data-correctness hazard (events go to the in-memory store and vanish on
restart).
**Fix:**
```elixir
def impl do
  Application.get_env(:orkestra, __MODULE__, [])
  |> Keyword.get(:adapter, Orkestra.EventStore.InMemory)
end
```
Also update the `@moduledoc` example in `event_store.ex:11` and `event_store_db.ex:9` from
`config :ultimus, ...` to `config :orkestra, ...`.

### CR-02: EventStoreDB `extract_revision/1` never matches — `append_events` always returns `{:ok, -1}`

**File:** `lib/orkestra/event_store/event_store_db.ex:111-122, 219-224`
**Issue:** `append/4` is called with `raw?: true`, so on success Spear returns `{:ok, response}`
where `response` is a raw `Streams.append_resp` Erlang record (a tuple), **not** a map with a
`:current_revision` key. `extract_revision/1` pattern-matches `%{current_revision: rev}`, which can
never match a record tuple, so it always falls through to `-1`. Every successful append therefore
reports revision `-1` to the caller, breaking optimistic-concurrency callers that thread the
returned revision into the next `expected_revision` (they will pass `-1`/`:empty` and get spurious
`:wrong_expected_version`, or silently corrupt ordering). The behaviour contract (`event_store.ex:57`)
promises `{:ok, revision()}`.
**Fix:** Extract the revision from the raw protobuf record (or drop `raw?: true` and use Spear's
parsed `:ok`/violation path). With `raw?: true` you must decode the `append_resp` record's
`current_revision_option`. Simplest correct approach — let Spear parse it and read the revision via
its public API rather than guessing the map shape:
```elixir
case Spear.append(spear_events, @connection, stream_id, expect: expect) do
  :ok ->
    # Spear's non-raw success returns :ok without the revision; if the revision
    # is required, read it back, e.g. via Spear.read_stream/.../last or by
    # decoding the raw append_resp record explicitly. Do NOT silently return -1.
    ...
end
```
At minimum, do not return a hardcoded `-1` on the fall-through branch — log and return
`{:error, {:unexpected_append_response, response}}` so the bug is loud rather than silent.

### CR-03: EventStoreDB append silently drops all event metadata

**File:** `lib/orkestra/event_store/event_store_db.ex:94-101`
**Issue:** Events are built with `Spear.Event.new(event.type, event.data, metadata: event.metadata)`.
`Spear.Event.new/3` does not accept a `:metadata` option — it accepts `:custom_metadata` (a binary)
and `:content_type` (see `deps/spear/lib/spear/event.ex:186-195`). The unknown `:metadata` keyword is
ignored, so `custom_metadata` defaults to `<<>>`. Result: correlation/causation/actor metadata —
the core of this library's metadata-threading guarantee — is **silently discarded** on every append
to EventStoreDB.
**Fix:** Serialize the metadata map to a binary and pass it as `:custom_metadata`:
```elixir
Spear.Event.new(
  event.type,
  event.data,
  custom_metadata: Jason.encode!(event.metadata)
)
```

### CR-04: EventStoreDB read silently drops all event metadata (guard mismatch)

**File:** `lib/orkestra/event_store/event_store_db.ex:213-217`
**Issue:** `extract_custom_metadata/1` matches `%{custom_metadata: meta} when is_map(meta)`. But
EventStoreDB / Spear surfaces `custom_metadata` as a **binary** (the raw bytes, typically a JSON
string — see `deps/spear/lib/spear/event.ex:59,134,193`), never a map. The `is_map/1` guard always
fails and the function falls through to the `_ -> %{}` clause, so every event read back from
EventStoreDB has empty metadata. Combined with CR-03, metadata is lost on both write and read.
**Fix:** Decode the binary custom_metadata:
```elixir
defp extract_custom_metadata(%Spear.Event{metadata: %{custom_metadata: bin}})
     when is_binary(bin) and bin != "" do
  case Jason.decode(bin) do
    {:ok, map} when is_map(map) -> map
    _ -> %{}
  end
end

defp extract_custom_metadata(_), do: %{}
```

### CR-05: InMemory per-stream subscription delivers nothing (missing `:stream_id`) and live push ignores the subscribed stream

**File:** `lib/orkestra/event_store/in_memory.ex:182-217, 219-224`
**Issue:** Two compounding bugs make any non-`:all` subscription broken:
1. `do_append/4` stamps each event with `:stream_revision` and `:global_position` but **never adds
   a `:stream_id` key**. `filter_for_stream/2` (line 223) filters history with
   `Map.get(e, :stream_id) == stream_id`, which is always `nil == stream_id` → `false`. A subscriber
   to a specific stream therefore receives **zero history**, even when matching events exist.
2. Live delivery in `do_append/4` (lines 212-214) pushes every newly-appended event to **every**
   registered subscriber with no stream filtering. So a per-stream subscriber receives live events
   from *all* streams, while a `:stream_id` subscriber gets correct history of nothing. The two paths
   (history-filtered, live-unfiltered) are inconsistent.

This is masked because every test in `in_memory_subscription_test.exs` subscribes with `:all`. The
behaviour doc (`event_store.ex:60-71`) explicitly advertises per-stream subscription.
**Fix:** Stamp `:stream_id` onto each event in `do_append/4`, and filter live delivery by the
subscriber's subscribed stream. This requires storing the subscribed stream alongside the pid:
```elixir
# in do_append, when stamping:
|> Map.put(:stream_id, stream_id)

# store subscribers as {pid, stream_or_all} instead of bare pids, then:
Enum.each(state.subscribers, fn {subscriber_pid, sub_stream} ->
  stamped
  |> filter_for_stream(sub_stream)
  |> Enum.each(fn e -> send(subscriber_pid, e) end)
end)
```
and update `subscribe_from_position/3` to register `{subscriber, stream_id_or_all}`.

## Warnings

### WR-01: `subscribe_from_position/3` returns an unusable ref and provides no unsubscribe path

**File:** `lib/orkestra/event_store/in_memory.ex:148-178`
**Issue:** The returned `make_ref()` is never stored in agent state and is not associated with the
registered subscriber. There is no way to unsubscribe, and a crashed/exited subscriber pid stays in
`state.subscribers` forever, so `do_append` keeps `send/2`-ing to dead pids (silently dropped) and
the list grows unbounded across a long-running test suite. For a test/dev adapter this is a leak and
makes the returned ref misleading (callers may assume it is a handle).
**Fix:** Store `{ref, pid, stream}` tuples; provide an `unsubscribe/1` by ref; optionally
`Process.monitor/1` the subscriber and prune on `:DOWN`. At minimum, document that the ref is inert.

### WR-02: `load_events/2` returns the full-stream revision even when the filtered slice is empty

**File:** `lib/orkestra/event_store/in_memory.ex:90-99`
**Issue:** When `from_revision` is at or beyond the head, `filtered` is `[]` but the function returns
`{:ok, [], revision}` where `revision` is the full stream's current revision. The single-arity
`load_events/1` returns `-1` for an empty result, so the two arities disagree on what revision
accompanies an empty list. Callers that branch on `{:ok, [], rev}` (as the EventStoreDB adapter and
likely the Phase 2 projector do) will see inconsistent semantics between the two adapters and the two
arities. Confirm this is intended; if "current revision regardless of filter" is the contract, the
single-arity empty case (`-1`) contradicts it.
**Fix:** Decide one contract. If empty-slice should still report the true head revision, make the
1-arity empty case return the true revision too (it is `-1` only because the stream is genuinely
empty, which is fine — but document the distinction explicitly in the behaviour `@callback` doc).

### WR-03: `append_events` revision math relies on `length/1` of the whole stream on every append

**File:** `lib/orkestra/event_store/in_memory.ex:113, 183, 197-198`
**Issue:** `current_revision = length(current_events) - 1` and `all_stream_events = current_events ++ stamped`
recompute and re-append the entire stream list on every call. Beyond the (out-of-scope) performance
concern, the correctness risk is that `++` and `length` on a growing list are the sole source of
truth for revision; any divergence between `global_counter` and per-stream length is undetected. This
is brittle for a component that defines concurrency correctness. Not a blocker for tests, but flagged
because revision integrity is load-bearing.
**Fix:** Track per-stream revision explicitly in state rather than deriving it from `length/1`, or add
an assertion that `base_revision == length(current_events)`.

### WR-04: EventStoreDB `load_events/1` and `/2` duplicate logic with divergent error handling

**File:** `lib/orkestra/event_store/event_store_db.ex:19-58, 60-90`
**Issue:** The two arities are near-identical, but `/1` logs on the non-`:not_found` Spear error and
the generic rescue, while `/2` logs nothing and silently returns `{:error, e}`. Silent failure in
`/2` (the incremental-load path the projector will use most) makes production debugging hard and is
inconsistent with the project's "log at decision points / failure" logging convention in CLAUDE.md.
**Fix:** Factor the shared body into a private helper that takes the `from`/empty-revision values, and
log uniformly in both arities.

### WR-05: `to_stored_event/1` can emit `global_position: nil`, violating the stored_event_with_position type

**File:** `lib/orkestra/event_store/event_store_db.ex:195-211`
**Issue:** `global_position_from_spear_event/1` returns `nil` when `commit_position` is absent or
non-integer, and `to_stored_event/1` puts that `nil` directly into `:global_position`. The
`@type stored_event_with_position` (`event_store.ex:36-43`) declares `global_position` as
`non_neg_integer()`. A `nil` position will break any downstream checkpoint arithmetic
(`head_position - last_position`) with an `ArithmeticError`. Standard reads (`load_events`) also call
`to_stored_event`, where `commit_position` is generally present, but the `nil` path is reachable.
**Fix:** Either guarantee a position (raise/return `{:error, ...}` when absent for subscription
events) or keep `global_position` out of the plain `stored_event()` map produced by reads, since the
plain `stored_event()` type does not include it.

### WR-06: `append_events` does not handle `expect: :exists` / non-negative-only revisions consistently

**File:** `lib/orkestra/event_store/event_store_db.ex:103-109` and `in_memory.ex:115-130`
**Issue:** The `expected_revision()` type (`event_store.ex:17`) is
`non_neg_integer() | :any | :no_stream`, but the EventStoreDB adapter also special-cases `-1 -> :empty`
(line 107), which is not part of the declared type, while InMemory does not accept `-1` at all (it
would fall to the `true ->` wrong-version branch). The two adapters accept different inputs for the
same behaviour callback, so code that passes `-1` works on EventStoreDB and fails on InMemory.
**Fix:** Normalize: either add `-1` to the `expected_revision()` type and handle it identically in
both adapters, or reject it in both. Keep adapter input contracts identical.

## Info

### IN-01: `bsl/2` import is inside the function body

**File:** `lib/orkestra/projector/lifecycle.ex:57`
**Issue:** `import Bitwise, only: [bsl: 2]` is placed inside `next_delay/2`. It works but is
unidiomatic; module-level `import Bitwise, only: [bsl: 2]` (or `use Bitwise`) reads better and avoids
re-importing on every call. The overflow-clamp logic itself is correct (`min(attempt, 62)` then
`min(cap, ...)`), and the cap dominates well before the clamp matters.
**Fix:** Move the `import` to module scope.

### IN-02: `next_delay/2` clamp at 62 is below the documented "arbitrary precision" rationale boundary

**File:** `lib/orkestra/projector/lifecycle.ex:60-64`
**Issue:** The doc says BEAM integers are arbitrary-precision so the clamp is "purely defensive."
That is accurate, but the clamp value 62 is a magic number with no named constant. Minor readability
nit only.
**Fix:** Extract `@max_shift 62` with a one-line comment, or inline-comment the choice of 62.

### IN-03: Schema/migration timestamp and default consistency is good; one doc/return-spec nit

**File:** `lib/orkestra/projection/migration.ex:40, 68`
**Issue:** `@spec up() :: :ok` / `@spec down() :: :ok` — `Ecto.Migration`'s `create/2` and `drop/1`
do not return `:ok`; they return migration instruction terms (and the migrator ignores the return).
The spec is technically inaccurate though harmless. The `Checkpoint` schema uses `:integer` for
`last_position` while the migration uses `:bigint` (`migration.ex:45`) — fine for Postgres (Ecto
`:integer` maps to whatever the column is) but worth a comment so a reader doesn't "fix" the schema
to `:bigint` (not an Ecto field type).
**Fix:** Relax the specs to `:: term()` (or drop them), and add a one-line note on the
`:integer`-field / `:bigint`-column mapping.

---

_Reviewed: 2026-06-24_
_Reviewer: Claude (gsd-code-reviewer)_
_Depth: standard_
