<!-- generated-by: gsd-doc-writer -->
# Getting Started with Orkestra

This guide walks you through installing Orkestra and building a complete end-to-end CQRS/ES flow from scratch — a command, a command handler, an aggregate, an event, and an event handler — all running in `iex` with no external services.

For a broader narrative walkthrough, see `guide.md` at the project root. For configuration reference, see `docs/CONFIGURATION.md`.

---

## Prerequisites

- **Elixir `~> 1.18`** — Orkestra requires Elixir 1.18 or later.
- **Mix** — included with Elixir.
- **No external services needed for local development** — the in-memory event store and PubSub message bus adapters are self-contained.

Verify your Elixir version:

```bash
elixir --version
```

---

## Installation

Add Orkestra to your `mix.exs` dependencies:

```elixir
def deps do
  [
    {:orkestra, "~> 0.1.0"}
  ]
end
```

Then fetch dependencies:

```bash
mix deps.get
```

---

## Step 1 — Configure the in-memory adapters

For local development and `iex` sessions, configure Orkestra to use the in-process PubSub bus and the in-memory event store. Add this to your application's `config/config.exs` (or `config/dev.exs`):

```elixir
config :orkestra, Orkestra.MessageBus,
  adapter: Orkestra.MessageBus.PubSub,
  app_prefix: MyApp

config :orkestra, Orkestra.MessageBus.PubSub,
  pubsub: MyApp.PubSub
```

The event store adapter defaults to `Orkestra.EventStore.InMemory` when no adapter key is set, so no additional event store config is required for local use.

---

## Step 2 — Define a command

A command expresses intent. Use `use Orkestra.Command` and the `param` DSL to declare typed parameters. Required params are validated on `new/2`.

```elixir
defmodule MyApp.Commands.OpenAccount do
  use Orkestra.Command

  param :account_id, :string, required: true
  param :owner,      :string, required: true
end
```

Build a command with `new/2`. It auto-generates an `id` and attaches `Orkestra.Metadata`:

```elixir
{:ok, cmd} = MyApp.Commands.OpenAccount.new(
  %{account_id: "acc_1", owner: "Alice"},
  actor_id: "user_42",
  source: "iex"
)

cmd.id          # auto-generated 20-char string
cmd.params      # %{account_id: "acc_1", owner: "Alice"}
cmd.metadata    # %Orkestra.Metadata{correlation_id: ..., actor_id: "user_42", ...}
```

Pass `actor_id:`, `actor_type:`, and `source:` as keyword options to `new/2` — they are stored in `cmd.metadata`.

---

## Step 3 — Define an event

An event is an immutable fact. Use `use Orkestra.Event` and the `field` DSL. Events carry a `data` map and propagate the correlation/causation chain from the command that caused them.

```elixir
defmodule MyApp.Events.AccountOpened do
  use Orkestra.Event

  field :account_id, :string, required: true
  field :owner,      :string, required: true
end
```

---

## Step 4 — Define an aggregate

An aggregate enforces domain rules as **pure functions** — no I/O, no GenServer. Implement the `Orkestra.Aggregate` behaviour:

- `init_state/0` — returns the starting state for a new aggregate instance.
- `stream_id/1` — derives the event stream identifier from the command.
- `evolve/2` — folds one event into the current state (pure).
- `decide/2` — given current state and a command, returns new events or an error (pure).

```elixir
defmodule MyApp.BankAccount do
  @behaviour Orkestra.Aggregate

  alias MyApp.Commands.OpenAccount
  alias MyApp.Events.AccountOpened

  @impl true
  def init_state, do: %{status: :new, owner: nil}

  @impl true
  def stream_id(command), do: "bank_account-#{command.params.account_id}"

  @impl true
  def evolve(state, %AccountOpened{} = e) do
    %{state | status: :open, owner: e.data.owner}
  end
  def evolve(state, _event), do: state

  @impl true
  def decide(%{status: :new}, %OpenAccount{} = cmd) do
    {:ok, [AccountOpened.new!(%{
      account_id: cmd.params.account_id,
      owner: cmd.params.owner
    })]}
  end
  def decide(%{status: :open}, _cmd), do: {:error, :account_already_open}
end
```

---

## Step 5 — Define a command handler

A `CommandHandler` is a GenServer that auto-subscribes to the command topic on startup. Implement `execute/2` with your business logic.

