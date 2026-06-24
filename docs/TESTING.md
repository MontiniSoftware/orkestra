<!-- generated-by: gsd-doc-writer -->
# Testing

Orkestra is split into two independent Mix projects, each with its own test suite: the core library at the repository root and the MCP server at `orkestra_mcp/`. Both use ExUnit. This guide covers the test layout, how to run tests, and the in-memory infrastructure that makes the test suite self-contained.

## Test framework and setup

Both projects use [ExUnit](https://hexdocs.pm/ex_unit/ExUnit.html), the standard Elixir test framework included with the language runtime. No additional test libraries are required beyond each project's normal dependencies.

### Core library (`test/`)

`test/test_helper.exs` starts a `Phoenix.PubSub` supervisor under the name `Orkestra.PubSub` and configures the message bus to use the in-memory `Orkestra.MessageBus.PubSub` adapter:

```elixir
Application.put_env(:orkestra, Orkestra.MessageBus,
  adapter: Orkestra.MessageBus.PubSub,
  app_prefix: nil
)

Application.put_env(:orkestra, Orkestra.MessageBus.PubSub,
  pubsub: Orkestra.PubSub
)

{:ok, _} = Phoenix.PubSub.Supervisor.start_link(name: Orkestra.PubSub)

ExUnit.start()
```

This means every test in the core library runs against a real (but in-process) pub/sub bus without any external broker. No environment variables or external services are needed.

### MCP server (`orkestra_mcp/test/`)

`orkestra_mcp/test/test_helper.exs` simply calls `ExUnit.start()`. The MCP server tests are stateless — tool tests create a temporary directory on the filesystem and clean it up in `on_exit/1` callbacks.

## Running tests

### Core library

Run the full suite from the repository root:

```bash
mix test
```

Run a single test file:

```bash
mix test test/orkestra/command_test.exs
```

Run a single test by line number:

```bash
mix test test/orkestra/command_test.exs:24
```

### MCP server

Run the full suite from within the `orkestra_mcp/` directory:

```bash
cd orkestra_mcp
mix test
```

Run a single test file:

```bash
mix test test/orkestra_mcp/generator_test.exs
```

Run a single test by line number:

```bash
mix test test/orkestra_mcp/tools/gen_command_test.exs:19
```

## Core library test layout (`test/orkestra/`)

Each module under `lib/orkestra/` has a corresponding test file. All unit tests use `async: true`; tests that interact with the pub/sub bus use `async: false` because they register named processes and shared bus state.

| Test file | Module under test | `async` |
|---|---|---|
| `orkestra/command_test.exs` | `Orkestra.Command` | `true` |
| `orkestra/event_test.exs` | `Orkestra.Event` | `true` |
| `orkestra/metadata_test.exs` | `Orkestra.Metadata` | `true` |
| `orkestra/command_envelope_test.exs` | `Orkestra.CommandEnvelope` | `true` |
| `orkestra/event_envelope_test.exs` | `Orkestra.EventEnvelope` | `true` |
| `orkestra/message_bus_test.exs` | `Orkestra.MessageBus` (topic helpers) | `true` |
| `orkestra/message_bus/pub_sub_test.exs` | `Orkestra.MessageBus.PubSub` | `false` |
| `orkestra/command_handler_test.exs` | `Orkestra.CommandHandler` | `false` |
| `orkestra/event_handler_test.exs` | `Orkestra.EventHandler` | `false` |

### Command and event tests

`command_test.exs` and `event_test.exs` define inline modules (e.g., `StartTask`, `TaskCompleted`) to exercise the `use Orkestra.Command` and `use Orkestra.Event` macros directly. They cover:

- `new/2` — happy path, default values, string key coercion, missing required params/fields
- `new!/2` — raises on failure
- `from_command/2` and `from_event/2` — metadata propagation (correlation chain, causation ID, actor)
- `field_definitions/0` and `param_definitions/0` — introspection callbacks

### Metadata test

`metadata_test.exs` covers `Metadata.new/1` (generates `correlation_id`, sets `issued_at`, accepts actor options) and `Metadata.derive/2` (preserves `correlation_id`, sets `causation_id`, carries actor through the chain).

### Envelope tests

`command_envelope_test.exs` and `event_envelope_test.exs` cover the full lifecycle state machines:

- `CommandEnvelope`: `pending → dispatched → succeeded|failed|rejected`, retry eligibility via `retryable?/1`, and middleware context via `put_context/3` / `get_context/3`.
- `EventEnvelope`: `pending → published → handled|partially_handled|failed`, per-handler tracking (`register_handler`, `mark_handler_succeeded`, `mark_handler_failed`, `mark_handler_skipped`, `mark_handler_processing`), and `all_handled?/1`.

### MessageBus topic helper test

`message_bus_test.exs` (async) tests `MessageBus.topic_for/1` — the conversion of module names to dot-separated topic strings — with and without the `app_prefix` configuration option. It uses `Application.put_env/3` inside a `setup` block and restores the original value with `on_exit/1`.

### PubSub integration test

`message_bus/pub_sub_test.exs` (not async) starts a fresh `Orkestra.MessageBus.PubSub` GenServer with `start_supervised!/1` for each test and registers the test process as `:test_process` so handler callbacks can send messages back via `Process.whereis(:test_process)`. It covers:

- `dispatch/1` — delivery to a registered command handler, error when no handler, error return, exception catching, and retry with `max_retries`
- `publish/1` — delivery to event handlers, wildcard topic matching (`"prefix.#"`)
- Dead-letter delivery — failed commands are broadcast on `"orkestra:deadletter"` after retries are exhausted

### CommandHandler and EventHandler tests

Both test files (not async) start a fresh bus with `start_supervised!({Bus, []})` and then `start_supervised!` each handler under test. The handler tests validate:

- `CommandHandler` — auto-subscription on startup, dispatch to `execute/2`, error and crash return shapes, and dead-letter after `max_retries`
- `EventHandler` — `event:` (single), `events:` (multiple), and `topic:` subscription modes, non-delivery of unsubscribed events, error and crash resilience, and dead-letter after `max_retries`

## In-memory pub/sub in tests

The `Orkestra.MessageBus.PubSub` GenServer is the sole adapter used during testing. It is entirely in-process: no AMQP broker or EventStore connection is required. Tests that need an isolated bus instance call `start_supervised!({Bus, []})` — ExUnit's supervision ensures the GenServer is stopped and its state discarded at the end of each test.

The `Orkestra.PubSub` Phoenix.PubSub instance (started in `test_helper.exs`) is used for dead-letter notifications. Tests that assert on dead-letter behaviour subscribe directly:

```elixir
Phoenix.PubSub.subscribe(Orkestra.PubSub, "orkestra:deadletter")
# ... trigger failure ...
assert_receive {:dead_letter, entry}
```

## MCP server test layout (`orkestra_mcp/test/`)

| Test file | Module under test | `async` |
|---|---|---|
| `orkestra_mcp/naming_test.exs` | `OrkestraMcp.Naming` | `true` |
| `orkestra_mcp/introspection_test.exs` | `OrkestraMcp.Introspection` | `true` |
| `orkestra_mcp/generator_test.exs` | `OrkestraMcp.Generator` | `true` |
| `orkestra_mcp/tools/gen_command_test.exs` | `OrkestraMcp.Tools.GenCommand` | `false` |
| `orkestra_mcp/tools/gen_event_test.exs` | `OrkestraMcp.Tools.GenEvent` | `false` |
| `orkestra_mcp/tools/gen_command_handler_test.exs` | `OrkestraMcp.Tools.GenCommandHandler` | `false` |
| `orkestra_mcp/tools/gen_event_handler_test.exs` | `OrkestraMcp.Tools.GenEventHandler` | `false` |
| `orkestra_mcp/tools/gen_aggregate_test.exs` | `OrkestraMcp.Tools.GenAggregate` | `false` |

### Naming test

`naming_test.exs` covers `Naming.module_to_file_path/1` (Elixir module name to `lib/` file path) and `Naming.infer_app_module/1` (reads `app:` from `mix.exs`). The `infer_app_module` test points at the fixture project described below.

### Introspection test

`introspection_test.exs` sets `@fixture_dir` at compile time:

```elixir
@fixture_dir Path.join([__DIR__, "..", "fixtures", "sample_project"]) |> Path.expand()
```

It calls `Introspection.discover(@fixture_dir)` and asserts on the returned map keys (`commands`, `events`, `command_handlers`, `event_handlers`, `aggregates`). It also tests `Introspection.build_domain_map/1`, which returns a human-readable string of the discovered domain.

### Generator test

`generator_test.exs` exercises code-generation functions directly:

- `Generator.gen_command/2` — returns `{source, file_path}`; asserts the source contains the correct `use Orkestra.Command` and `param` declarations and parses as valid Elixir via `Code.string_to_quoted/1`
- `Generator.gen_event/2` — same pattern for events
- `Generator.gen_command_handler/2` — generates a handler with a `def execute/2` stub
- `Generator.gen_event_handler/2` — three modes: `"single"`, `"multi"`, `"topic"`
- `Generator.gen_aggregate/4` — generates `decide/2` and `evolve/2` clauses for each command and event
- `Generator.write!/3` — creates a real file in a random `System.tmp_dir!()` subdirectory and removes it in an `after` block

### Tool tests (`tools/`)

The tool tests validate the MCP tool entry points (`execute/2`) end-to-end, including filesystem writes. Each test follows the same pattern:

1. `setup` creates a unique temporary directory and sets `:orkestra_mcp, :project_dir` to it.
2. The test calls `ToolModule.execute/2` with a params map and `nil` context.
3. Assertions check the returned result string and the presence of the written file.
4. `on_exit/1` removes the temporary directory and deletes the application env key.

Tools under test: `GenCommand`, `GenEvent`, `GenCommandHandler`, `GenEventHandler`, `GenAggregate`. Tool tests use `async: false` because they write to the application environment.

## Test fixture: `sample_project`

Located at `orkestra_mcp/test/fixtures/sample_project/`, this is a minimal Elixir project used by `introspection_test.exs` and `naming_test.exs`. It does not have its own dependencies or test suite — it is source files only.

```
test/fixtures/sample_project/
  mix.exs                                          # app: :my_app
  lib/
    my_app/
      inventory/
        track_stock.ex                             # Command with 2 params
      orders/
        commands/
          place_order.ex                           # Command with 2 params
        events/
          order_placed.ex                          # Event with 3 fields
        handlers/
          audit_logger.ex                          # EventHandler with topic:
          place_order_handler.ex                   # CommandHandler
          send_confirmation.ex                     # EventHandler with event:
          update_index.ex                          # EventHandler with events:
        order_aggregate.ex                         # Aggregate
```

The fixture covers all four handler subscription modes (`command:`, `event:`, `events:`, `topic:`) and is intentionally small so introspection tests run fast without needing to compile any modules.

## Writing new tests

Test files follow the naming convention `<module_name>_test.exs`. Place them under:

- `test/orkestra/` for core library modules
- `orkestra_mcp/test/orkestra_mcp/` for MCP server modules
- `orkestra_mcp/test/orkestra_mcp/tools/` for MCP tool modules

All tests use `use ExUnit.Case`. Set `async: true` for pure unit tests with no shared state. Set `async: false` for tests that call `start_supervised!` on the `PubSub` bus or write to `Application` environment.

Inline module definitions inside test modules (as used by `command_test.exs` and `event_test.exs`) are the standard pattern for testing `use` macros without needing separate fixture files.

## Coverage requirements

No coverage thresholds are configured in either project.
