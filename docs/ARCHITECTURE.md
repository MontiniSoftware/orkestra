<!-- generated-by: gsd-doc-writer -->
# Architecture

Orkestra is a CQRS/Event Sourcing toolkit for Elixir. It provides the building blocks for implementing
the command-query responsibility segregation pattern with event-sourced aggregates: commands represent
intent, aggregates enforce invariants and produce events, events are stored durably and broadcast to
interested handlers. The library is structured around swappable adapters so the same application code
runs in-process during tests and against distributed infrastructure in production.

A companion project, `orkestra_mcp`, ships as a standalone Model Context Protocol (MCP) server that
introspects a target project's domain model and provides scaffolding tools to AI coding assistants.

---

## Component diagram

```
  Caller
    │
    ▼
CommandEnvelope ──► MessageBus ──────────────────────► CommandHandler (GenServer)
                  (PubSub │                               │  execute/2
                  RabbitMQ)                               │
                      │                                   │
                      │  publish(EventEnvelope)           │ Aggregate.Root.execute/3
                      │◄──────────────────────────────────┘
                      │
                      ▼
                EventEnvelope ──► EventHandler (GenServer, fan-out)
                                    handle_event/2

  Aggregate.Root (imperative shell)
    │
    ├── EventStore.load_events ──► [InMemory | EventStoreDB]
    │        │
    │        ▼ Snapshot.load (snapshot-{stream_id})
    │
    ├── Aggregate.evolve/2 (pure fold, replays history)
    │
    ├── Aggregate.decide/2 (pure decision, returns new events)
    │
    ├── EventStore.append_events (optimistic concurrency)
    │
    ├── Snapshot.save (every N events, if configured)
    │
    └── MessageBus.publish (broadcast new events)
```

---

## System overview

A caller creates a `CommandEnvelope` wrapping a validated `Command` struct and dispatches it through
the `MessageBus`. The `CommandHandler` that subscribed to that command's topic receives the envelope,
executes business logic, and optionally calls `Aggregate.Root.execute/3`. The Root loads the
aggregate's event history from the `EventStore`, left-folds it through `evolve/2` to reconstruct
state, hands the state and command to the pure `decide/2` function, and appends the resulting events
back to the store under optimistic concurrency control. New events are then published as
`EventEnvelope` broadcasts so any number of `EventHandler` subscribers can react.

Every command and event carries `Metadata` (correlation ID, causation ID, actor identity, source)
that threads through the entire causal chain. OpenTelemetry spans wrap every stage of the pipeline so
traces can be correlated with structured log lines.

---

## Key abstractions

| Module | File | Role |
|---|---|---|
| `Orkestra.Aggregate` | `lib/orkestra/aggregate.ex` | Behaviour for pure aggregate logic: `init_state/0`, `stream_id/1`, `decide/2`, `evolve/2`, optional `snapshot_every/0` |
| `Orkestra.Aggregate.Root` | `lib/orkestra/aggregate/root.ex` | Imperative shell — orchestrates load → fold → decide → append → publish, handles optimistic-concurrency retries |
| `Orkestra.Command` | `lib/orkestra/command.ex` | `use`-able macro that generates a struct, `new/2`, `new!/2`, required-param validation, and an ID generator |
| `Orkestra.CommandHandler` | `lib/orkestra/command_handler.ex` | `use`-able macro that wires a GenServer to auto-subscribe to the command's MessageBus topic and delegate to `execute/2` |
| `Orkestra.Event` | `lib/orkestra/event.ex` | `use`-able macro mirroring `Command` for events; adds `from_command/2` and `from_event/2` for metadata chaining |
| `Orkestra.EventHandler` | `lib/orkestra/event_handler.ex` | `use`-able macro; supports single-event, multi-event, and wildcard-topic subscriptions; fan-out delivery |
| `Orkestra.CommandEnvelope` | `lib/orkestra/command_envelope.ex` | Wraps a command with lifecycle state (`:pending` → `:dispatched` → `:succeeded`/`:failed`/`:rejected`), retry tracking, and middleware context |
| `Orkestra.EventEnvelope` | `lib/orkestra/event_envelope.ex` | Wraps an event with per-handler delivery tracking (`:pending` → `:succeeded`/`:failed`/`:skipped`) |
| `Orkestra.Metadata` | `lib/orkestra/metadata.ex` | Immutable struct carrying `correlation_id`, `causation_id`, `actor_id`, `actor_type`, `source`, `issued_at` |
| `Orkestra.MessageBus` | `lib/orkestra/message_bus.ex` | Behaviour + topic-derivation utilities; runtime adapter resolved via `Application.get_env` |
| `Orkestra.EventStore` | `lib/orkestra/event_store.ex` | Behaviour for stream-based event persistence with optimistic concurrency; runtime adapter resolved via `Application.get_env` |
| `Orkestra.EventStore.Snapshot` | `lib/orkestra/event_store/snapshot.ex` | Stores aggregate state in a sibling stream (`snapshot-{stream_id}`) to reduce replay cost |
| `Orkestra.Telemetry` | `lib/orkestra/telemetry.ex` | OpenTelemetry span helpers, structured Logger metadata injection, and AMQP trace-context propagation |

