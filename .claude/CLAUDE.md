<!-- GSD:project-start source:PROJECT.md -->

## Project

**Orkestra**

Orkestra is an Elixir CQRS / event-sourcing library (plus an `orkestra_mcp` MCP server/CLI for code generation) for building event-driven Elixir applications. This milestone adds a **projection / read-model subsystem** — `event → projector → database` — that makes it easy for developers to derive and maintain read models from their event streams, starting with PostgreSQL and extending to MongoDB and Elasticsearch.

**Core Value:** A developer can define a projection that consumes domain events and maintains a queryable read model — with safe rebuilds, in-order error handling, and per-projection migrations — without writing the plumbing themselves.

### Constraints

- **Tech stack**: Elixir `~> 1.18`; projections build on **Ecto** for the Postgres adapter (migrations/rollbacks/queries). Storage deps are optional dependencies, consistent with the existing amqp/spear approach.
- **Compatibility**: Must integrate with the existing event store + message bus rather than replacing them; projectors are additive consumers of the event stream.
- **Architecture**: Shared projector lifecycle (subscription, checkpoints, retry/park-halt error handling, replay/rebuild) with **per-adapter** storage write/query APIs — each backend stays idiomatic.
- **Observability**: Reuse the existing OpenTelemetry `Telemetry` module conventions for all new spans/metrics.

<!-- GSD:project-end -->

<!-- GSD:stack-start source:codebase/STACK.md -->

## Technology Stack

## Languages

- Elixir 1.18+ - Core CQRS/ES library (`lib/orkestra/`) and MCP server/CLI (`orkestra_mcp/`)
- Node.js 22.0.0 - Development tooling only (not runtime dependency)

## Runtime

