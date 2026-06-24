# Orkestra — Developer Guide

Lightweight CQRS/ES toolkit for Elixir. Pluggable message bus, event store, and OpenTelemetry tracing.

Version: 0.1.0 | Elixir: ~> 1.18 | License: MIT

---

## File Map

```
lib/orkestra.ex                      # Namespace module (docs only)
lib/orkestra/
├── command.ex                       # Command macro + behaviour (DSL: `param`)
├── event.ex                         # Event macro + behaviour (DSL: `field`)
├── metadata.ex                      # Metadata struct (correlation/causation chain)
├── command_envelope.ex              # Command dispatch wrapper (lifecycle, retries)
├── event_envelope.ex                # Event publish wrapper (per-handler tracking)
├── command_handler.ex               # GenServer macro: auto-subscribe to commands
├── event_handler.ex                 # GenServer macro: auto-subscribe to events
├── telemetry.ex                     # OpenTelemetry spans + Logger metadata + AMQP context
├── message_bus.ex                   # Behaviour + topic derivation logic
├── message_bus/
│   ├── handler.ex                   # Handler behaviour (`handle/1`)
│   ├── pub_sub.ex                   # In-process adapter (Phoenix.PubSub)
│   └── rabbit_mq.ex                # Distributed adapter (AMQP 4.x)
├── event_store.ex                   # EventStore behaviour
├── event_store/
│   ├── in_memory.ex                 # Agent-based (test)
│   ├── event_store_db.ex            # EventStoreDB via Spear (production)
│   └── snapshot.ex                  # Snapshot load/save/decision logic
├── aggregate.ex                     # Aggregate behaviour (pure functions)
└── aggregate/
    └── root.ex                      # Imperative shell: load→fold→decide→append→publish

test/orkestra/
├── command_test.exs                 # Command validation, metadata, param definitions
├── event_test.exs                   # Event validation, from_command, from_event chains
├── metadata_test.exs                # Metadata creation and derivation
├── command_envelope_test.exs        # Envelope lifecycle, retries, middleware context
├── event_envelope_test.exs          # Handler registration, status transitions
├── command_handler_test.exs         # Subscription, execution, error handling
├── event_handler_test.exs           # Single/multi/wildcard events, retries, dead-letter
├── message_bus_test.exs             # topic_for/1 derivation with and without app_prefix
└── message_bus/
    └── pub_sub_test.exs             # Dispatch, publish, retry, dead-letter
```

---

## Architecture at a Glance

```
Command ──→ CommandEnvelope ──→ MessageBus.dispatch ──→ CommandHandler.execute
                                                              │
Event   ──→ EventEnvelope  ──→ MessageBus.publish  ──→ EventHandler.handle_event (fan-out)
                                                              │
                                                    ┌─────────┘
                                                    v
                                        Aggregate.Root.execute
                                  load → fold → decide → append → publish
                                            │              │
                                      EventStore     EventStore
                                     (load_events)  (append_events)
                                            │
                                       Snapshot (optional)
```

**Key design principle:** Aggregates are pure functions (no I/O). `Aggregate.Root` is the imperative shell that handles all side effects (store, bus, tracing).

---

## Dependencies

| Dep | Version | Required | Purpose |
|-----|---------|----------|---------|
| jason | ~> 1.2 | Yes | JSON serialization (RabbitMQ messages) |
| phoenix_pubsub | ~> 2.0 | Yes | In-process message bus adapter |
| opentelemetry_api | ~> 1.5 | Yes | Tracing span creation |
| amqp | ~> 4.1 | Optional | RabbitMQ adapter |
| spear | ~> 1.4 | Optional | EventStoreDB adapter (gRPC) |
| opentelemetry_process_propagator | ~> 0.3 | Optional | Cross-process OTel propagation (RabbitMQ) |

---

## Core Abstractions

### 1. Command (`lib/orkestra/command.ex`)

A command = intent to change the system. Defined via `use Orkestra.Command` + `param` DSL.

**Generated struct:** `%Module{id, type, params, metadata}`

- `new/2` — validates required params, runs custom `validate/1`, generates ID, attaches `Metadata`
- `new!/2` — raises on failure
- `param_definitions/0` — returns declared params as `[{name, type, opts}]`
- `validate/1` — overridable callback, returns `:ok | {:error, reason}`
- ID generation: `crypto.strong_rand_bytes(12)` → base32 hex (20 chars)
- String keys auto-normalized to atoms via `String.to_existing_atom/1`

