<!-- refreshed: 2026-06-24 -->
# Architecture

**Analysis Date:** 2026-06-24

## System Overview

```text
┌──────────────────────────────────────────────────────────────────┐
│                    Command/Event DSL Layer                        │
│  Command, Event macros generate validation & builders             │
│  `lib/orkestra/command.ex`, `lib/orkestra/event.ex`              │
└────────────────┬─────────────────────────────────────────────────┘
                 │
┌─────────────────┴──────────────────────────────────────────────────┐
│               Request Handlers & Aggregates                         │
│  ┌────────────────────┐      ┌──────────────────────────────────┐  │
│  │ CommandHandler     │      │   Aggregate.Root (Imperative)    │  │
│  │ EventHandler       │      │   Executes: load → fold →        │  │
│  │ `*_handler.ex`     │      │   decide → append → publish       │  │
│  │ auto-subscribe     │      │   `lib/orkestra/aggregate/`      │  │
│  └────────────────────┘      └──────────────────────────────────┘  │
│                                                                      │
│  ┌────────────────────────────────────────────────────────────────┐ │
│  │ Aggregate (Behaviour) — Pure Functions                         │ │
│  │ - init_state/0 — initial state                                 │ │
│  │ - stream_id/1 — derive event stream identifier                 │ │
│  │ - evolve/2 — fold function for replay (state, event → state)  │ │
│  │ - decide/2 — decision function (state, command → {:ok, events})│ │
│  │ - snapshot_every/0 — optional snapshotting interval            │ │
│  │ `lib/orkestra/aggregate.ex`                                    │ │
│  └────────────────────────────────────────────────────────────────┘ │
└────────────────┬───────────────────────────────────────────────────┘
                 │
┌─────────────────┴───────────────────────────────────────────────────┐
│                  Envelope & Metadata Layer                           │
│  CommandEnvelope — wraps command with dispatch state/retries        │
│  EventEnvelope — wraps event with handler tracking                  │
│  Metadata — correlation_id, causation_id, actor_id, source          │
│  Telemetry — OpenTelemetry spans + structured logging               │
│  `lib/orkestra/*_envelope.ex`, `lib/orkestra/metadata.ex`           │
└────────────────┬───────────────────────────────────────────────────┘
                 │
┌─────────────────┴────────────────────────────────────────────────────┐
│           Message Bus (Abstraction + Adapters)                       │
│  ┌──────────────────────┐    ┌──────────────────────────────────┐   │
│  │  MessageBus.PubSub   │    │  MessageBus.RabbitMQ             │   │
│  │  (Phoenix.PubSub)    │    │  (AMQP via amqp_client)          │   │
│  │  point-to-point      │    │  distributed, durable queues     │   │
│  │  commands            │    │  Topic: "module.path.underscore" │   │
│  │  broadcast events    │    └──────────────────────────────────┘   │
│  └──────────────────────┘                                            │
│  `lib/orkestra/message_bus/` + adapters                             │
└────────────────┬─────────────────────────────────────────────────────┘
                 │
┌─────────────────┴──────────────────────────────────────────────────────┐
│           Event Store (Abstraction + Adapters)                          │
│  ┌──────────────────────────┐  ┌─────────────────────────────────┐    │
│  │ EventStore.InMemory      │  │ EventStore.EventStoreDB         │    │
│  │ (Agent-based, test mode) │  │ (Spear gRPC client)             │    │
│  │ simple concurrency check │  │ optimistic concurrency control  │    │
│  └──────────────────────────┘  └─────────────────────────────────┘    │
│                                                                         │
│  Snapshot — separate stream `snapshot-{stream_id}` with state capture  │
│  `lib/orkestra/event_store/` + adapters                               │
└──────────────────────────────────────────────────────────────────────┘
```

## Component Responsibilities

| Component | Responsibility | File |
|-----------|----------------|------|
| Command | Struct + builder with validation for intents | `lib/orkestra/command.ex` |
| Event | Struct + builder with correlation tracking | `lib/orkestra/event.ex` |
| CommandEnvelope | Wraps command with dispatch state, retries | `lib/orkestra/command_envelope.ex` |
| EventEnvelope | Wraps event with per-handler tracking | `lib/orkestra/event_envelope.ex` |
| Metadata | Correlation, causation, actor, source | `lib/orkestra/metadata.ex` |
| Aggregate (behaviour) | Pure fold + decision functions | `lib/orkestra/aggregate.ex` |
| Aggregate.Root | Imperative shell: load → fold → decide → append → publish | `lib/orkestra/aggregate/root.ex` |
| CommandHandler (macro) | Auto-subscribes, unwraps, calls execute callback | `lib/orkestra/command_handler.ex` |
| EventHandler (macro) | Auto-subscribes (single, multi, or topic), calls handle_event | `lib/orkestra/event_handler.ex` |
| MessageBus | Command dispatch + event publish (behaviour) | `lib/orkestra/message_bus.ex` |
| MessageBus.PubSub | In-process via Phoenix.PubSub | `lib/orkestra/message_bus/pub_sub.ex` |
| MessageBus.RabbitMQ | Distributed via RabbitMQ/AMQP | `lib/orkestra/message_bus/rabbit_mq.ex` |
| EventStore | Event persistence with concurrency control (behaviour) | `lib/orkestra/event_store.ex` |
| EventStore.InMemory | Agent-backed storage for tests | `lib/orkestra/event_store/in_memory.ex` |
| EventStore.EventStoreDB | gRPC adapter for EventStoreDB | `lib/orkestra/event_store/event_store_db.ex` |
| Snapshot | State capture at configurable intervals | `lib/orkestra/event_store/snapshot.ex` |
| Telemetry | OpenTelemetry + structured logging | `lib/orkestra/telemetry.ex` |

## Pattern Overview

**Overall:** Command Query Responsibility Segregation (CQRS) with Event Sourcing (ES)

**Key Characteristics:**
- **Pure aggregates** — domain logic is pure functions (`evolve`, `decide`) with no I/O
- **Imperative shell** — Aggregate.Root handles all side effects (event store, message bus)
- **Optimistic concurrency** — expected_version check on append, automatic retry on conflict
- **Metadata threading** — correlation_id and causation_id flow through command → event → handler chain
- **Pluggable adapters** — MessageBus (PubSub or RabbitMQ), EventStore (InMemory or EventStoreDB)
- **OpenTelemetry integration** — all critical paths emit spans and structured logs

## Layers

**Command/Event DSL:**
- Purpose: Provide ergonomic struct builders with validation
- Location: `lib/orkestra/command.ex`, `lib/orkestra/event.ex`
- Contains: Macros (`param`, `field`) that emit struct definitions, builders, validators
- Depends on: Metadata for context
- Used by: Applications defining domain commands and events

**Handler Layer:**
- Purpose: Auto-subscribe and dispatch messages to application code
- Location: `lib/orkestra/command_handler.ex`, `lib/orkestra/event_handler.ex`
- Contains: GenServer-based handlers with envelope unwrapping and ack/nack logic
- Depends on: MessageBus for subscriptions, Telemetry for tracing
- Used by: Applications implementing event-driven reactions

**Aggregate Execution:**
- Purpose: Orchestrate the command processing pipeline
- Location: `lib/orkestra/aggregate/root.ex`, `lib/orkestra/aggregate.ex`
- Contains: Load-fold-decide-append-publish with retry logic and snapshots
- Depends on: EventStore, MessageBus, Snapshot
- Used by: CommandHandlers or direct calls to Aggregate.Root.execute/3

**Envelope & Metadata:**
- Purpose: Track dispatch state, retries, correlation, and causation
- Location: `lib/orkestra/*_envelope.ex`, `lib/orkestra/metadata.ex`
- Contains: Immutable envelope structures with status transitions
- Depends on: Command, Event
- Used by: All layers for request/response context

**Message Bus:**
- Purpose: Decouple command/event producers from handlers
- Location: `lib/orkestra/message_bus.ex` (behaviour), `lib/orkestra/message_bus/*.ex` (adapters)
- Contains: Point-to-point command dispatch, broadcast event publishing
- Depends on: None
- Used by: Aggregate.Root (publish), CommandHandler/EventHandler (subscribe)

**Event Store:**
- Purpose: Persist events with optimistic concurrency and snapshotting
- Location: `lib/orkestra/event_store.ex` (behaviour), `lib/orkestra/event_store/*.ex` (adapters)
- Contains: Stream-based append, load with revision, snapshots
- Depends on: None
- Used by: Aggregate.Root for load_events, append_events; Snapshot for state capture

## Data Flow

### Primary Command Execution Path

1. **Command Created** (`lib/orkestra/command.ex:new/2`)
   - Build params, validate, generate id, attach metadata
   - Return `{:ok, command}` or `{:error, reason}`

2. **Command Dispatched to Handler** (e.g. via `Aggregate.Root.execute/3`)
   - Derive stream_id from command using `Aggregate.stream_id/1`
   - Wrap command in CommandEnvelope (optional: set max_retries)

3. **Load & Fold State** (`lib/orkestra/aggregate/root.ex:load_and_fold/2`)
   - Try to load snapshot from `snapshot-{stream_id}` stream
   - If snapshot exists, load events from after snapshot revision
   - If no snapshot, load all events from stream (revision = -1)
   - Fold events using `Aggregate.evolve/2` to reconstruct state

4. **Decide** (`lib/orkestra/aggregate/root.ex:decide/3`)
   - Call `Aggregate.decide(state, command)` — pure, no I/O
   - Return `{:ok, [events]}` or `{:error, reason}`
   - If error, fail immediately

5. **Append Events** (`lib/orkestra/aggregate/root.ex:append/3`)
   - Serialize new events with metadata
   - Call `EventStore.append_events(stream_id, events, expected_revision)`
   - Optimistic concurrency: append only if revision matches
   - On `:wrong_expected_version`, retry entire pipeline (bounded by max_retries)

6. **Publish Events** (`lib/orkestra/aggregate/root.ex:publish_events/2`)
   - If `:publish => true` in options, broadcast to MessageBus
   - For each event, create EventEnvelope and call `bus.publish(envelope)`
   - MessageBus delivers to all subscribed EventHandlers

7. **Event Handlers React** (`lib/orkestra/event_handler.ex:handle/1`)
   - Subscribed handlers auto-receive EventEnvelope
   - Unwrap envelope, extract event + metadata
   - Call application's `handle_event(event, metadata)` callback
   - If `:ok`, mark handler as succeeded; if `{:error, reason}`, retry or nack

### Snapshot Lifecycle

- **Trigger:** After append, if `total_event_count % snapshot_every() == 0`
- **Action:** Save state to `snapshot-{stream_id}` stream
- **Next Load:** Skip all events before snapshot revision, replay only newer events

**State Management:**
- Aggregate state is reconstructed on every command execution (stateless)
- No shared mutable state across executions
- Concurrency handled by optimistic versioning, not locks

## Key Abstractions

**Aggregate (Behaviour):**
- Purpose: Encapsulate domain logic as pure state machines
- Examples: `MyApp.Orders.OrderAggregate`, `MyApp.Accounts.AccountAggregate`
- Pattern: Implements `init_state`, `stream_id`, `evolve`, `decide` (and optional `snapshot_every`)

**Command (Macro + Struct):**
- Purpose: Represent user intent with validated parameters
- Examples: `StartAssessment.new(%{...})`, `PlaceOrder.new!(%{...})`
- Pattern: `use Orkestra.Command`, declare `param :name, :type, ...`, auto-generated `new/2`, `new!/2`

**Event (Macro + Struct):**
- Purpose: Record immutable facts with correlated metadata
- Examples: `AssessmentCompleted.from_command(cmd, %{...})`, `Event.new!(%{...})`
- Pattern: `use Orkestra.Event`, declare `field :name, :type, ...`, auto-generated `new/2`, `from_command/2`

**Handler Macros (CommandHandler, EventHandler):**
- Purpose: Auto-subscribe to topics and provide ergonomic callback interface
- Pattern: `use Orkestra.CommandHandler, command: MyCommand` or `use Orkestra.EventHandler, event: MyEvent`
- Generates GenServer with `handle/1` that unwraps envelope and calls user's `execute/2` or `handle_event/2`

**MessageBus (Behaviour + Adapters):**
- Purpose: Decouple producers from consumers, support both in-process and distributed
- Adapters: PubSub (in-process), RabbitMQ (distributed)
- Pattern: Topics derived from module names, e.g., `MyApp.Orders.Commands.PlaceOrder` → `orders.commands.place_order`

**EventStore (Behaviour + Adapters):**
- Purpose: Persist events with transactional guarantees and snapshot optimization
- Adapters: InMemory (test), EventStoreDB (production)
- Pattern: Streams identified by string id, events have revision for concurrency control

## Entry Points

**Aggregate.Root.execute/3:**
- Location: `lib/orkestra/aggregate/root.ex:execute/3`
- Triggers: Called directly by command handlers or external commands
- Responsibilities: Load state, decide, append, publish; retry on concurrency conflict

**CommandHandler Macros:**
- Location: `lib/orkestra/command_handler.ex`
- Triggers: GenServer started in supervision tree, auto-subscribes to command topic
- Responsibilities: Deserialize envelope, call user's execute callback, ack/nack

**EventHandler Macros:**
- Location: `lib/orkestra/event_handler.ex`
- Triggers: GenServer started in supervision tree, auto-subscribes to event topic(s)
- Responsibilities: Deserialize envelope, call user's handle_event callback, ack/nack

**Application.start/2:**
- Where handlers are registered in supervision tree
- Example: `[MyApp.HandleStartAssessment, MyApp.OnAssessmentCompleted]`

## Architectural Constraints

- **Threading:** Single-threaded event loop per OTP process; concurrency via multiple Aggregate.Root executions, optimistic versioning prevents conflicts
- **Global state:** EventStore (InMemory or connection pool for EventStoreDB), MessageBus (PubSub registry or RabbitMQ channel)
- **Circular imports:** Handlers must not directly call Aggregate.Root.execute on commands in their own handler — would cause deadlock; use event-driven reactions instead
- **Snapshots:** Must maintain compatibility with past snapshot formats; Snapshot module uses Erlang binary format (version-safe with :safe atom deserialization)
- **Metadata threading:** Metadata flows automatically through `Event.from_command/2` and `Event.from_event/2`; causation_id is set to parent id, correlation_id is preserved
- **Handler idempotency:** Event handlers should be idempotent since retries may occur on transient failures

## Anti-Patterns

### Handler Directly Modifying Aggregate State

**What happens:** Event handler tries to call `Aggregate.Root.execute` to modify state instead of letting aggregate's decide function handle it

**Why it's wrong:** Violates event-driven architecture; creates tight coupling between handlers and aggregates; side effects become implicit

**Do this instead:** Commands should be dispatched by handlers, not directly modifying state. Keep handlers purely reactive (`handle_event/2` returns `:ok` or `{:error, reason}`). If new commands are needed, publish them to MessageBus or have a saga coordinator handle the flow.

### Mixing Pure and Impure Code in Aggregates

**What happens:** Aggregate functions call I/O (HTTP, database queries, side effects) inside `evolve/2` or `decide/2`

**Why it's wrong:** Breaks state replay; snapshot deserialization might fail; concurrency retries cause I/O duplication

**Do this instead:** Aggregate logic is pure. I/O happens in Aggregate.Root layer or in handlers. If decide needs external data, pass it as command params (validated before calling Root.execute).

### Ignoring Concurrency Conflicts

**What happens:** After `:wrong_expected_version` error, handler crashes instead of retrying through Root.execute

**Why it's wrong:** Events are lost; aggregate state becomes inconsistent

**Do this instead:** Aggregate.Root.execute automatically retries (bounded by max_retries). If you catch the error externally, re-call Root.execute or let the framework retry.

### Using Metadata.correlation_id as Business Logic

**What happens:** Aggregate decide functions check correlation_id to branch logic

**Why it's wrong:** Correlation is for tracing/debugging, not business rules; breaks observability

**Do this instead:** Derive business state from aggregate state (evolve result). Use metadata only for logging, tracing, and audit trails.

## Error Handling

**Strategy:** Explicit `{:ok, ...} | {:error, reason}` tuples throughout. Exceptions only for fatal failures (panic/crash).

**Patterns:**
- **Command validation fails:** Return `{:error, {:missing_params, keys}}` immediately in `new/2`
- **Aggregate decide fails:** Return `{:error, reason}` from decide, don't emit events, Aggregate.Root propagates error
- **Event append fails (concurrency):** Aggregate.Root catches `:wrong_expected_version` and retries
- **EventStore I/O fails:** Logged and returned as `{:error, reason}`, Root.execute fails
- **MessageBus publish fails:** Logged but doesn't block append (events are already persisted)
- **Handler execution fails:** Returns `{:error, reason}`, nacks envelope, triggers retry/dead-letter per adapter

## Cross-Cutting Concerns

**Logging:** Structured logs via Logger with `orkestra` tag, metadata injected by Telemetry.set_logger_metadata/1. Key fields: event_type, command_type, correlation_id, actor_id.

**Validation:** Commands validated in `Command.new/2` (required params, custom validate/1 callback). Events validated similarly. Aggregates enforce business rules in `decide/2`.

**Authentication:** Metadata.actor_id and actor_type capture identity. Handlers check these before processing. Authorization logic in aggregate decide or handler execute callbacks.

---

*Architecture analysis: 2026-06-24*
