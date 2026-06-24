# Codebase Structure

**Analysis Date:** 2026-06-24

## Directory Layout

```
orkestra/                          # Root: CQRS/ES library
├── lib/orkestra/
│   ├── orkestra.ex               # Module documentation, quick-start guide
│   ├── command.ex                # Command DSL — use Orkestra.Command macro
│   ├── event.ex                  # Event DSL — use Orkestra.Event macro
│   ├── command_envelope.ex       # Envelope wrapping commands with dispatch context
│   ├── event_envelope.ex         # Envelope wrapping events with handler tracking
│   ├── command_handler.ex        # Macro for auto-subscribing command handlers
│   ├── event_handler.ex          # Macro for auto-subscribing event handlers
│   ├── metadata.ex               # Correlation, causation, actor, source
│   ├── telemetry.ex              # OpenTelemetry spans + structured logging
│   ├── message_bus.ex            # Behaviour for command dispatch & event publish
│   ├── message_bus/
│   │   ├── handler.ex            # Behaviour for message handlers
│   │   ├── pub_sub.ex            # Adapter: Phoenix.PubSub (in-process)
│   │   └── rabbit_mq.ex          # Adapter: RabbitMQ/AMQP (distributed)
│   ├── event_store.ex            # Behaviour for event persistence
│   ├── event_store/
│   │   ├── in_memory.ex          # Adapter: Agent-backed (test/dev)
│   │   ├── event_store_db.ex     # Adapter: EventStoreDB via Spear
│   │   └── snapshot.ex           # State capture at configurable intervals
│   └── aggregate/
│       └── root.ex               # Imperative shell: load → fold → decide → append → publish
│
├── test/
│   ├── test_helper.exs
│   └── orkestra/
│       ├── command_test.exs      # Command builder, validation
│       ├── event_test.exs        # Event builder, correlation
│       ├── command_envelope_test.exs
│       ├── event_envelope_test.exs
│       ├── metadata_test.exs
│       ├── command_handler_test.exs
│       ├── event_handler_test.exs
│       ├── message_bus_test.exs
│       └── message_bus/
│           └── pub_sub_test.exs
│
├── mix.exs                        # Orkestra library definition, deps
├── README.md
└── .planning/
    └── codebase/                  # This analysis

orkestra_mcp/                      # Sub-project: MCP server for introspection + code generation
├── lib/orkestra_mcp/
│   ├── orkestra_mcp.ex           # Module documentation
│   ├── server.ex                 # MCP server entrypoint
│   ├── cli.ex                    # CLI interface for local usage
│   ├── introspection.ex          # Discover commands, events, handlers, aggregates in a project
│   ├── generator.ex              # Generate Command, Event, Handler, Aggregate modules
│   ├── naming.ex                 # Module name ↔ file path conversions
│   ├── application.ex            # OTP application
│   ├── tools/                    # MCP tools for code generation
│   │   ├── gen_command.ex
│   │   ├── gen_event.ex
│   │   ├── gen_command_handler.ex
│   │   ├── gen_event_handler.ex
│   │   └── gen_aggregate.ex
│   ├── resources/                # MCP resources for introspection
│   │   ├── domain_map.ex         # Overview of all components
│   │   ├── list_commands.ex      # Available commands
│   │   ├── list_events.ex        # Available events
│   │   ├── list_aggregates.ex    # Available aggregates
│   │   └── list_handlers.ex      # Available handlers
│   └── prompts/                  # MCP prompts with guided workflows
│       ├── conventions.ex        # Orkestra best practices
│       └── new_bounded_context.ex
│
├── test/
│   ├── test_helper.exs
│   ├── orkestra_mcp_test.exs
│   ├── fixtures/
│   │   └── sample_project/       # Example project for testing introspection
│   │       ├── lib/my_app/
│   │       │   ├── orders/
│   │       │   │   ├── commands/
│   │       │   │   │   └── place_order.ex
│   │       │   │   ├── events/
│   │       │   │   │   └── order_placed.ex
│   │       │   │   ├── handlers/
│   │       │   │   │   ├── place_order_handler.ex
│   │       │   │   │   ├── audit_logger.ex
│   │       │   │   │   ├── send_confirmation.ex
│   │       │   │   │   └── update_index.ex
│   │       │   │   └── order_aggregate.ex
│   │       │   └── inventory/
│   │       │       └── track_stock.ex
│   │       └── mix.exs
│   └── orkestra_mcp/
│       └── tools/
│           └── *_test.exs
│
├── mix.exs                        # OrkestraMcp app definition, depends on :orkestra
├── config/
│   └── config.exs
└── README.md
```