### 2. Event (`lib/orkestra/event.ex`)

An event = immutable fact that happened. Defined via `use Orkestra.Event` + `field` DSL.

**Generated struct:** `%Module{id, type, data, metadata, occurred_at}`

- `new/2` — validates required fields, generates ID, sets `occurred_at: DateTime.utc_now()`
- `from_command/2` — derives metadata from command (preserves `correlation_id`, sets `causation_id` = command.id)
- `from_event/2` — derives metadata from parent event (chains causation)
- `field_definitions/0` — returns declared fields as `[{name, type, opts}]`

### 3. Metadata (`lib/orkestra/metadata.ex`)

Lightweight context propagated through the entire pipeline.

**Struct fields:**
- `correlation_id` — root trace ID (links entire chain)
- `causation_id` — what directly caused this message
- `actor_id` — who initiated it (user ID, system name)
- `actor_type` — `:user | :system | :expert | :scheduler`
- `source` — origin string (e.g., "web", "api", "rabbitmq")
- `issued_at` — creation timestamp

**Functions:**
- `new/1` — fresh metadata with generated `correlation_id`, accepts `actor_id`, `actor_type`, `source`, `causation_id`
- `derive/2` — child metadata preserving `correlation_id`, setting new `causation_id`

### 4. Envelopes

**CommandEnvelope** (`lib/orkestra/command_envelope.ex`) — dispatch context wrapper.

- Status: `:pending → :dispatched → :succeeded | :failed | :rejected`
- Tracks `attempts`, `max_retries`, `result`, `error`, `dispatched_at`, `completed_at`
- `retryable?/1` — true if `:failed` and `attempts <= max_retries`
- `middleware_context` — shared map for middleware to store data (`put_context/2`, `get_context/2`)

**EventEnvelope** (`lib/orkestra/event_envelope.ex`) — publish context wrapper.

- Status: `:pending → :published → :handled | :partially_handled | :failed`
- Per-handler tracking: `handlers` map with statuses `:pending → :processing → :succeeded | :failed | :skipped`
- `register_handler/2`, `mark_handler_succeeded/2`, `mark_handler_failed/2`

### 5. Handlers

**CommandHandler** (`lib/orkestra/command_handler.ex`) — `use Orkestra.CommandHandler, command: MyCommand`

- GenServer that auto-subscribes on init via `bus.subscribe_command(topic, __MODULE__)`
- Implements `MessageBus.Handler.handle/1`
- User implements `execute(command, metadata)` → `:ok | {:ok, result} | {:error, reason}`
- Wraps execution in OTel span `"orkestra.command.handle"`, sets Logger metadata
- Subscription retry: 5 seconds on failure

**EventHandler** (`lib/orkestra/event_handler.ex`) — multiple subscription modes:
- `event: MyEvent` — single event
- `events: [EventA, EventB]` — multiple events
- `topic: "orders.events.#"` — wildcard pattern (`*` = one segment, `#` = multi-segment)
- `max_retries: N` — per-handler retry limit (default: 3)

User implements `handle_event(event, metadata)` → `:ok | {:error, reason}`

### 6. Message Bus

**Behaviour** (`lib/orkestra/message_bus.ex`):
- `dispatch/1` — point-to-point (one handler per command)
- `publish/1` — fan-out (many handlers per event)
- `subscribe_command/2`, `subscribe_event/3`
- `impl/0` — returns configured adapter (config key: `:orkestra, Orkestra.MessageBus, adapter:`)
- `topic_for/1` — module → dot-separated topic, stripping configured `app_prefix`

**PubSub adapter** (`lib/orkestra/message_bus/pub_sub.ex`):
- Synchronous dispatch, immediate retries (recursive)
- Commands: one handler per topic (competing consumers)
- Events: list of handlers per topic (fan-out)
- Dead-letter: broadcast on `"orkestra:deadletter"` topic
- Topic matching: supports `*` and `#` wildcards (RabbitMQ-style)
- Retry logic: `attempt_with_retry/4` — recursive with configurable max