```elixir
defmodule MyApp.Handlers.OpenAccountHandler do
  use Orkestra.CommandHandler,
    command: MyApp.Commands.OpenAccount

  alias Orkestra.Aggregate.Root

  @impl true
  def execute(command, _metadata) do
    case Root.execute(MyApp.BankAccount, command) do
      {:ok, _events, _state} -> :ok
      {:error, reason}       -> {:error, reason}
    end
  end
end
```

`Root.execute/3` runs the full pipeline internally: load events from the store, fold via `evolve/2`, call `decide/2`, append new events, and publish them to the message bus.

---

## Step 6 — Define an event handler

An `EventHandler` is a GenServer that auto-subscribes to one or more event topics. Implement `handle_event/2` to react to events.

```elixir
defmodule MyApp.Handlers.OnAccountOpened do
  use Orkestra.EventHandler,
    event: MyApp.Events.AccountOpened

  require Logger

  @impl true
  def handle_event(event, _metadata) do
    Logger.info("Account opened: #{event.data.account_id} for #{event.data.owner}")
    :ok
  end
end
```

Return `:ok` to acknowledge. Return `{:error, reason}` to trigger retry and eventual dead-lettering.

---

## Step 7 — Wire up the supervision tree

Add `Phoenix.PubSub`, the Orkestra PubSub bus, and your handlers to your application's supervision tree:

```elixir
defmodule MyApp.Application do
  use Application

  def start(_type, _args) do
    children = [
      {Phoenix.PubSub, name: MyApp.PubSub},
      Orkestra.MessageBus.PubSub,
      MyApp.Handlers.OpenAccountHandler,
      MyApp.Handlers.OnAccountOpened
    ]

    opts = [strategy: :one_for_one, name: MyApp.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
```

The handlers register themselves with the bus during `init/1` — no manual subscription step is needed.

---

## Step 8 — Dispatch a command in iex

Start your application and dispatch:

```bash
iex -S mix
```

```elixir
alias Orkestra.{CommandEnvelope, MessageBus}
alias MyApp.Commands.OpenAccount

# Build the command
{:ok, cmd} = OpenAccount.new(
  %{account_id: "acc_1", owner: "Alice"},
  actor_id: "user_42",
  source: "iex"
)

# Wrap in an envelope and dispatch
bus = MessageBus.impl()
:ok = bus.dispatch(CommandEnvelope.wrap(cmd))
```

You should see Logger output from `OnAccountOpened` confirming the event was received:

```
[info] Account opened: acc_1 for Alice
```

---

## Common setup issues

**`** (ArgumentError) ** argument error` when calling `new/2` with string keys**

String keys are normalized to atoms via `String.to_existing_atom/1`. If you pass string keys for params that have not been declared as atoms yet (e.g., in a freshly started `iex` session before the module is loaded), this can fail. Use atom keys when calling `new/2` directly.

**`No command handler registered` error in Logger**

The `CommandHandler` GenServer subscribes to the bus asynchronously on `init`. If you dispatch before the handler has finished subscribing (e.g., immediately on application startup), you will see this error. Add a brief delay or use `Process.sleep/1` in test setup, or check handler startup logs before dispatching.

**`Phoenix.PubSub` not started**

If `Phoenix.PubSub` is not in the supervision tree before `Orkestra.MessageBus.PubSub`, the PubSub bus will fail to start. Ensure `{Phoenix.PubSub, name: MyApp.PubSub}` appears before `Orkestra.MessageBus.PubSub` in `children`.

**Missing `config :orkestra, Orkestra.MessageBus.PubSub, pubsub: MyApp.PubSub`**

The PubSub adapter defaults to `Orkestra.PubSub` as the PubSub process name if this config key is absent. If your application names its PubSub differently (e.g., `MyApp.PubSub`), this config entry is required.

---

## Next steps

- **`docs/ARCHITECTURE.md`** — How Orkestra's components fit together (command envelope lifecycle, aggregate root pipeline, message bus adapters).
- **`docs/CONFIGURATION.md`** — Full configuration reference: all config keys, event store adapters, RabbitMQ adapter setup.
- **`docs/ELASTICSEARCH.md`** — Build Elasticsearch/OpenSearch read models with declarative schemas, full-text search, facets, and zero-downtime migrations.
- **`guide.md`** — Hands-on tutorial with more advanced patterns including aggregates with snapshots, wildcard event subscriptions, and metadata correlation chains.
