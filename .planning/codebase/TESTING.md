# Testing Patterns

**Analysis Date:** 2026-06-24

## Test Framework

**Runner:**
- ExUnit (Elixir built-in testing framework)
- Mix tasks: `mix test` runs all tests

**Run Commands:**

```bash
# All tests in both projects
mix test                        # From /home/th4t/Documents/personal/orkestra/
mix test --cover               # With coverage analysis
mix test --failed              # Rerun previously failed tests
mix test test/orkestra/command_test.exs:42  # Specific test

# Sub-project tests
cd orkestra_mcp && mix test    # From /home/th4t/Documents/personal/orkestra/orkestra_mcp/

# Watch mode (if ExUnit or livebook-watch is configured)
mix test --stale               # Rerun when files change
```

**Assertion Library:**
- Built-in ExUnit assertions: `assert`, `refute`, `assert_receive`, `refute_receive`
- Regex matching: `assert_raise RuntimeError, ~r/pattern/`
- No external assertion library (Mox, ExMachina) currently used

## Test File Organization

**Location:**
- Core library: `test/orkestra/` mirrors `lib/orkestra/`
- Sub-project: `orkestra_mcp/test/orkestra_mcp/` mirrors `orkestra_mcp/lib/orkestra_mcp/`
- Fixtures: `orkestra_mcp/test/fixtures/sample_project/` — test project with pre-built artifacts

**Naming:**
- Test file: `{module_name}_test.exs`
- Example: `lib/orkestra/command.ex` → `test/orkestra/command_test.exs`

**Structure:**
```
test/
├── test_helper.exs             # Shared setup
├── orkestra/
│   ├── command_test.exs
│   ├── command_handler_test.exs
│   ├── event_test.exs
│   ├── event_handler_test.exs
│   ├── message_bus_test.exs
│   ├── metadata_test.exs
│   ├── command_envelope_test.exs
│   ├── event_envelope_test.exs
│   └── message_bus/
│       └── pub_sub_test.exs

orkestra_mcp/test/
├── test_helper.exs
├── orkestra_mcp/
│   ├── generator_test.exs
│   ├── introspection_test.exs
│   ├── naming_test.exs
│   ├── tools/
│   │   ├── gen_command_test.exs
│   │   ├── gen_command_handler_test.exs
│   │   ├── gen_event_test.exs
│   │   ├── gen_event_handler_test.exs
│   │   └── gen_aggregate_test.exs
│   └── resources/
└── fixtures/
    └── sample_project/         # Complete example project
        ├── lib/
        │   └── my_app/         # Commands, events, handlers, aggregates
        └── mix.exs
```

## Test Structure

**Suite Organization:**

```elixir
defmodule Orkestra.CommandTest do
  use ExUnit.Case, async: true

  # Inline test modules (no external file)
  defmodule StartTask do
    use Orkestra.Command
    param :repo, :string, required: true
    param :branch, :string, default: "main"
  end

  # Describe blocks group related tests
  describe "new/2" do
    test "creates a command with required params" do
      assert {:ok, cmd} = StartTask.new(%{repo: "owner/repo"})
      assert cmd.params.repo == "owner/repo"
    end

    test "generates a unique id" do
      {:ok, cmd1} = StartTask.new(%{repo: "a"})
      {:ok, cmd2} = StartTask.new(%{repo: "b"})
      assert cmd1.id != cmd2.id
    end
  end

  describe "custom validate/1" do
    test "passes valid params" do
      assert {:ok, _} = ValidatedCommand.new(%{count: 5})
    end
  end
end
```

**Patterns:**

- **Setup:** One of two patterns:
  1. Inline test modules for fixtures (Commands, Events, Handlers)
  2. ExUnit `setup` block for shared state (`do: ... on_exit(fn -> ... end)`)

- **Teardown:** `on_exit/1` callback for cleanup:
  ```elixir
  setup do
    tmp_dir = Path.join(System.tmp_dir!(), "test_#{:rand.uniform(100_000)}")
    File.mkdir_p!(tmp_dir)
    Application.put_env(:orkestra_mcp, :project_dir, tmp_dir)

    on_exit(fn ->
      File.rm_rf!(tmp_dir)
      Application.delete_env(:orkestra_mcp, :project_dir)
    end)

    %{tmp_dir: tmp_dir}
  end
  ```

