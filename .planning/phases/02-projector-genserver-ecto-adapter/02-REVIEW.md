---
phase: 02-projector-genserver-ecto-adapter
reviewed: 2026-06-24T00:00:00Z
depth: standard
files_reviewed: 10
files_reviewed_list:
  - lib/orkestra/projection/storage/postgres.ex
  - lib/orkestra/projector/gen_server.ex
  - test/orkestra/projection/storage/postgres_test.exs
  - test/orkestra/projection/storage/postgres_adapter_tdd_test.exs
  - test/orkestra/projector/gen_server_test.exs
  - test/support/projection_test_repo.ex
  - test/support/projection_read_model.ex
  - test/support/projection_migrations.ex
  - test/test_helper.exs
  - mix.exs
findings:
  critical: 4
  warning: 2
  info: 3
  total: 9
status: issues_found
---

# Phase 02: Code Review Report

**Reviewed:** 2026-06-24
**Depth:** standard
**Files Reviewed:** 10
**Status:** issues_found

## Summary

Phase 2 delivers a Projector GenServer runtime and a Postgres/Ecto storage adapter. The
architecture is sound — deferred init via `send(self(), :load_checkpoint)`, atomic co-commit
via `Ecto.Multi.append`, halt-and-stay-alive on exhaustion — and the happy path is correct.
However, four blockers require attention before this code is production-ready:

1. The GenServer module is not guarded by `Code.ensure_loaded?` but directly uses Ecto
   struct literals and `Ecto.Multi` functions, causing a compile error when Ecto is absent.
2. Both `Orkestra.Projection.Migration` and `Orkestra.Test.ProjectionMigrations` use
   migration version `1` against the same `migration_source` table, so the read-model
   table migration is silently skipped in `GenServerTest`.
3. `Postgres.write/4` has an incomplete `case` clause — a handler returning
   `{:ok, non_Ecto.Multi_value}` raises `CaseClauseError`, crashing the GenServer and
   entering an infinite supervisor restart loop.
4. The retry mechanism enqueues `{:retry_event, event_N}` at the **end** of the mailbox
   via `Process.send_after`, but live events (N+1, N+2, …) are already in the mailbox and
   are processed first. This breaks the module's own "strictly sequential in-order
   processing" guarantee and allows checkpoint regression when a retry eventually commits.

---

## Critical Issues

### CR-01: `GenServer` module references Ecto struct literals without a compile-time guard

**File:** `lib/orkestra/projector/gen_server.ex:226,307`

**Issue:** `Orkestra.Projector.GenServer` is defined at the top level with no
`Code.ensure_loaded?` guard. It contains struct literal expressions `%Checkpoint{…}` (line 226)
and `%DeadLetter{…}` (lines 307–314). Both `Checkpoint` and `DeadLetter` are wrapped in
`if Code.ensure_loaded?(Ecto.Schema) do` guards in their own files, so they do not exist when
Ecto is absent. Elixir expands struct literals at compile time — if the module does not exist,
the compiler raises `(CompileError) … __struct__/0 is undefined`. The library therefore fails
to compile without the optional `:ecto` dependency, contradicting the `optional: true`
declaration in `mix.exs`.

The `Postgres` adapter wraps its entire body in `if Code.ensure_loaded?(Ecto.Multi) do`,
demonstrating the intended pattern. `GenServer` omits this guard entirely.

**Fix:** Wrap the whole `GenServer` module body in the same guard:

```elixir
if Code.ensure_loaded?(Ecto.Multi) do
  defmodule Orkestra.Projector.GenServer do
    # … unchanged …
  end
end
```

---

### CR-02: Migration version collision — `ProjectionMigrations` (v1) is silently skipped in `GenServerTest`

**File:** `test/orkestra/projector/gen_server_test.exs:27-43` and
`test/support/projection_migrations.ex:28`

