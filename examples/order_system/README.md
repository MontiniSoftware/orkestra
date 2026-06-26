# Order System Example

A complete example showcasing all Orkestra features: CQRS commands/events, aggregate lifecycle, event handlers, **dual projections** (PostgreSQL + Elasticsearch), **ES Query DSL**, and **MCP code generation**.

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
| **MCP config** (Claude Code integration) | `.mcp.json` |
| **MCP demo** (scaffold via CLI) | `priv/mcp_demo.sh` |
| **Docker Compose** (PG + ES + MCP) | `docker-compose.yml` |

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

## MCP Integration

The Orkestra MCP server provides AI-assisted code generation for CQRS/ES modules. Three ways to use it:

### 1. With Claude Code (recommended)

Open the example project in Claude Code — the `.mcp.json` auto-configures the server:

```bash
cd examples/order_system
claude                # MCP tools available automatically
```

Then ask Claude to scaffold new modules:

```
> Add a Shipping bounded context with a ShipOrder command,
> OrderShipped event, and an ES projector for shipment tracking
```

Claude will use the MCP tools (`gen_command`, `gen_event`, `gen_es_projection`, etc.) to generate all the files.

**Available MCP tools:**

| Tool | What it generates |
|------|-------------------|
| `gen_command` | Command module with typed params |
| `gen_event` | Event module with typed fields |
| `gen_aggregate` | Aggregate with decide/evolve stubs |
| `gen_command_handler` | CommandHandler bound to a command |
| `gen_event_handler` | EventHandler (single, multi, or wildcard) |
| `gen_projection` | Postgres projector with `project/2` |
| `gen_es_projection` | ES projector with `project_es/2` + `index_mapping/0` |
| `gen_read_model` | Ecto schema for read model |
| `gen_queries` | Postgres queries module |
| `gen_es_queries` | ES queries module with DSL |

**Available MCP resources (introspection):**

| Resource | What it shows |
|----------|---------------|
| `orkestra://domain-map` | Cross-reference of all commands, events, handlers, aggregates, projectors |
| `orkestra://projections` | All projections with backend type, cluster, index |
| `orkestra://commands` | All command modules with params |
| `orkestra://events` | All event modules with fields |
| `orkestra://handlers` | All command and event handlers |
| `orkestra://aggregates` | All aggregate modules |

### 2. Demo Script (Docker)

Scaffold a complete Inventory bounded context via the MCP CLI:

```bash
docker compose exec app sh priv/mcp_demo.sh
```

This generates 7 files in one go:
- `AddStock` command + `StockAdded` event
- `StockAggregate` with decide/evolve
- `AddStockHandler` (command) + `StockNotifier` (event)
- `StockESProjector` with index mapping
- `Inventory.ES.Queries` module

### 3. Direct CLI (local)

Build the escript and call tools directly:

```bash
cd orkestra_mcp
mix escript.build

# Generate an ES projector
echo '{"jsonrpc":"2.0","id":0,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"cli","version":"0.1"}}}
{"jsonrpc":"2.0","method":"notifications/initialized"}
{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"gen_es_projection","arguments":{"module_name":"OrderSystem.Shipping.ShipmentProjector","repo_module":"OrderSystem.Repo","cluster_module":"OrderSystem.ESCluster","index":"shipments","events":"[\"OrderSystem.Shipping.Events.OrderShipped\"]"}}}' \
  | ./orkestra_mcp --project-dir ../examples/order_system
```

## Try It

Once in IEx:

```elixir
# --- Place an order (full CQRS pipeline) ---
alias OrderSystem.Orders.Commands.PlaceOrder
alias Orkestra.CommandEnvelope

{:ok, cmd} = PlaceOrder.new(%{
  order_id: "ORD-100",
  product_name: "Erlang in Anger",
  quantity: 1,
  price: 19.99,
  customer_email: "joe@example.com"
})

bus = Orkestra.MessageBus.impl()
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

                            ┌──────────────────────────┐
                            │  orkestra-mcp (MCP server)│
                            │  gen_command, gen_event,  │
                            │  gen_es_projection, ...   │
                            │  domain_map introspection │
                            └──────────────────────────┘
                            Scaffolds all of the above ^
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