- **Assertion pattern:**
  ```elixir
  # Pattern matching on result tuple
  assert {:ok, cmd} = StartTask.new(%{repo: "a"})
  assert {:error, {:missing_params, [:repo]}} = StartTask.new(%{})

  # Message bus interaction
  assert :ok = Bus.dispatch(env)
  assert_receive {:executed, %{name: "test task"}}
  refute_receive {:executed, _}, 100  # Within 100ms
  ```

## Mocking

**Framework:** None explicitly used; instead, **process-based communication** with Phoenix.PubSub

**Patterns:**

1. **Message-based assertions** (no Mox):
   ```elixir
   defmodule SuccessfulHandler do
     use Orkestra.CommandHandler, command: CreateTask

     @impl true
     def execute(command, _metadata) do
       send(Process.whereis(:cmd_test), {:executed, command.params})
       {:ok, %{id: "created"}}
     end
   end

   setup do
     Process.register(self(), :cmd_test)
     :ok
   end

   test "handler processes command" do
     start_supervised!(SuccessfulHandler)
     # ... dispatch command ...
     assert_receive {:executed, %{name: "test task"}}
   end
   ```

2. **Subscription and publish testing** (from `event_handler_test.exs`):
   ```elixir
   setup do
     start_supervised!({Bus, []})
     Process.register(self(), :evt_test)
     :ok
   end

   test "handles the subscribed event" do
     start_supervised!(SingleEventHandler)
     Process.sleep(500)  # Give handler time to subscribe

     {:ok, event} = TaskCompleted.new(%{task_id: "t1"})
     env = EventEnvelope.wrap(event)

     assert :ok = Bus.publish(env)
     assert_receive {:single, %{task_id: "t1"}}
   end
   ```

**What to Mock:**
- Don't mock: Command/Event creation, validation, basic domain logic
- Test instead: Full integration via message bus

