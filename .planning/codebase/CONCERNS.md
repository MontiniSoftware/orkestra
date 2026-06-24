# Codebase Concerns

**Analysis Date:** 2026-06-24

## Early-Stage Maturity Risk

**Version 0.1.0 — Pre-release library**
- Status: Orkestra is at version 0.1.0, indicating pre-release/experimental status
- Impact: API stability not guaranteed; breaking changes expected before 1.0.0
- Recommendation: Library not suitable for production use without accepting API churn; version bump strategy and changelog discipline needed before wider adoption

## Configuration Key Mismatch (:ultimus vs :orkestra)

**Incorrect app namespace in EventStore config**
- Files: `lib/orkestra/event_store.ex` (line 11, 45)
- Issue: Config uses `:ultimus` app key instead of `:orkestra`:
  ```elixir
  # Line 11 (documentation):
  config :ultimus, Orkestra.EventStore,
    adapter: Orkestra.EventStore.EventStoreDB
  
  # Line 45 (implementation):
  Application.get_env(:ultimus, __MODULE__, [])
  ```
- Impact: **HIGH** — EventStore configuration will not be found at runtime if users follow the docs and configure under `:orkestra` (the actual app). This is a silent failure that causes in-memory adapter to be used instead of configured adapter.
- Root cause: Likely leftover from earlier project naming ("Ultimus" → "Orkestra")
- Fix approach: Change `:ultimus` to `:orkestra` in both doc example (line 11) and runtime fetch (line 45). Verify `lib/orkestra/event_store/event_store_db.ex` line 9 has same issue.

## Machine-Specific Absolute Paths in .mcp.json

**Hard-coded developer paths**
- File: `.mcp.json`
- Issue: MCP server config contains absolute paths specific to developer machine:
  ```json
  "command": "/data/progetti/orkestra/orkestra_mcp/orkestra_mcp",
  "args": ["--project-dir", "/data/progetti/orkestra"]
  ```
- Impact: **HIGH** — Config not portable; breaks for anyone checking out the repo at different path. MCP server will not start.
- Severity: Blocks any developer using this setup file
- Fix approach: Use relative paths (e.g., `./orkestra_mcp/orkestra_mcp`) or environment variable substitution. Document MCP setup with path-agnostic instructions.

## String-to-Atom Conversion Risks (Dynamic Module Loading)

**Unsafe String.to_existing_atom in runtime deserialization**
- Files: 
  - `lib/orkestra/aggregate/root.ex` (lines 200, 221)
  - `lib/orkestra/message_bus/rabbit_mq.ex` (lines 383, 428)
- Issue: Code converts event/command type strings to atoms at runtime:
  ```elixir
  module = String.to_existing_atom("Elixir.#{type}")
  ```
  If `type` comes from external/untrusted source (e.g., RabbitMQ message), a typo or malicious input crashes with `ArgumentError`.
- Impact: **MEDIUM** — Crashes deserialization pipeline; events/commands with unknown types cannot be processed. Error is not gracefully handled in all paths.
- Where it happens:
  - Aggregate Root: Loading stored events from event store during fold (line 200)
  - Aggregate Root: Hydrating commands from deserialized map (line 221)
  - RabbitMQ handler: Deserializing metadata actor_type (line 428)
- Current handling: Wrapped in `rescue` block, but generic catch-all may hide real bugs
- Fix approach: 
  1. Use `String.to_atom/1` with allowlist validation before conversion
  2. Add explicit error logging before rescue to distinguish deserialize failures from command/event logic errors
  3. Consider schema validation: pre-validate module names against known command/event registries

## Optional Dependency Coupling (amqp, spear)

**Silent adapter fallback for missing optional deps**
- Files: `mix.exs` (lines 31, 34)
- Dependencies marked optional:
  ```elixir
  {:amqp, "~> 4.1", optional: true},
  {:spear, "~> 1.4", optional: true}
  ```
