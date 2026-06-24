# External Integrations

**Analysis Date:** 2026-06-24

## APIs & External Services

**Model Context Protocol (MCP):**
- Hermes.MCP server framework - scaffolding and introspection tools for Orkestra projects
  - SDK/Client: hermes_mcp 0.14.1
  - Registered as: orkestra MCP server in `.mcp.json`
  - Capabilities: tools, resources, prompts
  - Transport: stdio (JSON-RPC over stdin/stdout)

## Data Storage

**Databases:**
- **EventStoreDB** (optional production choice)
  - Connection string via environment or config: `esdb://localhost:2113?tls=false` format
  - Client: Spear 1.4.1 (gRPC via Protocol Buffers)
  - Dependency: event_store_db_gpb_protobufs 2.4.0
  - Pattern: Event sourcing with optimistic concurrency control
  - Adapter: `Orkestra.EventStore.EventStoreDB` at `lib/orkestra/event_store/event_store_db.ex`
  - Alternative: In-memory (testing) via `Orkestra.EventStore.InMemory` at `lib/orkestra/event_store/in_memory.ex`

**File Storage:**
- Not applicable — event data is serialized to JSON via Jason and persisted in EventStoreDB or in-memory

**Caching:**
- Not detected

## Message Brokers

**RabbitMQ** (optional, distributed deployments):
- Adapter: `Orkestra.MessageBus.RabbitMQ` at `lib/orkestra/message_bus/rabbit_mq.ex`
- Connection: Via `channel_provider` callback (returns `{:ok, channel}`)
- SDK/Client: AMQP 4.1.0 + amqp_client 4.2.1
- Configuration:
  ```elixir
  config :orkestra, Orkestra.MessageBus.RabbitMQ,
    channel_provider: fn -> MyApp.RabbitMQ.Connection.channel() end
  ```
- Exchanges:
  - `orkestra.commands` (topic exchange, durable) - point-to-point routing
  - `orkestra.events` (topic exchange, durable) - fan-out routing
  - `orkestra.deadletter` (topic exchange, durable) - failed message destination
- Queues:
  - Commands: `orkestra.cmd.{topic}` per command type (competing consumers, prefetch 10)
  - Events: `orkestra.evt.{topic}.{handler_name}` per handler (fan-out subscribers)
  - Dead letter: `orkestra.deadletter.queue` (failed messages after retry exhaustion)
- Message Format: JSON with metadata for retry count, correlation ID, type
- Retry Strategy:
  - Default max retries: 3
  - Configurable per command via `CommandEnvelope.max_retries`
  - x-death header tracks retry attempts
  - Failed messages automatically routed to DLX after exhausting retries
- Serialization: JSON via Jason 1.4.4

**Phoenix.PubSub** (in-process, default for dev/test):
- Adapter: `Orkestra.MessageBus.PubSub` at `lib/orkestra/message_bus/pub_sub.ex`
- Configuration:
  ```elixir
  config :orkestra, Orkestra.MessageBus,
    adapter: Orkestra.MessageBus.PubSub,
    app_prefix: MyApp

  config :orkestra, Orkestra.MessageBus.PubSub,
    pubsub: MyApp.PubSub  # Points to Phoenix.PubSub process
  ```
- Topics:
  - Commands: `orkestra.commands.{topic}` → single handler dispatch (point-to-point)
  - Events: `orkestra:events:{topic}` → broadcast to all subscribers
  - Dead letter: `orkestra:deadletter` → monitoring/alerting channel
- Retry: Synchronous retry with configurable max per handler
- Serialization: In-memory struct passing (no JSON)

## Authentication & Identity

**Auth Provider:**
- Not applicable — Orkestra is a backend library. Auth is handled by consuming applications.

## Monitoring & Observability

**OpenTelemetry Tracing:**
- API: OpenTelemetry API 1.5.0 (`opentelemetry_api`)
- Process Propagator: OpenTelemetry Process Propagator 0.3.0 (optional, `opentelemetry_process_propagator`)
- Integration points:
  - `Orkestra.Telemetry` module at `lib/orkestra/telemetry.ex` provides span helpers
  - Spans for: command dispatch, event publishing, RabbitMQ publish/consume, retries
  - Attributes extracted from commands/events:
    - `orkestra.command.type`, `orkestra.command.id`
    - `orkestra.event.type`, `orkestra.event.id`
    - `orkestra.correlation_id`, `orkestra.causation_id`, `orkestra.actor_id`, `orkestra.actor_type`, `orkestra.source`
  - Trace context injection to AMQP headers for cross-process correlation
  - AMQP consumer spans automatically created with context propagation via `OpentelemetryProcessPropagator.Task.start`

