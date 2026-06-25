# Order System Example

A complete example showcasing all Orkestra features: CQRS commands/events, aggregate lifecycle, event handlers, and **dual projections** — the same events projected to both PostgreSQL and Elasticsearch simultaneously.

## What This Demonstrates

| Feature | File |
|---------|------|
| **Commands** with validation | `lib/order_system/orders/commands/place_order.ex` |
| **Events** with fields | `lib/order_system/orders/events/order_placed.ex` |
| **Aggregate** (pure decide/evolve) | `lib/order_system/orders/order_aggregate.ex` |
| **Command Handler** (auto-subscribe) | `lib/order_system/orders/handlers/place_order_handler.ex` |
| **Event Handler** (multi-event) | `lib/order_system/orders/handlers/order_notifier.ex` |
| **Postgres Projector** (Ecto.Multi) | `lib/order_system/orders/projectors/order_postgres_projector.ex` |
| **ES Projector** (`project_es/2`) | `lib/order_system/orders/projectors/order_es_projector.ex` |
| **ES Query DSL** (pipe-based) | `lib/order_system/orders/queries.ex` |
| **ES Index Mapping** (`dynamic: strict`) | Inside the ES projector's `index_mapping/0` |
| **Supervision tree** | `lib/order_system/application.ex` |
| **Docker Compose** (PG + ES) | `docker-compose.yml` |

## Quick Start

```bash
# Start PostgreSQL + Elasticsearch
docker compose up -d postgres elasticsearch

# Wait for services to be healthy
docker compose up -d --wait

# Run the full example (setup DB, seed data, open IEx)
docker compose run --rm app
```

Or run locally if you have PostgreSQL and Elasticsearch already running:

```bash
cd examples/order_system
mix setup          # deps.get + ecto.create + ecto.migrate
mix seed           # place 5 sample orders
iex -S mix         # interactive shell
```

## Try It

Once in IEx:

```elixir
# --- Place an order (full CQRS pipeline) ---
alias OrderSystem.Orders.Commands.PlaceOrder
alias Orkestra.{CommandEnvelope, Metadata}

{:ok, cmd} = PlaceOrder.new(%{
  order_id: "ORD-100",
  product_name: "Erlang in Anger",
  quantity: 1,
  price: 19.99,
  customer_email: "joe@example.com"
})

bus = Application.get_env(:order_system, :message_bus)
:ok = bus.dispatch(CommandEnvelope.wrap(cmd))

# Wait a moment for projectors to process
Process.sleep(500)

# --- Query PostgreSQL read model ---
OrderSystem.Repo.all(OrderSystem.Projections.OrderReadModel)

# --- Query Elasticsearch ---
OrderSystem.Orders.Queries.list()
OrderSystem.Orders.Queries.search_by_product("Erlang")
OrderSystem.Orders.Queries.expensive_orders(15.0)
OrderSystem.Orders.Queries.count_by_status()
OrderSystem.Orders.Queries.get("ORD-100")

# --- ES Query DSL directly ---
alias Orkestra.Projection.ES.Query

query = Query.new()
  |> Query.must(match: %{"product_name" => "elixir"})
  |> Query.filter(range: %{"total" => %{"gte" => 50}})
  |> Query.aggs("avg_total", avg: %{"field" => "total"})
  |> Query.size(10)
  |> Query.build()

Snap.Search.search(OrderSystem.ESCluster, "orders", query)

# --- Zero-downtime ES rebuild ---
# mix orkestra.projection.es.rebuild OrderSystem.Orders.Projectors.OrderESProjector
```

## Architecture

```
PlaceOrder (command)
    |
    v
PlaceOrderHandler (auto-subscribes, calls Aggregate.Root)
    |
    v
OrderAggregate.decide/2 (pure: validates state + produces events)
    |
    v
EventStore.InMemory (persists events)
    |
    +-- publishes --> OrderNotifier (logs, would send emails)
    |
    +-- projects --> OrderPostgresProjector (Ecto.Multi -> PostgreSQL)
    |                  checkpoint: atomic with read model write
    |
    +-- projects --> OrderESProjector (project_es/2 -> Elasticsearch)
                       live: Snap.Document.index (single doc)
                       catch-up: Snap.Bulk.perform (batch)
                       checkpoint: ES-first, Postgres-second
```

## Services

| Service | Port | Credentials |
|---------|------|-------------|
| PostgreSQL | 5432 | postgres / postgres |
| Elasticsearch | 9200 | elastic / changeme |

## Cleanup

```bash
docker compose down -v   # stops services and removes volumes
```