**Issue:** `GenServerTest.setup_all` runs two migrations sequentially into the same
`ProjectionRepo`, whose `migration_source` is configured as
`"orkestra_test_projection_schema_migrations"` in `test_helper.exs`:

```elixir
# Line 27-32
Ecto.Migrator.run(ProjectionRepo, [{1, Orkestra.Projection.Migration}], :up, all: true)

# Line 34-39
Ecto.Migrator.run(ProjectionRepo, [{ProjectionMigrations.version(), ProjectionMigrations}], :up, all: true)
```

`ProjectionMigrations.version()` returns `1` (same as the tuple `{1, Orkestra.Projection.Migration}`
in the first call). `Ecto.Migrator.run` tracks migrations by version number in the shared
`migration_source` table. After the first call, version `1` is recorded as already run. The
second call finds version `1` present and skips `ProjectionMigrations` — the
`projection_read_models` table is never created. Every test that writes to that table will
fail with `(Postgrex.Error) relation "projection_read_models" does not exist`.

`PostgresTest` runs only `ProjectionMigrations` in its `setup_all` without the Projection
system migration, so when `PostgresTest` runs first it records version `1` for
`ProjectionMigrations` — and then `GenServerTest` would skip `Orkestra.Projection.Migration`,
losing the checkpoint and dead-letter tables instead. Whichever module runs first determines
which migration is silently dropped.

**Fix:** Give `ProjectionMigrations` a version number that cannot collide with the library's
own migration version:

```elixir
# test/support/projection_migrations.ex
@version 20_000_101_000_001  # timestamp-style, well above any library-internal version
```

Update the tuple in `postgres_test.exs` and `gen_server_test.exs` accordingly:

```elixir
Ecto.Migrator.run(
  ProjectionRepo,
  [{ProjectionMigrations.version(), ProjectionMigrations}],
  :up,
  all: true
)
```

(No change needed at the call site since it already uses `ProjectionMigrations.version()`.)

---

### CR-03: `Postgres.write/4` — incomplete `case` clause crashes on unexpected handler return

**File:** `lib/orkestra/projection/storage/postgres.ex:80-83`

**Issue:** The `case` on the handler's return value handles only two shapes:

```elixir
case handler.(projector_name, event, position) do
  {:ok, multi} when is_struct(multi, Ecto.Multi) -> {:ok, multi}
  {:error, reason} -> {:error, reason}
end
```

If the handler returns `{:ok, nil}`, `{:ok, []}`, `{:ok, :some_atom}`, or any tuple other
than `{:ok, %Ecto.Multi{}}` or `{:error, _}`, Elixir raises `(CaseClauseError) no case
clause matching {:ok, nil}`. Because `write/4` is called from the GenServer's
`handle_info`, the exception propagates out of `handle_info`, terminates the GenServer
process, and triggers a supervisor restart. The restart immediately delivers the same event
again (the checkpoint has not advanced), creating an infinite restart loop.

**Fix:** Add a catch-all clause that converts unexpected returns into a structured error:

```elixir
case handler.(projector_name, event, position) do
  {:ok, multi} when is_struct(multi, Ecto.Multi) ->
    {:ok, multi}

  {:error, reason} ->
    {:error, reason}

  other ->
    {:error, {:invalid_handler_return, other}}
end
```

---

### CR-04: Retry mechanism breaks sequential in-order delivery — checkpoint can regress

**File:** `lib/orkestra/projector/gen_server.ex:293`

**Issue:** When event N fails, `handle_failure/3` calls:

```elixir
Process.send_after(self(), {:retry_event, event}, delay)
```

This places `{:retry_event, event_N}` at the **end** of the process mailbox after `delay`
milliseconds. During that delay, the event store subscription (InMemory, or Spear in
production) continues pushing events N+1, N+2, … directly into the mailbox via `send/2`.
Those events arrive and are processed **before** `{:retry_event, event_N}` is consumed.
If events N+1, N+2 succeed, their checkpoint upserts advance `last_position` to N+2. When
the retry of event N eventually executes and succeeds, its checkpoint upsert sets
`last_position` to N via `on_conflict: [set: [last_position: position, …]]` — regressing the
checkpoint from N+2 to N. On the next restart, events N+1 and N+2 will be re-processed,
violating idempotency guarantees (the unique index on `projection_read_models` would
prevent duplicate rows but the checkpoint is now stale).

