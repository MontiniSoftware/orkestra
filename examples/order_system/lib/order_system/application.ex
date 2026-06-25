defmodule OrderSystem.Application do
  @moduledoc """
  OTP Application for the Order System example.

  Starts all services in order:
  1. PubSub (message bus)
  2. PostgreSQL Repo
  3. ES Cluster (Snap + Finch pool)
  4. InMemory EventStore
  5. Command/Event handlers
  6. Projection Supervisor (Postgres + ES projectors)
  """
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      # 1. Message bus
      {Phoenix.PubSub, name: OrderSystem.PubSub},

      # 2. PostgreSQL (checkpoints, dead letters, Postgres read model)
      OrderSystem.Repo,

      # 3. Elasticsearch cluster (Snap manages its own Finch pool)
      {OrderSystem.ESCluster, []},

      # 4. InMemory event store (replace with EventStoreDB in production)
      Orkestra.EventStore.InMemory,

      # 5. Handlers
      OrderSystem.Orders.Handlers.PlaceOrderHandler,
      OrderSystem.Orders.Handlers.OrderNotifier,

      # 6. Projectors (Postgres + ES)
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
