---
phase: 01-foundations
fixed_at: 2026-06-24T00:00:00Z
review_path: .planning/phases/01-foundations/01-REVIEW.md
iteration: 1
findings_in_scope: 14
fixed: 14
skipped: 0
status: all_fixed
---

# Phase 01: Code Review Fix Report

**Fixed at:** 2026-06-24
**Source review:** .planning/phases/01-foundations/01-REVIEW.md
**Iteration:** 1

**Summary:**
- Findings in scope: 14 (all critical, warning, and info — `fix_scope: all`)
- Fixed: 14
- Skipped: 0

Verification after all fixes:
- `mix compile --warnings-as-errors` — passes
- `mix compile --no-optional-deps --warnings-as-errors` — passes (library still compiles without ecto)
- `mix test` — 137 tests, 0 failures (unchanged; no existing tests broke, no tests needed updating)
- `mix format` — all changed files formatted; `--check-formatted` clean

Fixes were applied in an isolated git worktree on a temporary branch and
fast-forwarded back onto the working branch. No source test changes were
required: the EventStoreDB tests are compile/wiring-only and the InMemory
subscription tests exercise only `:all`, so the per-stream and adapter-contract
fixes did not change behavior covered by existing assertions.

## Fixed Issues

### CR-01: `EventStore.impl/0` reads the wrong OTP application key (`:ultimus`)

**Files modified:** `lib/orkestra/event_store.ex`, `lib/orkestra/event_store/event_store_db.ex`
**Commits:** `1de9868` (event_store.ex), `f70b84e` (event_store_db.ex moduledoc)
**Applied fix:** Changed `Application.get_env(:ultimus, ...)` to `Application.get_env(:orkestra, __MODULE__, [])`, and updated both `@moduledoc` config examples (`event_store.ex`, `event_store_db.ex`) from `config :ultimus, ...` to `config :orkestra, ...`. Adapter configuration is now honored instead of silently falling back to InMemory.

### CR-02: EventStoreDB `extract_revision/1` never matches — `append_events` always returns `{:ok, -1}`

**Files modified:** `lib/orkestra/event_store/event_store_db.ex`
**Commit:** `f70b84e`
**Applied fix:** Kept `raw?: true` and decoded the raw `Streams.append_resp` record via Spear's generated record macros (`require Spear.Records.Streams, as: Streams`). `extract_revision/1` now returns `{:ok, rev}` for `{:success, _}` (reading `current_revision_option`: `{:current_revision, rev}` or `{:no_stream, _}` → `-1`), `{:error, :wrong_expected_version}` for that result variant, and `:error` for any unexpected shape — which is logged and surfaced as `{:error, {:unexpected_append_response, response}}` rather than a silent hardcoded `-1`. Verified against the gpb record definitions in `deps/event_store_db_gpb_protobufs/include/event_store_db_gpb_protobufs_streams.hrl` and `deps/spear/lib/spear/writing.ex`.
**Note:** No live EventStoreDB available; correctness verified by compilation (record macro names/fields resolve) and against the Spear/gpb source. Runtime behavior should be confirmed against a live instance in Phase 2 integration tests.

### CR-03: EventStoreDB append silently drops all event metadata

**Files modified:** `lib/orkestra/event_store/event_store_db.ex`
**Commit:** `f70b84e`
**Applied fix:** Replaced the ignored `metadata: event.metadata` option with `custom_metadata: Jason.encode!(event.metadata)` in `Spear.Event.new/3`, matching the real Spear API (`deps/spear/lib/spear/event.ex:186-195`, which accepts `:custom_metadata` as a binary).

### CR-04: EventStoreDB read silently drops all event metadata (guard mismatch)

**Files modified:** `lib/orkestra/event_store/event_store_db.ex`
**Commit:** `f70b84e`
**Applied fix:** Rewrote `extract_custom_metadata/1` to match a binary `custom_metadata` (`when is_binary(bin) and bin != ""`) and `Jason.decode/1` it back into the metadata map, with a `_ -> %{}` fallback. Round-trips with the CR-03 write fix.

### CR-05: InMemory per-stream subscription delivers nothing and live push ignores the subscribed stream

