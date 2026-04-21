# Orkestra

A lightweight CQRS/ES toolkit for Elixir. Pluggable message bus, event store, and OpenTelemetry tracing built in.

Orkestra gives you the building blocks without the framework lock-in. Define commands and events with a declarative DSL, wire up handlers that auto-subscribe, and swap between in-process PubSub and distributed RabbitMQ with a single config change.

## Installation

```elixir
def deps do
  [
    {:orkestra, "~> 0.1.0"}
  ]
end
```

## Quick start

### Define a command

```elixir
defmodule MyApp.Commands.PlaceOrder do
  use Orkestra.Command

  param :product_id, :string, required: true
  param :quantity, :integer, required: true
  param :notes, :string, default: ""
end
```

### Define an event

```elixir
defmodule MyApp.Events.OrderPlaced do
  use Orkestra.Event

  field :order_id, :string, required: true
  field :product_id, :string, required: true
  field :quantity, :integer, required: true
  field :placed_at, :string, required: true
end
```

### Handle the command

```elixir
defmodule MyApp.Handlers.PlaceOrderHandler do
  use Orkestra.CommandHandler,
    command: MyApp.Commands.PlaceOrder

  @impl true
  def execute(command, metadata) do
    order_id = Ecto.UUID.generate()

    # ... your business logic ...

    {:ok, %{order_id: order_id}}
  end
end
```

### React to the event

```elixir
defmodule MyApp.Handlers.SendOrderConfirmation do
  use Orkestra.EventHandler,
    event: MyApp.Events.OrderPlaced

  @impl true
  def handle_event(event, _metadata) do
    MyApp.Mailer.send_confirmation(event.data.order_id)
    :ok
  end
end
```

### Dispatch

```elixir
alias Orkestra.{CommandEnvelope, MessageBus}

{:ok, cmd} = MyApp.Commands.PlaceOrder.new(%{
  product_id: "sku_42",
  quantity: 3
}, actor_id: "user_123", source: "web")

bus = MessageBus.impl()
:ok = bus.dispatch(CommandEnvelope.wrap(cmd, max_retries: 2))
```

### Supervision tree

```elixir
children = [
  {Phoenix.PubSub, name: MyApp.PubSub},
  Orkestra.MessageBus.PubSub,
  MyApp.Handlers.PlaceOrderHandler,
  MyApp.Handlers.SendOrderConfirmation
]
```

## Configuration

### Message bus adapter

```elixir
# In-process (dev, test, single-node)
config :orkestra, Orkestra.MessageBus,
  adapter: Orkestra.MessageBus.PubSub,
  app_prefix: MyApp

config :orkestra, Orkestra.MessageBus.PubSub,
  pubsub: MyApp.PubSub

# Distributed (production, multi-node)
config :orkestra, Orkestra.MessageBus,
  adapter: Orkestra.MessageBus.RabbitMQ,
  app_prefix: MyApp

config :orkestra, Orkestra.MessageBus.RabbitMQ,
  channel_provider: fn -> MyApp.RabbitMQ.Connection.channel() end
```

### Topic derivation

Topics are derived automatically from module names. The `app_prefix` is stripped:

```
MyApp.Orders.Commands.PlaceOrder  ->  "orders.commands.place_order"
MyApp.Orders.Events.OrderPlaced   ->  "orders.events.order_placed"
```

### Event store

```elixir
# EventStoreDB (production)
config :orkestra, Orkestra.EventStore,
  adapter: Orkestra.EventStore.EventStoreDB

config :orkestra, Orkestra.EventStore.EventStoreDB,
  connection_string: "esdb://localhost:2113?tls=false"

# In-memory (test)
config :orkestra, Orkestra.EventStore,
  adapter: Orkestra.EventStore.InMemory
```

## Core concepts

### Commands

Commands represent an intent to change the system. They are validated, dispatched to a single handler, and either succeed or fail.

```elixir
defmodule CreateAccount do
  use Orkestra.Command

  param :email, :string, required: true
  param :name, :string, required: true
  param :plan, :string, default: "free"

  @impl true
  def validate(%{email: email}) do
    if String.contains?(email, "@"), do: :ok, else: {:error, :invalid_email}
  end
end

{:ok, cmd} = CreateAccount.new(%{email: "a@b.com", name: "Alice"})
{:error, {:missing_params, [:email]}} = CreateAccount.new(%{name: "Bob"})
{:error, :invalid_email} = CreateAccount.new(%{email: "nope", name: "Eve"})
```

### Events

Events represent something that happened. They are immutable facts, never rejected. Events can be derived from commands or other events, preserving the correlation chain.