The module docstring claims "strictly sequentially in-order processing via mailbox" and
"PROJ-04", but this guarantee only holds when there are no failures. The test suite does
not expose this because retry-path tests (`ERR-04`, `STORE-03`) inject only a single event
and do not append further events during the retry window.

**Fix — pause subscription on failure, resume on success (recommended):**

Introduce a `:paused` state field. When entering retry, call
`event_store.unsubscribe(subscription_ref)` (or a similar "pause" mechanism) to stop
receiving new events until the retry succeeds or the event is parked. Restore the
subscription after the event is committed or halted. This prevents N+1 events from
entering the mailbox during the retry window.

**Minimal fix — flush unknown messages on retry:**

If pausing is not feasible in this phase, at a minimum document the known ordering
violation prominently, remove the claim of "strictly sequential in-order processing" when
failures occur, and guard the checkpoint upsert so it never regresses:

```elixir
# Only update last_position if the new value is greater than the current persisted value
on_conflict: [set: [
  last_position:
    fragment("GREATEST(projection_checkpoints.last_position, ?)", ^position),
  halted: false,
  updated_at: ^now
]]
```

This does not fix out-of-order read-model rows but does prevent checkpoint regression.

---

## Warnings

### WR-01: `Postgres.reset/2` discards `repo.delete_all` return and never returns `{:error, term()}`

**File:** `lib/orkestra/projection/storage/postgres.ex:107-108`

**Issue:** `repo.delete_all/1` returns `{count, nil}` on success and raises on a DB-level
error. The current implementation unconditionally returns `:ok`:

```elixir
repo.delete_all(from(s in schema, where: s.projector_name == ^projector_name))
:ok
```

The `Orkestra.Projection.Storage` behaviour callback declares
`reset/2 :: :ok | {:error, term()}`. This implementation never exercises the error branch —
callers expecting `{:error, _}` to handle DB failures will instead receive an unhandled
exception. If the intent is to convert DB errors to `{:error, term()}`, a `rescue` block is
needed. If the intent is to let exceptions propagate, the callback spec should be tightened
to `:: :ok` (but that changes the public contract).

**Fix:**

```elixir
def reset(projector_name, opts) do
  repo = Keyword.fetch!(opts, :repo)
  schema = Keyword.fetch!(opts, :schema)

  try do
    repo.delete_all(from(s in schema, where: s.projector_name == ^projector_name))
    :ok
  rescue
    e -> {:error, Exception.message(e)}
  end
end
```

---

### WR-02: Sandbox allow / `:load_checkpoint` scheduling window is a true race

**File:** `test/orkestra/projector/gen_server_test.exs:157-158` (all six tests)

**Issue:** The deferred init pattern (`send(self(), :load_checkpoint)` in `init/1`) is
intended to ensure `Sandbox.allow/3` is called before the first `Repo` access. The pattern
works in practice because `start_supervised!` is synchronous and the BEAM scheduler
typically does not preempt the test process before the next line executes. However, the
guarantee is scheduling-heuristic, not structural. The BEAM is a preemptive runtime; if the
GenServer process is scheduled immediately after `init/1` returns (e.g., on a multi-core
system or under load), it processes `:load_checkpoint` before `Sandbox.allow/3` executes,
causing a sandbox ownership error: `(DBConnection.OwnershipError) cannot find ownership
process for …`.

The correct structural fix is synchronous acknowledgement — the test process confirms the
allow is in place before the GenServer processes its first message.

**Fix:** After `Sandbox.allow/3`, use `GenServer.call/2` with a no-op cast to flush the
mailbox synchronously, ensuring `:load_checkpoint` has been fully processed before the
test proceeds:

```elixir
pid = start_supervised!({ProjectorGenServer, test_config(projector_name)})
Ecto.Adapters.SQL.Sandbox.allow(ProjectionRepo, self(), pid)
# Synchronize: wait for :load_checkpoint to complete before the test proceeds.
# :sys.get_state/1 blocks until the GenServer is idle (no pending messages being processed).
:sys.get_state(pid)
```

Alternatively, add a `:ping` `GenServer.call/3` to `ProjectorGenServer` for test use only.

---

## Info

### IN-01: Test comment in `ERR-04` misrepresents `max_retries` semantics

**File:** `test/orkestra/projector/gen_server_test.exs:339`

**Issue:** The comment reads:

```
# max_retries: 2 → attempt 1 retries, attempt 2 retries, attempt 3 parks
```

`Lifecycle.classify/2` uses `attempts < config.max_retries` (strict less-than). With
`max_retries: 2`, attempt 1 retries (`1 < 2`), attempt 2 parks (`2 < 2` is false). There
are 2 total attempts (original + 1 retry), not 3. The assertion `dead_letter.attempts == 2`
is correct; only the comment is wrong. The same semantic confusion applies to the
`Lifecycle.should_halt?` doc example at `lib/orkestra/projector/lifecycle.ex:104`.

**Fix:** Correct the comment:

```elixir
# max_retries: 2 → attempt 1 retries (1 < 2), attempt 2 parks (2 < 2 is false).
# Total attempts: 2.  dead_letter.attempts == 2.
```

---

### IN-02: `Lifecycle.next_delay/2` docstring examples use 0-indexed attempts but `GenServer` always passes 1-indexed values

**File:** `lib/orkestra/projector/lifecycle.ex:57-59` and
`lib/orkestra/projector/gen_server.ex:283`

**Issue:** The `next_delay` docstring shows `next_delay(0, …) = 500`. The GenServer calls
`next_delay(new_attempts, …)` where `new_attempts = state.attempts + 1`, so the minimum
value passed is `1`. The first retry therefore gets `base * 2^1 = 2 × base` rather than
`base * 2^0 = base`. The backoff is still monotonically increasing and capped, so this
causes no incorrect termination, but the docstring examples are never exercised in
production.

**Fix:** Either update the docstring to start examples at 1 (reflecting actual usage), or
adjust the call site to pass `new_attempts - 1` to match the intended 0-indexed semantics.

---

### IN-03: `postgres_adapter_tdd_test.exs` step-prefix test validates the test handler, not the adapter

**File:** `test/orkestra/projection/storage/postgres_adapter_tdd_test.exs:36-52`

**Issue:** The test "all Multi step names from handler are prefixed with `:read_model_`"
constructs a handler that already uses `:read_model_insert`, then asserts the output uses
that prefix. The adapter (`Postgres.write/4`) performs no enforcement of the
`:read_model_` prefix convention — it transparently returns whatever Multi the handler
provides. The test verifies that the test's own handler follows the convention, not that
the adapter enforces or validates it. A handler returning a step named `:foo` would pass
`write/4` without issue and this test would not detect it.

**Fix (documentation):** Either remove this test and replace it with a comment noting that
the prefix is a convention enforced at code-review time (not runtime), or add a genuine
validation step in `write/4` that checks all step names in the returned Multi:

```elixir
names = Ecto.Multi.to_list(multi) |> Enum.map(&elem(&1, 0))
if Enum.all?(names, fn n -> String.starts_with?(Atom.to_string(n), "read_model_") end) do
  {:ok, multi}
else
  {:error, {:invalid_step_names, Enum.reject(names, &String.starts_with?(Atom.to_string(&1), "read_model_"))}}
end
```

---

_Reviewed: 2026-06-24_
_Reviewer: Claude (gsd-code-reviewer)_
_Depth: standard_