## Directory Purposes

**lib/orkestra/:**
Core CQRS/ES framework.
- Behaviours: Aggregate, EventStore, MessageBus, MessageBus.Handler, Command, Event
- Macros: CommandHandler, EventHandler (auto-subscribe + dispatch)
- Concrete structs: CommandEnvelope, EventEnvelope, Metadata
- Adapters: PubSub, RabbitMQ (message bus), InMemory, EventStoreDB (event store)
- Orchestration: Aggregate.Root (load-fold-decide-append-publish pipeline)

**lib/orkestra/message_bus/:**
Message transport abstraction and implementations.
- `handler.ex` — callback behaviour for handlers
- `pub_sub.ex` — in-process broadcasting via Phoenix.PubSub (dev, test, single-node)
- `rabbit_mq.ex` — distributed messaging via RabbitMQ (production, multi-node)

**lib/orkestra/event_store/:**
Event persistence abstraction and implementations.
- `in_memory.ex` — Agent-backed ephemeral storage (tests)
- `event_store_db.ex` — gRPC to EventStoreDB (production event sourcing DB)
- `snapshot.ex` — Optional state snapshots for faster replay

**lib/orkestra/aggregate/:**
Aggregate execution and pure domain logic separation.
- `root.ex` — Imperative shell orchestrating the full pipeline