**What NOT to Mock:**
- Handler registration and subscription (test with `start_supervised!`)
- Message dispatch/publish (use in-process `Phoenix.PubSub` directly in tests)
- Retry logic (it's part of the contract)

## Fixtures and Factories

**Test Data:**

Commands and Events created inline with `.new()`:
```elixir
{:ok, cmd} = StartTask.new(%{repo: "owner/repo", branch: "dev"})
{:ok, event} = TaskCompleted.new(%{task_id: "t1", status: "success"})
```

**Sample Project Fixture:**

`orkestra_mcp/test/fixtures/sample_project/` is a **complete, working Orkestra project**:
- `lib/my_app/orders/commands/place_order.ex` — Example command
- `lib/my_app/orders/events/order_placed.ex` — Example event
- `lib/my_app/orders/handlers/place_order_handler.ex` — Example command handler
- `lib/my_app/orders/handlers/send_confirmation.ex` — Example event handler
- `lib/my_app/orders/order_aggregate.ex` — Example aggregate

Used in `introspection_test.exs` to test code discovery and generation:
```elixir
@fixture_dir Path.join([__DIR__, "..", "fixtures", "sample_project"]) |> Path.expand()

test "discovers commands with params" do
  %{commands: commands} = Introspection.discover(@fixture_dir)
  place_order = Enum.find(commands, &(&1.module == "MyApp.Orders.Commands.PlaceOrder"))
  assert place_order
  assert length(place_order.params) == 2
end
```

**Location:**
- Inline: Test module scope (e.g., `defmodule CreateTask` inside test file)
- Files: `orkestra_mcp/test/fixtures/sample_project/lib/`

## Coverage

**Requirements:** No coverage targets specified in codebase

**View Coverage:**
```bash
mix test --cover
# Outputs: coverage/ directory with .html files
# Open: coverage/index.html in browser
```

**Current coverage:** Not measured in CI/CD visible in this codebase

## Test Types

**Unit Tests:**
- **Scope:** Single module in isolation
- **Approach:** Inline fixtures, assertions on return values
- **Examples:**
  - `command_test.exs`: Tests Command struct creation, validation, required field checking
  - `event_test.exs`: Tests Event struct creation, `from_command/2`, `from_event/2`
  - `metadata_test.exs`: Tests metadata creation and derivation
  - `message_bus_test.exs`: Tests topic generation rules

**Integration Tests:**
- **Scope:** Handler + MessageBus interaction (or Aggregate + EventStore)
- **Approach:** Start GenServers (`start_supervised!`), dispatch/publish via bus, assert messages
- **Examples:**
  - `command_handler_test.exs`: CommandHandler subscription, dispatch, retry/dead-letter
  - `event_handler_test.exs`: EventHandler subscription (single/multi/wildcard), publish, error handling
  - `message_bus/pub_sub_test.exs`: MessageBus.PubSub dispatch/publish integration

**E2E Tests:**
- **Not explicitly present** in test suite
- Alternative: Use `orkestra_mcp/test/fixtures/sample_project/` as manual integration reference

## Common Patterns

**Async Control:**
- `async: true` — No shared state, safe to run in parallel (unit tests)
  - Examples: `command_test.exs`, `event_test.exs`, `metadata_test.exs`
- `async: false` — Requires sequential execution (handler tests, message bus tests)
  - Examples: `command_handler_test.exs`, `event_handler_test.exs`
  - Reason: Phoenix.PubSub subscription state is shared across test cases

**Async Test Example from `command_test.exs`:**
```elixir
defmodule Orkestra.CommandTest do
  use ExUnit.Case, async: true  # Parallel-safe

  defmodule StartTask do
    use Orkestra.Command
    param :repo, :string, required: true
  end

  describe "new/2" do
    test "creates a command with required params" do
      assert {:ok, cmd} = StartTask.new(%{repo: "owner/repo"})
      assert cmd.params.repo == "owner/repo"
    end
  end
end
```

**Non-Async Test Example from `command_handler_test.exs`:**
```elixir
defmodule Orkestra.CommandHandlerTest do
  use ExUnit.Case, async: false  # Sequential only

  setup do
    start_supervised!({Bus, []})  # Shared service
    Process.register(self(), :cmd_test)
    :ok
  end

  test "handler subscribes and processes command" do
    start_supervised!(SuccessfulHandler)
    topic = MessageBus.topic_for(CreateTask)
    wait_for_handler(topic)  # Poll until subscribed
    # ...
  end
end
```

**Async Testing:**
```elixir
# Simple async: assert on return value immediately
test "creates an event" do
  {:ok, event} = MinimalEvent.new(%{message: "x"})
  assert event.data.message == "x"
end

# Message bus async: use assert_receive with timeout
test "handles the subscribed event" do
  start_supervised!(SingleEventHandler)
  Process.sleep(500)  # Give handler time to subscribe

  {:ok, event} = TaskCompleted.new(%{task_id: "t1"})
  Bus.publish(EventEnvelope.wrap(event))

  # Wait up to default timeout (100ms) for message
  assert_receive {:single, %{task_id: "t1"}}
end

# With explicit timeout
refute_receive {:executed, _}, 100  # Fail if message received within 100ms
```

**Error Testing:**
```elixir
# Pattern match on error tuple
test "fails on missing required params" do
  assert {:error, {:missing_params, [:repo]}} = StartTask.new(%{})
end

# Test bang versions raise
test "raises on failure" do
  assert_raise RuntimeError, ~r/validation failed/, fn ->
    StartTask.new!(%{})
  end
end

# Test handler errors are caught
test "catches handler crashes" do
  start_supervised!(CrashingHandler)
  topic = MessageBus.topic_for(CreateTask)
  wait_for_handler(topic)

  {:ok, cmd} = CreateTask.new(%{name: "crash"})
  env = CommandEnvelope.wrap(cmd)

  assert {:error, {:handler_crash, _}} = Bus.dispatch(env)
end
```

## Test Helper Setup

**File:** `/home/th4t/Documents/personal/orkestra/test/test_helper.exs`

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

**What it does:**
1. Configures MessageBus to use PubSub adapter (in-process, not RabbitMQ)
2. Creates named PubSub instance `Orkestra.PubSub` for all tests
3. Starts ExUnit test runner

**File:** `/home/th4t/Documents/personal/orkestra/orkestra_mcp/test/test_helper.exs`

```elixir
ExUnit.start()
```

Simpler (no shared services for MCP tests).

## Key Testing Principles

1. **No external dependencies in tests** — Use in-process PubSub, not RabbitMQ
2. **Deterministic IDs** — Command/Event IDs are generated; tests don't assert on specific values
3. **Timeout awareness** — Handler subscription is async; tests use `Process.sleep()` or polling
4. **Error as data** — Errors returned as tuples, not exceptions (except bang versions)
5. **Pure aggregate logic** — Aggregate tests (if added) would be simple function tests, no I/O
6. **Message-based verification** — Use `send/2` to capture handler behavior, assert on messages

---

*Testing analysis: 2026-06-24*