- Issue: If user configures RabbitMQ adapter but hasn't installed `:amqp`, the code will fail at runtime with missing module error. Similarly for `:spear` with EventStoreDB.
- Impact: **MEDIUM** — No compile-time safety; runtime failures if adapter is misconfigured. Poor DX.
- Current state: No dependency guards or clear error messages
- Fix approach: 
  1. Add compile-time guards in adapter modules (e.g., check `Code.ensure_loaded/1` or use `if Mix.target() == :host` guards)
  2. Document required dependencies per adapter clearly
  3. Consider adding a mix task to validate setup: `mix orkestra.validate_config`

## Snapshot Revision Bug in Root.execute

**Incorrect snapshot event count in retry scenario**
- File: `lib/orkestra/aggregate/root.ex` (lines 148–157, 180)
- Issue: When a snapshot is loaded:
  ```elixir
  {:ok, %{state: state, revision: rev}} ->
    {state, rev, rev + 1, true}  # ← snapshot_events = rev + 1
  ```
  Then total_event_count calculated as:
  ```elixir
  total_event_count = snapshot_events + length(events)
  ```
  But `snapshot_events` is set to `rev + 1`, which is the event count **up to the snapshot**, not the revision. If snapshot was taken at revision 99, `snapshot_events = 100`, but only 99 actual events were replayed. This off-by-one error breaks snapshot decision logic.
- Impact: **MEDIUM** — Snapshots taken at wrong intervals or not at all if event count calculation is off. In retry loops, total_event_count becomes invalid.
- Scenario:
  1. 100 events accumulated, snapshot taken at rev 99 (100 total events)
  2. Set `snapshot_events = 100`
  3. Load 5 more events after snapshot
  4. Calculate `total_event_count = 100 + 5 = 105` (correct by coincidence)
  5. But on retry if snapshot is stale, count is recomputed with wrong basis
- Fix approach: Track actual event count correctly. Use `revision + 1` as event count (0-indexed revision), not `rev + 1` as "events seen so far". Or: store event count explicitly in snapshot data.

## Snapshot Deserialization Error Suppression

**Snapshot failure silently downgrades to full replay**
- File: `lib/orkestra/event_store/snapshot.ex` (lines 36–46)
- Issue: If snapshot deserialization fails:
  ```elixir
  {:ok, events, _} ->
    latest = List.last(events)
    case deserialize_state(latest.data) do
      {:ok, state, revision} ->
        {:ok, %{state: state, revision: revision}}
      {:error, _} = err ->
        Logger.warning("Failed to deserialize snapshot", ...)
        err
    end
  ```
  Callers receive `{:error, _}` but then in Root.execute (line 149), this is handled as:
  ```elixir
  {:error, :no_snapshot} ->
    {aggregate.init_state(), -1, 0, false}
  ```
  But the error is **not** `:no_snapshot`, it's a deserialization error. This causes Aggregate.Root to crash with `FunctionClauseError`.
- Impact: **HIGH** — Corrupted snapshots crash the system. No graceful recovery path.
- Fix approach: 
  1. Change snapshot deserialization errors to return `:no_snapshot` (degrade to full replay)
  2. Or: catch all errors in Root.execute snapshot loading
  3. Log actual deserialize failure for forensics before downgrading

## Race Condition in Retry Logic Edge Case

**Concurrency conflict retry may exceed bounds**
- File: `lib/orkestra/aggregate/root.ex` (lines 99–139)
- Issue: Retry loop increments attempt counter, but if retry logic runs out of retries:
  ```elixir
  {:error, :wrong_expected_version} ->
    Logger.error("Concurrency conflict exhausted retries", ...)
    {:error, :concurrency_conflict}
  ```
  But if **multiple processes execute concurrently** on same stream, all N processes may simultaneously hit max_retries on the same event. This is not a bug per se (retries work), but callers don't know if `:concurrency_conflict` is transient or indicates a real conflict pattern.
- Impact: **LOW** — Edge case; documented behavior. But error reason doesn't distinguish "truly concurrent" from "hit retry limit during normal load".
- Observation: This is acceptable if documented; not a bug.

## Test Coverage Gaps