**RabbitMQ adapter** (`lib/orkestra/message_bus/rabbit_mq.ex`):
- Exchanges: `orkestra.commands` (topic), `orkestra.events` (topic), `orkestra.deadletter` (topic)
- Command queues: `"orkestra.cmd.#{topic}"` (competing consumers)
- Event queues: `"orkestra.evt.#{topic}.#{handler_name}"` (fan-out, per-handler)
- All queues: `durable: true`, DLX configured, `prefetch_count: 10`
- Retry tracking via `x-death` headers (native RabbitMQ), `x-max-retries` custom header
- Serialization: JSON via Jason, with `__type__` discriminator
- OTel: W3C trace context injected into AMQP headers, extracted on consume
- Publishes with `persistent: true`, `content_type: "application/json"`

### 7. Event Store

**Behaviour** (`lib/orkestra/event_store.ex`):
- `load_events/1`, `load_events/2` (from revision), `append_events/3` (with optimistic concurrency)
- Types: `stored_event = %{id, type, data, metadata, stream_revision}`
- `expected_revision`: `:any | :no_stream | non_neg_integer()`

**InMemory** (`lib/orkestra/event_store/in_memory.ex`):
- Agent-based, `%{stream_id => [events]}`
- `reset!/1` for test cleanup

**EventStoreDB** (`lib/orkestra/event_store/event_store_db.ex`):
- Spear gRPC client
- Maps `:no_stream`/`-1` → `:empty`, handles `ExpectationViolation`

**Snapshot** (`lib/orkestra/event_store/snapshot.ex`):
- Stream: `"snapshot-#{stream_id}"`
- State serialized as `Base.encode64(:erlang.term_to_binary(state))`
- `should_snapshot?/2` — checks aggregate's `snapshot_every/0` callback and event count modulo

### 8. Aggregate

**Behaviour** (`lib/orkestra/aggregate.ex`) — pure functions only:
- `init_state/0` — initial state
- `stream_id/1` — derives stream ID from command
- `evolve/2` — pure fold (state + event → new state)
- `decide/2` — pure decision (state + command → events or error)
- `snapshot_every/0` — optional, interval or `:never`