---

## Data flow

### Command dispatch path

1. Caller builds a command with `MyCommand.new/2` (returns `{:ok, cmd}`) and wraps it:
   `CommandEnvelope.wrap(cmd, max_retries: 3)`.
2. Caller calls `MessageBus.impl().dispatch(envelope)`.
3. The MessageBus (PubSub or RabbitMQ) routes the envelope to the registered `CommandHandler` for
   that topic. Topics are derived automatically — e.g. `MyApp.Tasks.Commands.StartAssessment` becomes
   `"tasks.commands.start_assessment"` after stripping the configured `app_prefix`.
4. `CommandHandler.handle/1` (implemented by the macro) unwraps the command and calls your
   `execute(command, metadata)` callback.

### Aggregate execution path

When a `CommandHandler` calls `Aggregate.Root.execute(MyAggregate, command)`:

1. `stream_id/1` is called on the aggregate module to derive the stream identifier.
2. `Snapshot.load(stream_id)` checks for a snapshot in the `snapshot-{stream_id}` stream. If found,
   replay starts from the snapshot's revision; otherwise replay starts from the stream beginning.
3. `EventStore.load_events/1` (or `/2` with `from_revision`) reads stored events.
4. Events are left-folded through `aggregate.evolve(state, event)` to reconstruct current state.
5. `aggregate.decide(state, command)` is called. It returns `{:ok, [events]}` or `{:error, reason}`.
   No I/O is allowed here — it must be a pure function.
6. `EventStore.append_events(stream_id, events, expected_revision)` writes the new events under
   optimistic concurrency. On `:wrong_expected_version`, the entire load → fold → decide → append
   cycle retries (default 3 times).
7. New events are folded into state to produce the updated state.
8. If `snapshot_every/0` is configured and the total event count is a multiple of that interval,
   `Snapshot.save/3` writes a serialised state snapshot.
9. Each new event is wrapped in an `EventEnvelope` and published via the MessageBus.

### Event delivery path

1. `MessageBus.publish(EventEnvelope)` broadcasts to all subscribers for that event's topic.
2. Each `EventHandler` GenServer receives the envelope and calls your `handle_event(event, metadata)`
   callback.
3. On `:ok` the message is acknowledged; on `{:error, reason}` it is nacked and requeued up to the
   configured retry limit, then dead-lettered.

---

## MessageBus adapters

### `Orkestra.MessageBus.PubSub` (`lib/orkestra/message_bus/pub_sub.ex`)

In-process adapter backed by `Phoenix.PubSub`. Commands are dispatched synchronously to a single
registered handler (point-to-point). Events are broadcast via `Phoenix.PubSub.broadcast/3` and also
dispatched synchronously to all registered handlers for ack tracking. Wildcard topic matching (`*`
single-segment, `#` multi-segment) is implemented in process. Failed handlers that exhaust retries
are broadcast to the `orkestra:deadletter` PubSub topic.

**Use this adapter** for tests, single-node deployments, and development.

### `Orkestra.MessageBus.RabbitMQ` (`lib/orkestra/message_bus/rabbit_mq.ex`)

Distributed adapter using AMQP. Two durable topic exchanges are declared on startup:

- `orkestra.commands` — commands route here; one shared queue per topic enables competing consumers.
- `orkestra.events` — events route here; one dedicated queue per handler enables fan-out delivery.

A dead-letter exchange (`orkestra.deadletter`) and queue (`orkestra.deadletter.queue`) capture
messages that exhaust retries. Retry count is tracked via the RabbitMQ `x-death` header and a custom
`x-max-retries` AMQP header. OTel trace context is propagated through AMQP message headers using
`x-b3-*` / W3C traceparent headers.

Serialization uses JSON (`Jason`). Command envelopes are identified by `__type__: "command_envelope"`;
event envelopes by `__type__: "event_envelope"`. Deserialization reconstructs typed structs via
`String.to_existing_atom/1`.

**Use this adapter** for production and multi-node deployments.

**Configuration:**

```elixir
config :orkestra, Orkestra.MessageBus,
  adapter: Orkestra.MessageBus.RabbitMQ,
  app_prefix: MyApp

config :orkestra, Orkestra.MessageBus.RabbitMQ,
  channel_provider: fn -> MyApp.RabbitMQ.get_channel() end
```

---

## EventStore adapters

### `Orkestra.EventStore.InMemory` (`lib/orkestra/event_store/in_memory.ex`)