```elixir
defmodule AccountCreated do
  use Orkestra.Event

  field :account_id, :string, required: true
  field :email, :string, required: true
  field :plan, :string, required: true
end

# From a command (preserves correlation, sets causation)
{:ok, event} = AccountCreated.from_command(cmd, %{
  account_id: "acc_123",
  email: "a@b.com",
  plan: "free"
})

event.metadata.correlation_id == cmd.metadata.correlation_id  # true
event.metadata.causation_id == cmd.id                         # true
```

### Metadata

Every command and event carries metadata that flows through the pipeline:

```elixir
%Orkestra.Metadata{
  correlation_id: "abc123",    # links an entire chain of commands/events
  causation_id: "cmd_456",     # what directly caused this
  actor_id: "user_789",        # who initiated it
  actor_type: :user,           # :user | :system | :expert | :scheduler
  source: "web",               # where it originated
  issued_at: ~U[2026-03-27 12:00:00Z]
}

# Derive child metadata (preserves correlation, sets causation)
child = Orkestra.Metadata.derive(parent_metadata, "parent_id")
```

### Envelopes

Envelopes wrap commands and events with dispatch context.

**Command envelopes** track dispatch lifecycle and retries:

```elixir
env = CommandEnvelope.wrap(cmd, max_retries: 3)
env.status    # :pending -> :dispatched -> :succeeded | :failed | :rejected

CommandEnvelope.retryable?(env)  # true if failed and attempts <= max_retries
```

**Event envelopes** track delivery to multiple handlers:

```elixir
env = EventEnvelope.wrap(event) |> EventEnvelope.mark_published()
env = EventEnvelope.register_handler(env, "SendEmail")
env = EventEnvelope.register_handler(env, "UpdateIndex")
env = EventEnvelope.mark_handler_succeeded(env, "SendEmail")
env = EventEnvelope.mark_handler_failed(env, "UpdateIndex")
env.status  # :partially_handled
```

### Event handlers

Subscribe to one event, multiple events, or wildcard patterns:

```elixir
# Single event
use Orkestra.EventHandler,
  event: MyApp.Events.OrderPlaced

# Multiple events
use Orkestra.EventHandler,
  events: [MyApp.Events.OrderPlaced, MyApp.Events.OrderCancelled]

# Wildcard pattern
use Orkestra.EventHandler,
  topic: "orders.events.#"

# With retry config
use Orkestra.EventHandler,
  event: MyApp.Events.OrderPlaced,
  max_retries: 5
```

## Message bus adapters

### PubSub (in-process)

Synchronous dispatch. Commands go to one handler, events broadcast to all subscribers. Retries are immediate (recursive). Dead-lettered messages are broadcast on `"orkestra:deadletter"`.

### RabbitMQ (distributed)

Commands use exchange `orkestra.commands` with one queue per command type (competing consumers). Events use exchange `orkestra.events` with one queue per handler (fan-out).

Features:
- Retry tracking via `x-death` headers (native RabbitMQ)
- Max retries via `x-max-retries` header
- Dead letter exchange `orkestra.deadletter` with catch-all queue
- All queues declared with DLX configuration
- W3C trace context propagation in AMQP headers

## Observability

Orkestra is instrumented with OpenTelemetry out of the box.

### Span hierarchy

```
orkestra.command.dispatch       (message bus)
  orkestra.command.handle       (command handler)
    orkestra.event.publish      (message bus)
      orkestra.event.handle     (event handler)
```

Additional spans: `orkestra.retry`, `orkestra.rabbitmq.publish` (kind: producer), `orkestra.rabbitmq.consume` (kind: consumer).

### Span attributes

All spans include: `orkestra.command.type`, `orkestra.command.id`, `orkestra.correlation_id`, `orkestra.causation_id`, `orkestra.actor_id`, `orkestra.handler`.

### Structured logging

All log messages use Logger metadata instead of string interpolation:

```
[info] Command handler subscribed  handler=MyApp.HandleOrder  topic=orders.commands.place_order  orkestra=command_handler
[warning] Handler nack, requeuing  handler=MyApp.HandleOrder  attempt=2  max_retries=3  orkestra=rabbitmq
[error] Dead letter recorded  handler=MyApp.HandleOrder  reason=:timeout  orkestra=pubsub
```

Logger metadata set during handler execution: `correlation_id`, `causation_id`, `actor_id`, `trace_id`, `span_id`.

### Distributed tracing (RabbitMQ)

Trace context is injected into AMQP message headers on publish and extracted on consume, creating linked spans across nodes. Uses `OpentelemetryProcessPropagator` for context propagation across BEAM processes.


## License

MIT