**Root** (`lib/orkestra/aggregate/root.ex`) — imperative shell:
- `execute/3` — full pipeline: load → fold → decide → append → publish → snapshot
- Options: `max_retries:` (default 3), `publish:` (default true)
- Optimistic concurrency: auto-retries on `:wrong_expected_version` (re-loads, re-folds, re-decides)
- Hydration: reconstructs Command/Event structs from deserialized maps (RabbitMQ path)
- Publishing errors are rescued (don't fail the aggregate)
- Snapshotting checked after successful append

### 9. Telemetry (`lib/orkestra/telemetry.ex`)

- `with_span/3` — wraps function in named OTel span, auto-sets error status
- `command_attrs/1`, `event_attrs/1`, `metadata_attrs/1` — span attribute builders
- `set_logger_metadata/1` — sets Logger metadata with Orkestra fields + OTel trace_id/span_id
- `inject_context_to_headers/0` — OTel context → AMQP header tuples `{key, :longstr, value}`
- `extract_context_from_headers/1` — AMQP headers → OTel process context

**Span hierarchy:**
```
orkestra.command.dispatch → orkestra.command.handle → orkestra.event.publish → orkestra.event.handle
orkestra.aggregate.execute → orkestra.aggregate.load → orkestra.aggregate.fold → orkestra.aggregate.decide → orkestra.aggregate.append → orkestra.aggregate.publish → orkestra.aggregate.snapshot
orkestra.retry, orkestra.rabbitmq.publish (kind: producer), orkestra.rabbitmq.consume (kind: consumer)
```

---

## Configuration

```elixir
# Message Bus
config :orkestra, Orkestra.MessageBus,
  adapter: Orkestra.MessageBus.PubSub,  # or .RabbitMQ
  app_prefix: MyApp                      # stripped from topic derivation

# PubSub adapter
config :orkestra, Orkestra.MessageBus.PubSub,
  pubsub: MyApp.PubSub

# RabbitMQ adapter
config :orkestra, Orkestra.MessageBus.RabbitMQ,
  channel_provider: fn -> MyApp.RabbitMQ.Connection.channel() end

# Event Store
config :orkestra, Orkestra.EventStore,
  adapter: Orkestra.EventStore.EventStoreDB  # or .InMemory

config :orkestra, Orkestra.EventStore.EventStoreDB,
  connection_string: "esdb://localhost:2113?tls=false"
```

---

## Design Patterns Used

| Pattern | Where | How |
|---------|-------|-----|
| CQRS | Commands vs Events | Separate write intent (Command) from read facts (Event) |
| Event Sourcing | Aggregate + EventStore | State reconstructed by folding events |
| Functional Core / Imperative Shell | Aggregate (pure) + Root (I/O) | Business logic is pure, side effects isolated |
| Envelope | CommandEnvelope, EventEnvelope | Wraps messages with lifecycle and dispatch metadata |
| Competing Consumers | Command dispatch | One handler per command type |
| Fan-Out | Event publish | Multiple handlers per event type |
| Optimistic Concurrency | Aggregate.Root | expected_revision check, auto-retry on conflict |
| Dead Letter | PubSub + RabbitMQ | Failed messages archived after retry exhaustion |
| Pluggable Adapters | MessageBus, EventStore | Swap implementations via config |
| Macro DSL | Command (`param`), Event (`field`) | Declarative message definitions compiled at build time |
| Auto-Subscription | CommandHandler, EventHandler | GenServer self-subscribes on init |
| Correlation Chain | Metadata | correlation_id + causation_id flow through pipeline |

---

## Known Issues / Technical Debt

1. **`:ultimus` config key in EventStore** — `event_store.ex:45` uses `Application.get_env(:ultimus, ...)` instead of `:orkestra`. This is a leftover from a rename. The MessageBus correctly uses `:orkestra`.

2. **`:ultimus` reference in EventStore moduledoc** — `event_store.ex:11` shows `config :ultimus, Orkestra.EventStore` in the docs.

3. **No aggregate tests** — There are no test files for `Aggregate` or `Aggregate.Root`.

4. **No EventStoreDB adapter tests** — `event_store_db.ex` and `snapshot.ex` have no test coverage (requires running EventStoreDB instance).

5. **No InMemory event store tests** — Missing dedicated tests for `EventStore.InMemory`.

6. **No RabbitMQ adapter tests** — `rabbit_mq.ex` has no test coverage (requires running RabbitMQ instance).

7. **No exponential backoff** — PubSub retries are immediate (recursive). RabbitMQ retries rely on broker requeue delay. No configurable backoff strategy.

8. **`hydrate_event` uses `String.to_existing_atom/1`** — Will crash if event module hasn't been loaded yet. Currently rescued, falling back to raw map.

9. **`normalize_params` uses `String.to_existing_atom/1`** — Same atom-existence requirement for string-keyed param maps.

10. **Subscription retry is hardcoded to 5 seconds** — `command_handler.ex` and `event_handler.ex` both use `Process.send_after(self(), :subscribe, 5_000)`.

11. **No middleware pipeline** — `CommandEnvelope` has `middleware_context` field but no middleware chain implementation exists.

---

## Test Strategy

- Tests use `ExUnit.Case`, mostly `async: false` for bus-related tests (shared GenServer state)
- Setup via `start_supervised!/1` for GenServer components
- `assert_receive/2` for async message verification
- Process registration (`Process.register/2`) for inter-process communication in tests
- Dead-letter verification via PubSub subscription to `"orkestra:deadletter"`
- Test helper (`test_helper.exs`) configures PubSub adapter with `Orkestra.PubSub` as the PubSub name

Run tests:
```bash
mix test
```

---

## Typical Command Flow (PubSub)

1. `PlaceOrder.new(%{product_id: "x", quantity: 1}, actor_id: "user_1")` → `{:ok, cmd}`
2. `CommandEnvelope.wrap(cmd, max_retries: 2)` → envelope with `:pending` status
3. `bus.dispatch(envelope)` → PubSub looks up handler by topic, calls `dispatch_with_retry/2`
4. `PlaceOrderHandler.handle(envelope)` → sets OTel span + Logger metadata, calls `execute/2`
5. User's `execute/2` returns `{:ok, %{order_id: "..."}}`
6. Envelope marked `:succeeded`

## Typical Aggregate Flow

1. `Root.execute(BankAccount, open_account_cmd)` → determines `stream_id`
2. Loads snapshot (if any) → loads events from store → folds via `evolve/2`
3. Calls `decide(state, cmd)` → gets `[AccountOpened, ...]`
4. `append_events(stream_id, events, expected_revision)` → optimistic concurrency check
5. If `:wrong_expected_version` → retry from step 2 (up to `max_retries`)
6. Publishes events to MessageBus (if `publish: true`)
7. Checks snapshot interval → saves if needed
8. Returns `{:ok, events, new_state}`