Agent-backed in-memory store. Streams are plain Elixir lists keyed by stream ID. Optimistic
concurrency is enforced in an `Agent.get_and_update/2` call so the check-and-append is atomic within
a single node. Provides `reset!/1` for clearing state between tests.

**Use this adapter** for tests and local development.

### `Orkestra.EventStore.EventStoreDB` (`lib/orkestra/event_store/event_store_db.ex`)

Adapter for [EventStoreDB](https://www.eventstore.com/) via the `Spear` gRPC client. Streams are
addressed by string ID. Optimistic concurrency maps Orkestra revisions to Spear's `expect:` option:
revision `-1` becomes `:empty`, integers pass through directly. `Spear.ExpectationViolation` is
translated to `:wrong_expected_version`. Events are streamed forwards with `Spear.stream!/3`.

**Use this adapter** for production.

**Configuration:**

```elixir
config :ultimus, Orkestra.EventStore,
  adapter: Orkestra.EventStore.EventStoreDB

config :ultimus, Orkestra.EventStore.EventStoreDB,
  connection_string: "esdb://localhost:2113?tls=false"
```

> Note: the EventStore configuration key is currently `:ultimus` (the host application name) rather
> than `:orkestra`. This is visible in `Orkestra.EventStore.impl/0`.

---

## Snapshots (`Orkestra.EventStore.Snapshot`)

Snapshots reduce aggregate replay cost when event streams grow long. An aggregate module opts in by
implementing the optional `snapshot_every/0` callback:

```elixir
@impl true
def snapshot_every, do: 50  # snapshot after every 50 events
```

When `total_event_count` is a positive multiple of the configured interval, `Snapshot.save/3`
appends a single event of type `"Orkestra.Snapshot"` to a sibling stream named
`snapshot-{stream_id}`. The payload is the Erlang term serialised with `:erlang.term_to_binary/1`
and base64-encoded. On load, `Snapshot.load/1` reads the latest event from that snapshot stream and
deserialises it, then the Root loads only events after the snapshot's revision.

---

## Metadata and causation chaining

`Orkestra.Metadata` carries the following fields through every command and event:

| Field | Description |
|---|---|
| `correlation_id` | Unique ID for the entire causal chain; generated once per user action |
| `causation_id` | ID of the command or event that directly caused this message |
| `actor_id` | Identity of the actor (user ID, system name, etc.) |
| `actor_type` | `:user`, `:system`, `:expert`, or `:scheduler` |
| `source` | Origin of the message (`"web"`, `"api"`, `"rabbitmq"`, etc.) |
| `issued_at` | `DateTime.utc_now()` at creation time |

Derived metadata is created with `Metadata.derive(parent_metadata, causation_id)`, which preserves
`correlation_id` and `actor_*` fields while setting a new `causation_id`. Helpers
`Event.from_command/2` and `Event.from_event/2` call this automatically.

At execution time, `Orkestra.Telemetry.set_logger_metadata/1` injects correlation and causation IDs
into the Logger process dictionary alongside the current OTel `trace_id` and `span_id`, enabling
log-to-trace correlation in tools like SigNoz.

---

## Telemetry and tracing (`Orkestra.Telemetry`)

Orkestra wraps every pipeline stage in a named OpenTelemetry span:

| Span name | Stage |
|---|---|
| `orkestra.aggregate.execute` | Top-level aggregate command execution |
| `orkestra.aggregate.load` | Event loading and snapshot resolution |
| `orkestra.aggregate.fold` | State reconstruction from events |
| `orkestra.aggregate.decide` | Pure decision function call |
| `orkestra.aggregate.append` | Event store write |
| `orkestra.aggregate.publish` | MessageBus broadcast |
| `orkestra.aggregate.snapshot` | Snapshot save |
| `orkestra.command.dispatch` | Command dispatch via MessageBus |
| `orkestra.command.handle` | CommandHandler callback |
| `orkestra.event.publish` | Event publish via MessageBus |
| `orkestra.event.handle` | EventHandler callback |
| `orkestra.rabbitmq.publish` | AMQP message publish |
| `orkestra.rabbitmq.consume` | AMQP message consume |
| `orkestra.retry` | Retry attempt (PubSub adapter) |

Span attributes use the `orkestra.*` namespace (e.g. `orkestra.command.type`,
`orkestra.correlation_id`). Errors set the span status to `:error` and record the reason.

---

## Directory structure

```
orkestra/
  lib/
    orkestra/
      aggregate.ex              # Behaviour: pure aggregate contract
      aggregate/
        root.ex                 # Imperative shell: load→fold→decide→append→publish
      command.ex                # use-able macro for commands
      command_envelope.ex       # Envelope with lifecycle and retry tracking
      command_handler.ex        # use-able macro for command handler GenServers
      event.ex                  # use-able macro for events
      event_envelope.ex         # Envelope with per-handler delivery tracking
      event_handler.ex          # use-able macro for event handler GenServers
      event_store.ex            # Behaviour for event persistence
      event_store/
        in_memory.ex            # Agent-backed store for tests
        event_store_db.ex       # Spear gRPC adapter for EventStoreDB
        snapshot.ex             # Snapshot load/save on snapshot-{stream_id} streams
      message_bus.ex            # Behaviour + topic derivation
      message_bus/
        handler.ex              # Handler behaviour (handle/1)
        pub_sub.ex              # Phoenix.PubSub in-process adapter
        rabbit_mq.ex            # AMQP distributed adapter
      metadata.ex               # Correlation/causation struct
      telemetry.ex              # OTel spans, Logger metadata, AMQP propagation
  test/
    ...

orkestra_mcp/                   # Standalone MCP server (separate Mix project)
  lib/
    orkestra_mcp/
      server.ex                 # Hermes.Server registering all tools, resources, prompts
      application.ex            # OTP application; starts server on stdio transport
      cli.ex                    # Escript entry point
      introspection.ex          # Static source analysis: discovers commands, events, handlers, aggregates
      generator.ex              # Code generation: produces module source and resolves file paths
      naming.ex                 # Module-name to file-path conversion helpers
      tools/
        gen_aggregate.ex        # MCP tool: generate aggregate with decide/evolve clauses
        gen_command.ex          # MCP tool: generate command module
        gen_event.ex            # MCP tool: generate event module
        gen_command_handler.ex  # MCP tool: generate command handler module
        gen_event_handler.ex    # MCP tool: generate event handler module
      resources/
        domain_map.ex           # MCP resource: cross-reference map of commands → handlers → events
        list_aggregates.ex      # MCP resource: list discovered aggregates
        list_commands.ex        # MCP resource: list discovered commands with params
        list_events.ex          # MCP resource: list discovered events with fields
        list_handlers.ex        # MCP resource: list discovered handlers with subscriptions
      prompts/
        conventions.ex          # MCP prompt: Orkestra conventions and best practices
        new_bounded_context.ex  # MCP prompt: guided workflow for adding a bounded context
```

---

## `orkestra_mcp` — MCP server for AI-assisted development

`orkestra_mcp` is a companion Mix project (in the `orkestra_mcp/` directory) that ships as an
escript (`OrkestraMcp.CLI`) and OTP application. It exposes a Model Context Protocol server over
stdio transport using the `hermes_mcp` library.

The MCP server has three capability types:

**Tools** (write operations — generate source files in the target project):

| Tool | Purpose |
|---|---|
| `orkestra.gen.command` | Scaffold a `use Orkestra.Command` module |
| `orkestra.gen.event` | Scaffold a `use Orkestra.Event` module |
| `orkestra.gen.command_handler` | Scaffold a `use Orkestra.CommandHandler` module |
| `orkestra.gen.event_handler` | Scaffold a `use Orkestra.EventHandler` module |
| `orkestra.gen.aggregate` | Scaffold an `@behaviour Orkestra.Aggregate` module with stubbed `decide` and `evolve` clauses |

**Resources** (read operations — introspect the target project):

| Resource URI | Purpose |
|---|---|
| `orkestra://domain-map` | Cross-reference map linking commands → handlers and events → handlers |
| `orkestra://commands` | All commands discovered in `lib/` with their `param` definitions |
| `orkestra://events` | All events discovered in `lib/` with their `field` definitions |
| `orkestra://handlers` | All command and event handlers with their subscriptions |
| `orkestra://aggregates` | All aggregate modules |

**Prompts** (context for the AI assistant):

| Prompt | Purpose |
|---|---|
| `conventions` | Full Orkestra conventions reference (file layout, naming, metadata chain, supervision tree) |
| `new_bounded_context` | Step-by-step workflow for adding a new bounded context to an existing project |

### How introspection works

`OrkestraMcp.Introspection.discover/1` accepts a project directory path. It walks `lib/**/*.ex`
files with `Path.wildcard/1`, reads each file's source, and applies regex patterns to detect:

- `use Orkestra.Command` — command modules, extracting `param` declarations
- `use Orkestra.Event` — event modules, extracting `field` declarations
- `use Orkestra.CommandHandler, command: ...` — command handlers and their command binding
- `use Orkestra.EventHandler, event: ...` / `events: [...]` / `topic: "..."` — event handlers and
  their subscriptions
- `@behaviour Orkestra.Aggregate` — aggregate modules

This is static source analysis (no compilation required). The `build_domain_map/1` function
cross-references the discovered components to produce a human-readable text map.

The `project_dir` for introspection and generation is configured via:

```elixir
config :orkestra_mcp, :project_dir, "/path/to/your/project"
```

or passed at runtime when starting the escript.
