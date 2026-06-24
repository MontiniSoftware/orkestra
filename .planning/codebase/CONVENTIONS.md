# Coding Conventions

**Analysis Date:** 2026-06-24

## Naming Patterns

**Files:**
- Snake_case with `.ex` extension: `command_handler.ex`, `event_store.ex`
- Underscored directory structure mirrors module hierarchy: `lib/orkestra/message_bus/pub_sub.ex` → `Orkestra.MessageBus.PubSub`
- Test files mirror source structure with `_test.exs` suffix: `test/orkestra/command_handler_test.exs`

**Modules:**
- CamelCase: `Orkestra.Command`, `Orkestra.CommandHandler`, `Orkestra.MessageBus.PubSub`
- Modules using macros have descriptive names: `Orkestra.Command` (provides `param` macro), `Orkestra.Event` (provides `field` macro)
- Subproject uses different prefix: `OrkestraMcp` (not `Orkestra.MCP`)

**Functions:**
- snake_case: `generate_id()`, `topic_for()`, `dispatch()`, `publish()`, `stream_id()`
- Callbacks in behaviours: `execute/2`, `handle_event/2`, `decide/2`, `evolve/2`, `init_state/0`
- Private helper functions: `normalize_params/1`, `check_required/1`, `load_and_fold/2`
- Public API functions use descriptive names: `new/2` (constructor), `new!/2` (bang version), `from_command/2` (factory)

**Variables:**
- Atom keys for structs and pattern matching: `:ok`, `:error`, `:missing_params`
- Long variable names for clarity in complex functions: `command`, `metadata`, `expected_revision`, `stream_id`
- Underscore prefix for intentionally unused variables: `_opts`, `_metadata`

**Types:**
- @type definitions use snake_case: `execute_result`, `param_definition`, `field_definition`
- Standard Elixir atom types: `:atom`, `:string`, `:integer`, `:float`, `:list`, `:map`
- Custom struct types use the full module name: `Orkestra.Command.t()`, `Orkestra.Event.t()`

## Code Style

**Formatting:**
- Tool: `mix format` (Elixir built-in formatter)
- Config: `.formatter.exs` in both `/home/th4t/Documents/personal/orkestra/.formatter.exs` and `/home/th4t/Documents/personal/orkestra/orkestra_mcp/.formatter.exs`
- Standard Elixir formatting rules (2-space indentation, column wrapping)

**Linting:**
- No explicit linter config found; relies on formatter and manual code review
- Credo may be used in practice (common in Elixir projects) but not configured in the examined files

## Import Organization

**Order:**
1. External dependencies: `Phoenix.PubSub`, `Jason`, `OpenTelemetry`
2. Same-app dependencies: `Orkestra.*` modules
3. Local/internal requires: `require Logger`, `require OpenTelemetry.Tracer`

**Pattern from `command_handler.ex` (line 51-55):**
```elixir
require Logger
require OpenTelemetry.Tracer, as: Tracer

alias Orkestra.{CommandEnvelope, MessageBus}
alias Orkestra.Telemetry, as: OTel
```

**Path Aliases:**
- `alias` used for commonly-accessed modules
- Long module paths frequently aliased: `alias Orkestra.MessageBus.PubSub, as: Bus`
- Multi-module aliases use `{Module1, Module2}` syntax

## Error Handling

**Patterns:**
- Return tuples (Erlang-style): `:ok` for success, `{:ok, value}` for success with result, `{:error, reason}` for failure
- Bang functions (`new!`, `write!`) raise on error instead of returning `{:error, _}`
- Exception handling in critical code paths: wrap in `rescue` and log, return `{:error, {:handler_crash, message}}`

**Examples from codebase:**
- Command/Event creation: `{:ok, cmd} = StartTask.new(%{...})` or `{:error, {:missing_params, keys}}`
- Handler execution: `case execute(command, metadata) do :ok -> :ok; {:error, reason} -> handle_error end`
- Aggregate operations: optimistic concurrency retry on `{:error, :wrong_expected_version}`

**Validation:**
- Structured errors: `{:missing_params, [:key1, :key2]}` not `{:error, "message"}`
- Early validation in factories: check required fields before returning success
- Callables can override default validation: override `@impl true def validate(params)` in Command/Event modules

## Logging

**Framework:** Erlang `Logger` module (builtin, no external dependency)

**Levels used:**
- `Logger.debug/2` — Low-level operational details (command received, event folding)
- `Logger.info/2` — Important lifecycle events (handler subscribed, command succeeded)
- `Logger.warning/2` — Recoverable failures (handler subscribe retry, command execution failure, concurrency conflict)
- `Logger.error/2` — Unrecoverable failures (handler crash, max retries exhausted)

**Pattern from `command_handler.ex` (line 74-78, 109-115):**
```elixir
Logger.info("Command handler #{inspect(__MODULE__)} subscribed",
  handler: inspect(__MODULE__),
  topic: topic,
  orkestra: :command_handler
)

Logger.debug("Handling command",
  handler: inspect(__MODULE__),
  command_type: command.type,
  command_id: command.id,
  orkestra: :command_handler
)
```