### Missing aggregate/root tests
- What's not tested: Core pipeline (load → fold → decide → append → publish)
  - Snapshot loading and usage
  - Snapshot edge cases (corruption, missing snapshot stream)
  - Retry logic with actual concurrency
  - Event hydration from stored format
  - Command hydration from RabbitMQ deserialized format
- Files: `lib/orkestra/aggregate.ex`, `lib/orkestra/aggregate/root.ex`, `lib/orkestra/event_store/snapshot.ex`
- Risk: **HIGH** — Core execution engine untested; regressions in load/fold/decide flow not caught
- Priority: Critical before production use

### Missing event_store tests
- What's not tested: 
  - `Orkestra.EventStore.EventStoreDB` adapter (gRPC calls, connection handling)
  - Optimistic concurrency with real `:wrong_expected_version` scenarios
  - Stream not found vs empty stream behavior
  - Event hydration and field mapping
- Files: `lib/orkestra/event_store/event_store_db.ex`, `lib/orkestra/event_store/in_memory.ex`
- Risk: **MEDIUM** — In-memory works, but EventStoreDB adapter untested

### Missing message_bus/rabbitmq tests
- What's not tested: RabbitMQ integration
  - Serialization/deserialization round-trip
  - Dead-letter queue behavior
  - Retry count extraction from headers
  - Topic-to-queue binding
  - Connection failure and recovery
- Files: `lib/orkestra/message_bus/rabbit_mq.ex`
- Risk: **MEDIUM** — Distributed message bus untested; first RabbitMQ deployment will be discovery phase

### Missing introspection tests
- What's not tested: 
  - Introspection.discover/1 with real file structures
  - Module name extraction with edge cases (nested modules, atoms with dots)
  - Regex extraction of params/fields (multiline, edge cases)
  - Build domain map correctness
- Files: `lib/orkestra_mcp/introspection.ex`
- Risk: **MEDIUM** — MCP code generation depends on correct introspection; wrong module names or missing handlers can go unnoticed

## Fragile Static Introspection Assumptions (orkestra_mcp)

**Regex-based code parsing is brittle**
- Files: `orkestra_mcp/lib/orkestra_mcp/introspection.ex` (lines 45–173)
- Issue: Code discovery via regex matching on file content:
  ```elixir
  if content =~ ~r/use\s+Orkestra\.Command/ do
    case extract_module_name(content) do
      nil -> acc
      module_name -> ...
    end
  end
  ```
  This breaks if:
  - Code is formatted differently (extra whitespace, line breaks)
  - Comment contains `use Orkestra.Command` (false positive)
  - String literal contains the pattern (false positive)
  - Multi-line macros with unmatched whitespace
- Examples that break:
  ```elixir
  # Breaks: whitespace after use
  use  Orkestra.Command
  
  # Breaks: in comment
  # use Orkestra.Command for this

  # Breaks: in string
  "use Orkestra.Command to define..."
  
  # Breaks: continuation
  use Orkestra.
    Command
  ```
- Impact: **MEDIUM** — Code generation may miss modules or hallucinate false positives. Users don't realize their handlers weren't discovered.
- Fix approach: 
  1. Use proper Elixir AST parsing instead of regex (e.g., `Code.string_to_quoted/2`)
  2. Validate extracted module names exist and are actually modules
  3. Add introspection test cases for edge cases

## Snapshot Interval Calculation Edge Case

**Snapshot always taken on boundary, no jitter**
- File: `lib/orkestra/event_store/snapshot.ex` (lines 18–21)
- Issue: Logic takes snapshot when `rem(total_event_count, interval) == 0`:
  ```elixir
  interval != :never and total_event_count > 0 and rem(total_event_count, interval) == 0
  ```
  If many aggregates have same interval (e.g., 100), all will snapshot simultaneously at event count 100, 200, etc. This can cause thundering herd writes to event store.
- Impact: **LOW** — Not a correctness issue, but can cause latency spikes. Only matters at scale.
- Recommendation: Consider adding jitter to snapshot timing in future versions

## Error Context Loss in RabbitMQ Handler