**Files modified:** `lib/orkestra/event_store/in_memory.ex`
**Commit:** `55e140c`
**Applied fix:** (1) `do_append/4` now stamps each event with `:stream_id` so `filter_for_stream/2` history filtering works. (2) Subscribers are stored as `{ref, pid, stream_or_all}` and live delivery filters each subscriber's events through `filter_for_stream/2`, so per-stream subscribers receive only their stream and `:all` subscribers receive everything. The `:all` path (D-01 gap-free counter, D-03 push, exclusive `> from_position`) is preserved.
**Human verification recommended:** This changes subscription delivery semantics; no existing test covers per-stream subscriptions, so confirm per-stream delivery behavior when Phase 2 adds the projector.

### WR-01: `subscribe_from_position/3` returns an unusable ref and provides no unsubscribe path

**Files modified:** `lib/orkestra/event_store/in_memory.ex`
**Commit:** `55e140c`
**Applied fix:** Subscriber state now stores the `ref` alongside `{pid, stream}`. Added a documented `unsubscribe/1` that removes the matching subscription by ref (idempotent, returns `:ok`). The returned ref is now a real handle. Updated moduledoc and the subscribe doc accordingly.

### WR-02: `load_events/2` empty-slice revision contract ambiguity

**Files modified:** `lib/orkestra/event_store.ex`
**Commit:** `1de9868`
**Applied fix:** Documented one explicit contract in the behaviour `@callback` docs: the third tuple element is always the stream's current head revision regardless of filter; `-1` is reserved for a genuinely empty stream. The existing InMemory behavior already matches this; the distinction is now spelled out so the two arities and two adapters agree.

### WR-03: `append_events` revision math relies on `length/1` of the whole stream

**Files modified:** `lib/orkestra/event_store/in_memory.ex`
**Commit:** `55e140c`
**Applied fix:** Added a defensive pattern-match assertion `^base_position = length(state.global_events)` in `do_append/4` so any divergence between the gap-free global counter and the recorded global events fails loudly rather than silently corrupting ordering. (Per-stream revision is still derived from list length; the assertion guards the load-bearing global invariant.)

### WR-04: EventStoreDB `load_events/1` and `/2` duplicate logic with divergent error handling

**Files modified:** `lib/orkestra/event_store/event_store_db.ex`
**Commit:** `f70b84e`
**Applied fix:** Factored both arities into a shared private `do_load/3` helper taking the stream options and the empty-result revision. Logging is now uniform across both arities (the incremental `/2` path no longer fails silently).

### WR-05: `to_stored_event/1` can emit `global_position: nil`

**Files modified:** `lib/orkestra/event_store/event_store_db.ex`
**Commit:** `f70b84e`
**Applied fix:** `to_stored_event/1` now builds the plain `stored_event()` map and only adds `:global_position` when a non-negative integer position is present. Plain reads (no/absent commit_position) omit the key entirely (matching the plain `stored_event()` type); subscription events with a real position carry it. No `nil` is ever emitted, avoiding downstream `ArithmeticError`.

### WR-06: `append_events` accepted `-1` inconsistently between adapters

**Files modified:** `lib/orkestra/event_store/event_store_db.ex`
**Commit:** `f70b84e`
**Applied fix:** Removed the EventStoreDB-only `-1 -> :empty` special case so the `expect` mapping matches the declared `expected_revision()` type (`non_neg_integer() | :any | :no_stream`) and the InMemory adapter. Non-negative integers map to a revision; `:no_stream` maps to `:empty`. The two adapters now accept identical inputs.

### IN-01: `bsl/2` import is inside the function body

**Files modified:** `lib/orkestra/projector/lifecycle.ex`
**Commit:** `509a595`
**Applied fix:** Moved `import Bitwise, only: [bsl: 2]` to module scope.

### IN-02: `next_delay/2` clamp magic number 62

**Files modified:** `lib/orkestra/projector/lifecycle.ex`
**Commit:** `509a595`
**Applied fix:** Extracted `@max_shift 62` module attribute with an explanatory comment and used it in the clamp.

### IN-03: migration return-spec / `:integer`-vs-`:bigint` doc nit

**Files modified:** `lib/orkestra/projection/migration.ex`
**Commit:** `2bd94da`
**Applied fix:** Relaxed `@spec up()`/`@spec down()` from `:: :ok` to `:: term()` (Ecto migration DDL functions return instruction terms, not `:ok`), and added a comment noting that the `:integer` schema field correctly maps to the `:bigint` column (`:bigint` is not an Ecto field type).

---

_Fixed: 2026-06-24_
_Fixer: Claude (gsd-code-fixer)_
_Iteration: 1_
