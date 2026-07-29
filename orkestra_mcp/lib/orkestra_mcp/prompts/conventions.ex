defmodule OrkestraMcp.Prompts.Conventions do
  @moduledoc "Orkestra CQRS/ES conventions and best practices"

  use Hermes.Server.Component, type: :prompt

  alias Hermes.Server.Response

  schema do
  end

  @impl true
  def get_messages(_params, _frame) do
    response =
      Response.prompt()
      |> Response.user_message(conventions_text())

    {:reply, response}
  end

  defp conventions_text do
    """
    # Orkestra CQRS/ES Conventions

    ## File Layout

    Organise your domain code by bounded context:

    ```
    lib/my_app/
      orders/
        commands/
          place_order.ex       # MyApp.Orders.Commands.PlaceOrder
        events/
          order_placed.ex      # MyApp.Orders.Events.OrderPlaced
        handlers/
          place_order_handler.ex    # MyApp.Orders.Handlers.PlaceOrderHandler
          send_confirmation.ex      # MyApp.Orders.Handlers.SendConfirmation
        order_aggregate.ex         # MyApp.Orders.OrderAggregate
    ```

    ## Commands

    - Use `use Orkestra.Command`
    - Define params with `param :name, :type, opts`
    - Supported types: `:string`, `:integer`, `:float`, `:boolean`, `:map`, `:list`
    - Options: `required: true`, `default: value`
    - Override `validate/1` for custom validation
    - Commands carry an auto-generated `:id`, `:type`, `:params`, and `:metadata`

    ## Events

    - Use `use Orkestra.Event`
    - Define fields with `field :name, :type, opts`
    - Same types and options as commands
    - Use `from_command/2` to create events from commands (preserves correlation_id, sets causation_id)
    - Use `from_event/2` to chain events (causation chaining)
    - Events carry `:id`, `:type`, `:data`, `:metadata`, and `:occurred_at`

    ## Command Handlers

    - Use `use Orkestra.CommandHandler, command: MyCommand`
    - Implement `execute(command, metadata) :: :ok | {:ok, result} | {:error, reason}`
    - Handlers auto-subscribe to the command's topic on the MessageBus
    - One handler per command (1:1 binding)

    ## Event Handlers

    - Use `use Orkestra.EventHandler, event: MyEvent` (single event)
    - Or `use Orkestra.EventHandler, events: [EventA, EventB]` (multiple events)
    - Or `use Orkestra.EventHandler, topic: "orders.events.*"` (wildcard)
    - Implement `handle_event(event, metadata) :: :ok | {:error, reason}`
    - Multiple handlers can subscribe to the same event (fan-out)

    ## Aggregates

    - Implement `@behaviour Orkestra.Aggregate`
    - Pure functions only: `init_state/0`, `stream_id/1`, `decide/2`, `evolve/2`
    - `decide(state, command)` returns `{:ok, [events]}` or `{:error, reason}`
    - `evolve(state, event)` returns the new state (pure fold)
    - Use `Orkestra.Aggregate.Root.execute/3` as the imperative shell
    - Optional `snapshot_every/0` for snapshotting

    ## Metadata Chain

    - Every command/event carries `Orkestra.Metadata`
    - `correlation_id` links the entire causal chain
    - `causation_id` identifies the direct cause
    - Always use `Event.from_command/2` or `Event.from_event/2` to preserve the chain
    - Metadata also carries `actor_id`, `actor_type`, `source`, `issued_at`

    ## Supervision Tree

    Add handlers to your application's supervision tree:

    ```elixir
    children = [
      MyApp.Orders.Handlers.PlaceOrderHandler,
      MyApp.Orders.Handlers.SendConfirmation,
      # ...
    ]
    ```

    ## MessageBus

    - Configure with `Orkestra.MessageBus.PubSub` (in-process) or `Orkestra.MessageBus.RabbitMQ` (distributed)
    - Topics are auto-derived from module names: `MyApp.Orders.Commands.PlaceOrder` -> `"orders.commands.place_order"`
    - Use `Orkestra.MessageBus.dispatch/1` for commands, `publish/1` for events

    ## EventStore

    - Configure with `Orkestra.EventStore.InMemory` (tests) or `Orkestra.EventStore.EventStoreDB` (production)
    - Streams are identified by string IDs (e.g., `"order-123"`)
    - Optimistic concurrency via expected revision
    """
  end
end