**Logging:**
- Standard Elixir Logger
- orkestra_mcp routes all logs to stderr (not stdout) for MCP protocol cleanliness
- Structured logging via Logger metadata in handlers (`Orkestra.Telemetry.set_logger_metadata`)
- Log level in orkestra_mcp: `:warning` and above only

**Error Tracking:**
- Not detected as external service — handled locally via dead letter queues (RabbitMQ) or dead letter broadcasts (PubSub)

## CI/CD & Deployment

**Hosting:**
- Not detected — Orkestra is a library, not a deployed service. orkestra_mcp is a binary/server.

**CI Pipeline:**
- Not detected in codebase

**Escript (Command Line):**
- orkestra_mcp builds an escript via Mix
- Main entry: `OrkestraMcp.CLI` at `orkestra_mcp/lib/orkestra_mcp/cli.ex`
- Configuration in `orkestra_mcp/mix.exs`:
  ```elixir
  escript: [main_module: OrkestraMcp.CLI]
  ```

## Environment Configuration

**Required env vars:**
- For RabbitMQ: Typically `AMQP_URL` or connection details passed to `channel_provider`
- For EventStoreDB: `EVENTSTOREDB_CONNECTION` or config entry with `esdb://` URL
- For OpenTelemetry: Exporter config (not in Orkestra core, handled by app)

**Secrets location:**
- Not stored in Orkestra codebase — consuming apps handle secret injection via environment

## Webhooks & Callbacks

**Incoming:**
- Not applicable

**Outgoing:**
- Commands and events published to message bus (RabbitMQ or PubSub)
- Handlers subscribe and process asynchronously
- Manual publication via `bus.dispatch(envelope)` or `bus.publish(envelope)`

## Message Format & Serialization

**JSON Schema (RabbitMQ wire protocol):**

**CommandEnvelope:**
```json
{
  "__type__": "command_envelope",
  "command_type": "string (e.g., 'PlaceOrder')",
  "command_id": "string (UUID)",
  "params": { "key": "value" },
  "metadata": {
    "correlation_id": "string",
    "causation_id": "string or null",
    "actor_id": "string or null",
    "actor_type": "atom as string",
    "source": "string or null",
    "issued_at": "ISO8601 datetime"
  },
  "status": "atom as string ('dispatched', 'processing', etc.)",
  "attempts": "integer",
  "max_retries": "integer"
}
```

**EventEnvelope:**
```json
{
  "__type__": "event_envelope",
  "event_type": "string",
  "event_id": "string (UUID)",
  "data": { "key": "value" },
  "metadata": { "...correlation info..." },
  "occurred_at": "ISO8601 datetime or null"
}
```

**AMQP Message Metadata:**
- `content_type`: "application/json"
- `persistent`: true (durable queues)
- `message_id`: UUID from command/event
- `correlation_id`: correlation_id from metadata
- `type`: "command" or "event"
- Custom headers:
  - `x-max-retries`: integer (max retry attempts)
  - `x-death`: list (RabbitMQ retry metadata)
  - OpenTelemetry context headers (traceparent, tracestate, baggage)

## Topic Naming Convention

Topics are derived from module names and automatically downcased + underscored:

```
MyApp.Orders.Commands.PlaceOrder  →  "orders.commands.place_order"
MyApp.Orders.Events.OrderPlaced   →  "orders.events.order_placed"
MyApp.Tasks.Handlers.HandleTask    →  (derived from command/event, not handler module)
```

App prefix (e.g., `MyApp`) is stripped if configured via:
```elixir
config :orkestra, Orkestra.MessageBus, app_prefix: MyApp
```

## MCP Tools & Resources

**Tools (code generation):**
- GenCommand - scaffold a command struct
- GenEvent - scaffold an event struct
- GenCommandHandler - scaffold a command handler
- GenEventHandler - scaffold an event handler
- GenAggregate - scaffold an aggregate root

**Resources (read-only introspection):**
- ListCommands - discover all defined commands
- ListEvents - discover all defined events
- ListHandlers - discover all registered handlers
- ListAggregates - discover all aggregate roots
- DomainMap - visualize bounded contexts and dependencies

**Prompts (LLM guidance):**
- Conventions - project-specific CQRS patterns
- NewBoundedContext - scaffolding guide for new domain areas

---

*Integration audit: 2026-06-24*