- Erlang/OTP (compatible with Elixir 1.18, typically OTP 27+)
- Mix (Elixir's package manager)
- Lockfile: `mix.lock` (orkestra), `orkestra_mcp/mix.lock` (MCP subproject)

## Frameworks

- Phoenix.PubSub 2.2.0 - In-process message bus for dev/test (single-node)
- Hermes.MCP 0.14.1 - MCP (Model Context Protocol) server framework for `orkestra_mcp/`
- ExDoc 0.40.1 - Documentation generation (dev-only, runtime: false)

## Key Dependencies

- Jason 1.4.4 - JSON encoding/decoding for serialization across message bus and event store
- OpenTelemetry API 1.5.0 - Observability instrumentation (tracing spans, context propagation)
- AMQP 4.1.0 - Optional, RabbitMQ adapter for distributed message bus via amqp_client 4.2.1
- Spear 1.4.1 - Optional, EventStoreDB adapter via gRPC with event_store_db_gpb_protobufs 2.4.0
- OpenTelemetry Process Propagator 0.3.0 - Optional, trace context propagation across Erlang processes
- Finch 0.21.0 - HTTP client for hermes_mcp
- Mint 1.7.1 - HTTP/2 transport layer
- Gun 2.2+ - Optional, alternative HTTP transport for hermes_mcp
- Connection 1.1.0 - Connection pooling for Spear
- GPB 4.21.7 - Protocol buffer compiler for EventStoreDB gRPC communication
- HPAX 1.0.3 - HTTP/2 RFC-compliant priority encoding
- amqp_client 4.2.1 - RabbitMQ Erlang client
- rabbit_common 4.2.1 - RabbitMQ common libraries
- credentials_obfuscation 3.5.0 - RabbitMQ credential handling
- Ranch 2.2.0 - TCP/socket abstraction
- Recon 2.5.6 - RabbitMQ introspection
- Thoas 1.2.1 - JSON encoder (RabbitMQ dep)
- Telemetry 1.4.1 - Metrics and events (used by hermes_mcp)
- Peri 0.6.2 - Schema/API introspection for hermes_mcp (with optional Ecto support)
- MIME 2.0.7 - HTTP content-type handling

## Configuration

- Configuration via `config/config.exs` per Elixir environment (dev, test, prod)
- orkestra_mcp forces MCP stdio (clean stdout for protocol), routes logs to stderr at `:warning` level
- Optional runtime configuration for:
- `mix.exs` for orkestra (library)
- `orkestra_mcp/mix.exs` for MCP server and CLI escript
- `.formatter.exs` for code formatting (covers `lib/`, `test/`, `config/`)

## Platform Requirements

- Elixir 1.18+ (required by both mix.exs files)
- Erlang/OTP 27+ (inferred from Elixir 1.18 compatibility)
- Optional: RabbitMQ 3.8+ for AMQP testing
- Optional: EventStoreDB 24+ for gRPC adapter testing
- Node.js 22.0.0 (dev tooling only)
- Erlang/OTP runtime
- Optional: RabbitMQ 3.8+ (for distributed deployments)
- Optional: EventStoreDB 24+ (for event persistence with optimistic concurrency)

<!-- GSD:stack-end -->

<!-- GSD:conventions-start source:CONVENTIONS.md -->

## Conventions

## Naming Patterns

- Snake_case with `.ex` extension: `command_handler.ex`, `event_store.ex`
- Underscored directory structure mirrors module hierarchy: `lib/orkestra/message_bus/pub_sub.ex` → `Orkestra.MessageBus.PubSub`
- Test files mirror source structure with `_test.exs` suffix: `test/orkestra/command_handler_test.exs`
- CamelCase: `Orkestra.Command`, `Orkestra.CommandHandler`, `Orkestra.MessageBus.PubSub`
- Modules using macros have descriptive names: `Orkestra.Command` (provides `param` macro), `Orkestra.Event` (provides `field` macro)
- Subproject uses different prefix: `OrkestraMcp` (not `Orkestra.MCP`)
- snake_case: `generate_id()`, `topic_for()`, `dispatch()`, `publish()`, `stream_id()`
- Callbacks in behaviours: `execute/2`, `handle_event/2`, `decide/2`, `evolve/2`, `init_state/0`
- Private helper functions: `normalize_params/1`, `check_required/1`, `load_and_fold/2`
- Public API functions use descriptive names: `new/2` (constructor), `new!/2` (bang version), `from_command/2` (factory)
- Atom keys for structs and pattern matching: `:ok`, `:error`, `:missing_params`
- Long variable names for clarity in complex functions: `command`, `metadata`, `expected_revision`, `stream_id`
- Underscore prefix for intentionally unused variables: `_opts`, `_metadata`
- @type definitions use snake_case: `execute_result`, `param_definition`, `field_definition`
- Standard Elixir atom types: `:atom`, `:string`, `:integer`, `:float`, `:list`, `:map`
- Custom struct types use the full module name: `Orkestra.Command.t()`, `Orkestra.Event.t()`

## Code Style

- Tool: `mix format` (Elixir built-in formatter)
- Config: `.formatter.exs` in both `/home/th4t/Documents/personal/orkestra/.formatter.exs` and `/home/th4t/Documents/personal/orkestra/orkestra_mcp/.formatter.exs`
- Standard Elixir formatting rules (2-space indentation, column wrapping)
- No explicit linter config found; relies on formatter and manual code review
- Credo may be used in practice (common in Elixir projects) but not configured in the examined files

## Import Organization

- `alias` used for commonly-accessed modules
- Long module paths frequently aliased: `alias Orkestra.MessageBus.PubSub, as: Bus`
- Multi-module aliases use `{Module1, Module2}` syntax

## Error Handling

- Return tuples (Erlang-style): `:ok` for success, `{:ok, value}` for success with result, `{:error, reason}` for failure
- Bang functions (`new!`, `write!`) raise on error instead of returning `{:error, _}`
- Exception handling in critical code paths: wrap in `rescue` and log, return `{:error, {:handler_crash, message}}`
- Command/Event creation: `{:ok, cmd} = StartTask.new(%{...})` or `{:error, {:missing_params, keys}}`
- Handler execution: `case execute(command, metadata) do :ok -> :ok; {:error, reason} -> handle_error end`
- Aggregate operations: optimistic concurrency retry on `{:error, :wrong_expected_version}`
- Structured errors: `{:missing_params, [:key1, :key2]}` not `{:error, "message"}`
- Early validation in factories: check required fields before returning success
- Callables can override default validation: override `@impl true def validate(params)` in Command/Event modules

## Logging

- `Logger.debug/2` — Low-level operational details (command received, event folding)
- `Logger.info/2` — Important lifecycle events (handler subscribed, command succeeded)
- `Logger.warning/2` — Recoverable failures (handler subscribe retry, command execution failure, concurrency conflict)
- `Logger.error/2` — Unrecoverable failures (handler crash, max retries exhausted)
- Always include structured metadata (key-value pairs), not just the message
- Use `orkestra: :domain_area` tag for filtering/alerting (`orkestra: :command_handler`, `orkestra: :aggregate`)
- Log at decision points (subscription, success, failure, retry)
- `OpenTelemetry.Tracer` used alongside Logger for span context
- `OTel.set_logger_metadata()` / `OTel.clear_logger_metadata()` bracket operation boundaries

## Comments

- Module/function @doc/@moduledoc is **required** — every public function and module has documentation
- Inline comments only for non-obvious logic (e.g., "optimistic concurrency retry on wrong_expected_version")
- Comments describe **why**, not **what** (readers can read the code for "what")
- High-level behavior and usage examples
- Configuration instructions
- Links to related modules

## Defining a command

## Building a command

## Function Design

- Most functions 5-30 lines
- Larger functions broken into helpers: `do_execute/6` delegates to `load_and_fold/2`, `decide/3`, `append/3`
- Macros use `__before_compile__` callbacks to keep macro expansion clean
- Use pattern matching on first argument to distinguish clauses: `def decide(%{status: :new}, cmd)` vs `def decide(%{status: :open}, cmd)`
- Options passed as keyword lists: `opts \\ []` with `Keyword.get(opts, :key, default)`
- Envelopes and contexts passed explicitly, not via process state (pure functions in aggregates)
- Single return type per function: all paths return `:ok` or `{:error, reason}` or a value
- Success with value: `{:ok, result}` tuple
- Failure: `{:error, reason}` where reason is typically an atom or `{:error_type, details}`
- Optional callbacks return `:ok` or `{:error, _}` — no mixed `nil` and error tuples
- `@spec` used on public functions: `@spec new(map(), keyword()) :: {:ok, Command.t()} | {:error, term()}`
- Spec format: parameter types, return type with pipe-separated alternatives
- Type names fully qualified: `Orkestra.Command.t()`, not shorthand

## Module Design

- All public functions are implicitly exported (no explicit exports in Elixir)
- Functions intended as public (in behavior contracts) are listed in `@callback`
- Macros imported with `import ModuleName, only: [param: 2, param: 3]`
- Not used in this codebase
- Each module in its own file with clear responsibility boundary
- Defined via `@callback` directives and optionally `@optional_callbacks`
- Implementations use `@behaviour ModuleName` and `@impl true` on each callback

## Macro Patterns

<!-- GSD:conventions-end -->

<!-- GSD:architecture-start source:ARCHITECTURE.md -->

## Architecture

## System Overview

```text

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

- **Pure aggregates** — domain logic is pure functions (`evolve`, `decide`) with no I/O
- **Imperative shell** — Aggregate.Root handles all side effects (event store, message bus)
- **Optimistic concurrency** — expected_version check on append, automatic retry on conflict
- **Metadata threading** — correlation_id and causation_id flow through command → event → handler chain
- **Pluggable adapters** — MessageBus (PubSub or RabbitMQ), EventStore (InMemory or EventStoreDB)
- **OpenTelemetry integration** — all critical paths emit spans and structured logs

## Layers

- Purpose: Provide ergonomic struct builders with validation
- Location: `lib/orkestra/command.ex`, `lib/orkestra/event.ex`
- Contains: Macros (`param`, `field`) that emit struct definitions, builders, validators
- Depends on: Metadata for context
- Used by: Applications defining domain commands and events
- Purpose: Auto-subscribe and dispatch messages to application code
- Location: `lib/orkestra/command_handler.ex`, `lib/orkestra/event_handler.ex`
- Contains: GenServer-based handlers with envelope unwrapping and ack/nack logic
- Depends on: MessageBus for subscriptions, Telemetry for tracing
- Used by: Applications implementing event-driven reactions
- Purpose: Orchestrate the command processing pipeline
- Location: `lib/orkestra/aggregate/root.ex`, `lib/orkestra/aggregate.ex`
- Contains: Load-fold-decide-append-publish with retry logic and snapshots
- Depends on: EventStore, MessageBus, Snapshot
- Used by: CommandHandlers or direct calls to Aggregate.Root.execute/3
- Purpose: Track dispatch state, retries, correlation, and causation
- Location: `lib/orkestra/*_envelope.ex`, `lib/orkestra/metadata.ex`
- Contains: Immutable envelope structures with status transitions
- Depends on: Command, Event
- Used by: All layers for request/response context
- Purpose: Decouple command/event producers from handlers
- Location: `lib/orkestra/message_bus.ex` (behaviour), `lib/orkestra/message_bus/*.ex` (adapters)
- Contains: Point-to-point command dispatch, broadcast event publishing
- Depends on: None
- Used by: Aggregate.Root (publish), CommandHandler/EventHandler (subscribe)
- Purpose: Persist events with optimistic concurrency and snapshotting
- Location: `lib/orkestra/event_store.ex` (behaviour), `lib/orkestra/event_store/*.ex` (adapters)
- Contains: Stream-based append, load with revision, snapshots
- Depends on: None
- Used by: Aggregate.Root for load_events, append_events; Snapshot for state capture

## Data Flow

### Primary Command Execution Path

### Snapshot Lifecycle

- **Trigger:** After append, if `total_event_count % snapshot_every() == 0`
- **Action:** Save state to `snapshot-{stream_id}` stream
- **Next Load:** Skip all events before snapshot revision, replay only newer events
- Aggregate state is reconstructed on every command execution (stateless)
- No shared mutable state across executions
- Concurrency handled by optimistic versioning, not locks

## Key Abstractions

- Purpose: Encapsulate domain logic as pure state machines
- Examples: `MyApp.Orders.OrderAggregate`, `MyApp.Accounts.AccountAggregate`
- Pattern: Implements `init_state`, `stream_id`, `evolve`, `decide` (and optional `snapshot_every`)
- Purpose: Represent user intent with validated parameters
- Examples: `StartAssessment.new(%{...})`, `PlaceOrder.new!(%{...})`
- Pattern: `use Orkestra.Command`, declare `param :name, :type, ...`, auto-generated `new/2`, `new!/2`
- Purpose: Record immutable facts with correlated metadata
- Examples: `AssessmentCompleted.from_command(cmd, %{...})`, `Event.new!(%{...})`
- Pattern: `use Orkestra.Event`, declare `field :name, :type, ...`, auto-generated `new/2`, `from_command/2`
- Purpose: Auto-subscribe to topics and provide ergonomic callback interface
- Pattern: `use Orkestra.CommandHandler, command: MyCommand` or `use Orkestra.EventHandler, event: MyEvent`
- Generates GenServer with `handle/1` that unwraps envelope and calls user's `execute/2` or `handle_event/2`
- Purpose: Decouple producers from consumers, support both in-process and distributed
- Adapters: PubSub (in-process), RabbitMQ (distributed)
- Pattern: Topics derived from module names, e.g., `MyApp.Orders.Commands.PlaceOrder` → `orders.commands.place_order`
- Purpose: Persist events with transactional guarantees and snapshot optimization
- Adapters: InMemory (test), EventStoreDB (production)
- Pattern: Streams identified by string id, events have revision for concurrency control

## Entry Points

- Location: `lib/orkestra/aggregate/root.ex:execute/3`
- Triggers: Called directly by command handlers or external commands
- Responsibilities: Load state, decide, append, publish; retry on concurrency conflict
- Location: `lib/orkestra/command_handler.ex`
- Triggers: GenServer started in supervision tree, auto-subscribes to command topic
- Responsibilities: Deserialize envelope, call user's execute callback, ack/nack
- Location: `lib/orkestra/event_handler.ex`
- Triggers: GenServer started in supervision tree, auto-subscribes to event topic(s)
- Responsibilities: Deserialize envelope, call user's handle_event callback, ack/nack
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

### Mixing Pure and Impure Code in Aggregates

### Ignoring Concurrency Conflicts

### Using Metadata.correlation_id as Business Logic

## Error Handling

- **Command validation fails:** Return `{:error, {:missing_params, keys}}` immediately in `new/2`
- **Aggregate decide fails:** Return `{:error, reason}` from decide, don't emit events, Aggregate.Root propagates error
- **Event append fails (concurrency):** Aggregate.Root catches `:wrong_expected_version` and retries
- **EventStore I/O fails:** Logged and returned as `{:error, reason}`, Root.execute fails
- **MessageBus publish fails:** Logged but doesn't block append (events are already persisted)
- **Handler execution fails:** Returns `{:error, reason}`, nacks envelope, triggers retry/dead-letter per adapter

## Cross-Cutting Concerns

<!-- GSD:architecture-end -->

<!-- GSD:skills-start source:skills/ -->

## Project Skills

No project skills found. Add skills to any of: `.claude/skills/`, `.agents/skills/`, `.cursor/skills/`, `.github/skills/`, or `.codex/skills/` with a `SKILL.md` index file.
<!-- GSD:skills-end -->

<!-- GSD:workflow-start source:GSD defaults -->

## GSD Workflow Enforcement

Before using Edit, Write, or other file-changing tools, start work through a GSD command so planning artifacts and execution context stay in sync.

Use these entry points:

- `/gsd-quick` for small fixes, doc updates, and ad-hoc tasks
- `/gsd-debug` for investigation and bug fixing
- `/gsd-execute-phase` for planned phase work

Do not make direct repo edits outside a GSD workflow unless the user explicitly asks to bypass it.
<!-- GSD:workflow-end -->

<!-- GSD:profile-start -->

## Developer Profile

> Profile not yet configured. Run `/gsd-profile-user` to generate your developer profile.
> This section is managed by `generate-claude-profile` -- do not edit manually.
<!-- GSD:profile-end -->