**Handler exceptions lose root cause context**
- File: `lib/orkestra/message_bus/rabbit_mq.ex` (lines 213–239)
- Issue: Deserialize errors and handler errors conflated:
  ```elixir
  result =
    try do
      case deserialize(body) do
        {:ok, envelope} -> handler.handle(envelope)
        {:error, reason} -> {:error, {:deserialize, reason}}
      end
    rescue
      e -> {:error, {:exception, Exception.message(e)}}
    end

  case result do
    :ok -> AMQP.Basic.ack(channel, meta.delivery_tag)
    {:error, {:deserialize, reason}} ->
      Logger.error("Deserialize failed, sending to DLQ", ...)
      AMQP.Basic.reject(channel, meta.delivery_tag, requeue: false)
    {:error, reason} ->
      handle_failure(channel, meta, handler, reason, retry_count, max_retries)
  end
  ```
  If deserialization error is wrapped as `{:exception, ...}` by the catch-all, it goes to `handle_failure` (retry) instead of DLQ. But deserialization errors should not be retried—they need manual intervention.
- Impact: **MEDIUM** — Malformed messages retry infinitely before going to DLQ, wasting queue capacity
- Fix approach: Distinguish deserialization errors from handler errors more explicitly; don't retry deserialize failures

## Atom Exhaustion Risk in RabbitMQ Deserialization

**String.to_existing_atom fallback to String.to_atom**
- File: `lib/orkestra/message_bus/rabbit_mq.ex` (lines 454–458)
- Issue: Atomize keys with fallback:
  ```elixir
  atom_key =
    try do
      String.to_existing_atom(k)
    rescue
      ArgumentError -> String.to_atom(k)
    end
  ```
  If malicious/untrusted message contains arbitrary string keys, this creates unbounded atoms. Atoms are not garbage-collected in Erlang; atom exhaustion is a DoS vector.
- Impact: **MEDIUM** — If RabbitMQ messages from untrusted source, attacker can exhaust VM atom table and crash node
- Fix approach: Use `:ephemeral_atoms => false` guard in deserialization; only atomize known key names

## Missing Event Handler Subscription Timeout

**EventHandler subscription has no timeout**
- File: `lib/orkestra/event_handler.ex` (lines 112–136)
- Issue: If message bus subscription fails, handler retries indefinitely:
  ```elixir
  def handle_info(:subscribe, state) do
    ...
    if Enum.all?(results, &(&1 == :ok)) do
      {:noreply, %{state | subscribed: true}}
    else
      Logger.warning("Event handler subscribe failed, retrying", ...)
      Process.send_after(self(), :subscribe, 5_000)
      {:noreply, state}
    end
  end
  ```
  If message bus is permanently down (configuration error), handler spins indefinitely, never starts accepting events. No application-level health check sees this.
- Impact: **MEDIUM** — Silent failure mode: handler process runs but never subscribes. Monitoring needs to check subscription state.
- Fix approach: Add exponential backoff with max backoff cap; or fail early if subscription fails N times

## Version Mismatch Between orkestra and orkestra_mcp

**No coordinated version bumping**
- Files: `mix.exs`, `orkestra_mcp/mix.exs`
- Issue: orkestra is 0.1.0, orkestra_mcp likely independent version. If APIs change in orkestra, orkestra_mcp may not track version bumps.
- Impact: **LOW** — Mostly organizational; relevant when releasing, not a runtime bug
- Recommendation: Document version coordination strategy; consider monorepo versioning

## Missing Graceful Shutdown for EventStore Connection

**EventStoreDB adapter has no cleanup**
- File: `lib/orkestra/event_store/event_store_db.ex`
- Issue: `Spear.Connection` is started externally and never explicitly stopped by EventStore adapter. If connection process dies, EventStore has no recovery mechanism.
- Impact: **LOW** — Spear connection supervisor should handle recovery, but if not configured correctly, EventStore silently fails
- Recommendation: Document Spear.Connection setup and include health check

---

*Concerns audit: 2026-06-24*