**Conventions:**
- Always include structured metadata (key-value pairs), not just the message
- Use `orkestra: :domain_area` tag for filtering/alerting (`orkestra: :command_handler`, `orkestra: :aggregate`)
- Log at decision points (subscription, success, failure, retry)

**Telemetry Integration:**
- `OpenTelemetry.Tracer` used alongside Logger for span context
- `OTel.set_logger_metadata()` / `OTel.clear_logger_metadata()` bracket operation boundaries

## Comments

**When to Comment:**
- Module/function @doc/@moduledoc is **required** — every public function and module has documentation
- Inline comments only for non-obvious logic (e.g., "optimistic concurrency retry on wrong_expected_version")
- Comments describe **why**, not **what** (readers can read the code for "what")

**JSDoc/TSDoc Pattern:**
ExDoc-style module docs (`@moduledoc`) used for:
- High-level behavior and usage examples
- Configuration instructions
- Links to related modules

**Example from `command.ex` (line 2-32):**
```elixir
@moduledoc """
Behaviour and struct builder for CQRS commands.

A command represents an intent to change the system state.
Commands are validated, authorized, and dispatched to a handler.

## Defining a command

    defmodule MyApp.Tasks.Commands.StartAssessment do
      use Orkestra.Command

      param :repo, :string, required: true
      ...
    end

## Building a command

    {:ok, cmd} = StartAssessment.new(%{...})
    cmd.id           # auto-generated
"""
```

Function docs use `@doc` with concise descriptions:
```elixir
@doc "Declares a command parameter."
defmacro param(name, type, opts \\ []) do
```

## Function Design

**Size:**
- Most functions 5-30 lines
- Larger functions broken into helpers: `do_execute/6` delegates to `load_and_fold/2`, `decide/3`, `append/3`
- Macros use `__before_compile__` callbacks to keep macro expansion clean

**Parameters:**
- Use pattern matching on first argument to distinguish clauses: `def decide(%{status: :new}, cmd)` vs `def decide(%{status: :open}, cmd)`
- Options passed as keyword lists: `opts \\ []` with `Keyword.get(opts, :key, default)`
- Envelopes and contexts passed explicitly, not via process state (pure functions in aggregates)

**Return Values:**
- Single return type per function: all paths return `:ok` or `{:error, reason}` or a value
- Success with value: `{:ok, result}` tuple
- Failure: `{:error, reason}` where reason is typically an atom or `{:error_type, details}`
- Optional callbacks return `:ok` or `{:error, _}` — no mixed `nil` and error tuples

**Specs:**
- `@spec` used on public functions: `@spec new(map(), keyword()) :: {:ok, Command.t()} | {:error, term()}`
- Spec format: parameter types, return type with pipe-separated alternatives
- Type names fully qualified: `Orkestra.Command.t()`, not shorthand

## Module Design

**Exports:**
- All public functions are implicitly exported (no explicit exports in Elixir)
- Functions intended as public (in behavior contracts) are listed in `@callback`
- Macros imported with `import ModuleName, only: [param: 2, param: 3]`

**Barrel Files:**
- Not used in this codebase
- Each module in its own file with clear responsibility boundary

**Behaviors:**
- Defined via `@callback` directives and optionally `@optional_callbacks`
- Implementations use `@behaviour ModuleName` and `@impl true` on each callback

**Example from `command_handler.ex` (line 39-40):**
```elixir
@callback execute(command :: map(), metadata :: Orkestra.Metadata.t() | nil) ::
          :ok | {:ok, term()} | {:error, term()}

defmacro __using__(opts) do
  quote do
    @behaviour Orkestra.CommandHandler
```

## Macro Patterns

**Three main macro use cases:**

1. **DSL Macros** — Declarative field/parameter definition
   - `param :name, :type, required: true` in Command modules
   - `field :name, :type, required: true` in Event modules
   - Collected via `Module.register_attribute()` and `@before_compile`

2. **Behavior Helpers** — Auto-wiring handlers
   - `use Orkestra.CommandHandler, command: Module` generates GenServer + subscription logic
   - `use Orkestra.EventHandler, event: Module` generates multi-event support with wildcards
   - Keeps handler implementation focused on business logic (`execute/2`, `handle_event/2`)

3. **Tracing Macros** — Structured concurrency
   - `Tracer.with_span "name", attributes: {...}` wraps operation boundaries
   - Sets span attributes, status, events for observability

**Pattern:**
```elixir
defmacro __using__(opts) do
  quote do
    # Module-level setup
    @behaviour Orkestra.CommandHandler
    Module.register_attribute(__MODULE__, :param_defs, accumulate: true)
    import Orkestra.Command, only: [param: 2, param: 3]
    @before_compile Orkestra.Command
  end
end

defmacro param(name, type, opts \\ []) do
  quote do
    @param_defs {unquote(name), unquote(type), unquote(opts)}
  end
end
```

---

*Convention analysis: 2026-06-24*