**orkestra_mcp/lib/orkestra_mcp/:**
Code generation and introspection helpers for Orkestra projects.
- **tools/** — MCP tools: gen_command, gen_event, gen_command_handler, gen_event_handler, gen_aggregate
- **resources/** — MCP resources: domain_map, list_commands, list_events, list_aggregates, list_handlers
- **prompts/** — MCP prompts: conventions, new_bounded_context
- `introspection.ex` — Parse a project's lib/ to discover existing Orkestra components
- `generator.ex` — Code generation for new components
- `naming.ex` — Module name to file path mappings

**orkestra_mcp/test/fixtures/sample_project/:**
Reference project for testing introspection and generation.
- Structure: `lib/my_app/{bounded_context}/{commands,events,handlers}/`
- Demonstrates: Command, Event, CommandHandler, EventHandler, Aggregate definitions

## Key File Locations

**Entry Points:**
- `lib/orkestra.ex` — Module docs, quick-start examples
- `orkestra_mcp/lib/orkestra_mcp.ex` — OrkestraMcp module docs
- `orkestra_mcp/lib/orkestra_mcp/server.ex` — MCP server startup

**Configuration:**
- `mix.exs` (main) — Orkestra library definition
- `orkestra_mcp/mix.exs` — OrkestraMcp app definition
- `orkestra_mcp/config/config.exs` — OrkestraMcp app config

**Core Logic:**
- `lib/orkestra/aggregate.ex` — Aggregate behaviour (init_state, stream_id, evolve, decide)
- `lib/orkestra/aggregate/root.ex` — Pipeline orchestration (load-fold-decide-append-publish)
- `lib/orkestra/command_handler.ex` — Auto-subscribing handler macro
- `lib/orkestra/event_handler.ex` — Auto-subscribing handler macro

**Testing:**
- `test/orkestra/command_test.exs` — Command creation and validation
- `test/orkestra/event_test.exs` — Event creation and correlation
- `test/orkestra/command_handler_test.exs` — Handler behavior
- `test/orkestra/message_bus/pub_sub_test.exs` — MessageBus dispatch and publish
- `orkestra_mcp/test/fixtures/sample_project/` — Reference project

## Naming Conventions

**Files:**
- Core modules: `lib/orkestra/{abstraction}.ex` (e.g., `command.ex`, `event.ex`, `metadata.ex`)
- Adapters: `lib/orkestra/{subsystem}/{implementation}.ex` (e.g., `message_bus/pub_sub.ex`, `event_store/in_memory.ex`)
- Tests: `test/orkestra/{module}_test.exs` (parallel to source structure)
- MCP tools: `orkestra_mcp/lib/orkestra_mcp/tools/gen_{component}.ex`
- MCP resources: `orkestra_mcp/lib/orkestra_mcp/resources/list_{components}.ex`

**Modules:**
- Library root: `Orkestra`
- Behaviours: `Orkestra.Aggregate`, `Orkestra.Command`, `Orkestra.Event`, `Orkestra.MessageBus`, `Orkestra.EventStore`
- Macros: `Orkestra.CommandHandler`, `Orkestra.EventHandler`
- Adapters: `Orkestra.MessageBus.PubSub`, `Orkestra.MessageBus.RabbitMQ`, `Orkestra.EventStore.InMemory`, `Orkestra.EventStore.EventStoreDB`
- Supporting: `Orkestra.CommandEnvelope`, `Orkestra.EventEnvelope`, `Orkestra.Metadata`, `Orkestra.Telemetry`
- MCP: `OrkestraMcp`, `OrkestraMcp.Introspection`, `OrkestraMcp.Generator`, `OrkestraMcp.Naming`, etc.

**Command/Event Modules (in applications):**
- Commands: `MyApp.{BoundedContext}.Commands.{NamedCommand}` (e.g., `MyApp.Orders.Commands.PlaceOrder`)
- Events: `MyApp.{BoundedContext}.Events.{NamedEvent}` (e.g., `MyApp.Orders.Events.OrderPlaced`)
- Aggregates: `MyApp.{BoundedContext}.{EntityName}Aggregate` (e.g., `MyApp.Orders.OrderAggregate`)
- Command Handlers: `MyApp.{Handler}{CommandName}` or `MyApp.{BoundedContext}.Handle{CommandName}` (e.g., `MyApp.HandlePlaceOrder`)
- Event Handlers: `MyApp.On{EventName}` or `MyApp.{BoundedContext}.On{EventName}` (e.g., `MyApp.OnOrderPlaced`)

## Where to Add New Code

**New Feature (Command + Handler + Events):**
- Command module: `lib/{app}/{bounded_context}/commands/{command_name}.ex` (in target application, not Orkestra)
- Event modules: `lib/{app}/{bounded_context}/events/{event_name}.ex`
- CommandHandler: `lib/{app}/{bounded_context}/handlers/handle_{command_name}.ex` or `lib/{app}/handle_{command_name}.ex`
- EventHandlers: `lib/{app}/{bounded_context}/handlers/on_{event_name}.ex` or `lib/{app}/on_{event_name}.ex`
- Tests: `test/{app}/{bounded_context}/` (mirror source structure)

**New Aggregate:**
- Location: `lib/{app}/{bounded_context}/{aggregate_name}_aggregate.ex`
- Example: `lib/my_app/orders/order_aggregate.ex`
- Must implement: `Orkestra.Aggregate` behaviour (init_state, stream_id, evolve, decide)
- Optional: snapshot_every/0 for snapshotting

**New Component in Orkestra Library:**
- If it's a core abstraction: `lib/orkestra/{component}.ex` (create behaviour/struct)
- If it's an adapter: `lib/orkestra/{subsystem}/{adapter_name}.ex`
- Update `mix.exs` if new external dependencies are needed
- Add corresponding tests in `test/orkestra/{component}_test.exs`

**New MCP Tool:**
- Location: `orkestra_mcp/lib/orkestra_mcp/tools/gen_{component}.ex`
- Must provide: code generation function returning `{source_code, file_path}` tuple
- Register in `orkestra_mcp/lib/orkestra_mcp/server.ex` in tools list

**New MCP Resource:**
- Location: `orkestra_mcp/lib/orkestra_mcp/resources/{list_or_view}_{components}.ex`
- Must provide: introspection function for querying project structure
- Use `OrkestraMcp.Introspection.discover/1` to scan project

## Special Directories

**test/:**
- Purpose: ExUnit tests for Orkestra core
- Generated: No (human-maintained)
- Committed: Yes

**orkestra_mcp/test/fixtures/sample_project/:**
- Purpose: Reference Orkestra-based project for introspection/generation testing
- Generated: No (fixture maintained by hand)
- Committed: Yes
- Structure demonstrates: commands/, events/, handlers/, aggregate patterns

**lib/orkestra/ (sub-directories):**
- `message_bus/` — MessageBus adapters and handler behaviour
- `event_store/` — EventStore adapters and snapshot logic
- `aggregate/` — Aggregate.Root orchestration

**orkestra_mcp/ (sub-directories):**
- `tools/` — MCP tool implementations (code generation)
- `resources/` — MCP resource implementations (introspection)
- `prompts/` — MCP prompt implementations (guided workflows)

---

*Structure analysis: 2026-06-24*
