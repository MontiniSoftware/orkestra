defmodule OrderSystem.Application do
  @moduledoc """
  OTP Application for the Order System example.

  Starts all services in order:
  1. Phoenix.PubSub (underlying pubsub transport)
  2. Orkestra.MessageBus.PubSub (command/event bus GenServer)
  3. PostgreSQL Repo
  4. ES Cluster (Snap + Finch pool)
  5. InMemory EventStore
  6. Command/Event handlers
  7. Projection Supervisor (Postgres + ES projectors)
  """
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      # 1. Phoenix.PubSub transport (used by Orkestra.MessageBus.PubSub)
      {Phoenix.PubSub, name: OrderSystem.PubSub},

      # 2. Orkestra's message bus GenServer (registers handlers, routes messages)
      Orkestra.MessageBus.PubSub,

      # 3. PostgreSQL (checkpoints, dead letters, Postgres read model)
      OrderSystem.Repo,

      # 4. Elasticsearch cluster (Snap manages its own Finch pool)
      {OrderSystem.ESCluster, []},

      # 5. InMemory event store (replace with EventStoreDB in production)
      Orkestra.EventStore.InMemory,

      # 6. Handlers
      OrderSystem.Orders.Handlers.PlaceOrderHandler,
      OrderSystem.Orders.Handlers.OrderNotifier,

      # 7. Projectors (Postgres + ES)
      {Orkestra.Projection.Supervisor,
       projectors: [
         OrderSystem.Orders.Projectors.OrderPostgresProjector,
         OrderSystem.Orders.Projectors.OrderESProjector
       ]}
    ]

    opts = [strategy: :one_for_one, name: OrderSystem.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
