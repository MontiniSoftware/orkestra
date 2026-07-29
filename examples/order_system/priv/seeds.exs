# Seeds: Place sample orders to demonstrate the full pipeline
#
# Run with: mix seed
# (or: mix run priv/seeds.exs)

alias Orkestra.{CommandEnvelope, MessageBus}
alias OrderSystem.Orders.Commands.PlaceOrder

IO.puts("\n--- Placing sample orders ---\n")

bus = MessageBus.impl()

orders = [
  %{order_id: "ORD-001", product_name: "Elixir in Action", quantity: 2, price: 45.99, customer_email: "alice@example.com"},
  %{order_id: "ORD-002", product_name: "Programming Phoenix", quantity: 1, price: 39.99, customer_email: "bob@example.com"},
  %{order_id: "ORD-003", product_name: "Metaprogramming Elixir", quantity: 3, price: 29.99, customer_email: "charlie@example.com"},
  %{order_id: "ORD-004", product_name: "Designing Elixir Systems", quantity: 1, price: 49.99, customer_email: "alice@example.com"},
  %{order_id: "ORD-005", product_name: "Real-Time Phoenix", quantity: 2, price: 35.99, customer_email: "diana@example.com"}
]

for order_params <- orders do
  {:ok, cmd} = PlaceOrder.new(order_params)
  envelope = CommandEnvelope.wrap(cmd)

  result = bus.dispatch(envelope)

  case result do
    {:error, reason} ->
      IO.puts("  FAILED: #{order_params.order_id} — #{inspect(reason)}")

    _ ->
      IO.puts("  Placed: #{order_params.order_id} — #{order_params.product_name} x#{order_params.quantity}")
  end

  # Small delay to let projectors process
  Process.sleep(100)
end

# Wait for projectors to catch up
Process.sleep(1000)

IO.puts("\n--- Done! Orders are now in both PostgreSQL and Elasticsearch ---")
IO.puts("""

Try these in IEx:

  # PostgreSQL read model
  OrderSystem.Repo.all(OrderSystem.Projections.OrderReadModel)

  # Elasticsearch read model via the generated repository (returns Order structs
  # and %Orkestra.ES.Page{} results with facets)
  OrderSystem.Search.Orders.get("ORD-001")
  OrderSystem.Search.Orders.get_paged(search: "elixir", facets: true)

  # Higher-level query helpers built on the repository
  OrderSystem.Orders.Queries.list(facets: true)
  OrderSystem.Orders.Queries.search_by_product("Elixir")
  OrderSystem.Orders.Queries.expensive_orders(40.0)
  OrderSystem.Orders.Queries.by_status("placed")
  OrderSystem.Orders.Queries.get("ORD-001")

  # Escape hatch: the ES Query DSL directly
  alias Orkestra.ES.Query
  OrderSystem.Orders.Queries.raw_search(fn q ->
    q
    |> Query.must(match: %{"product_name" => "elixir"})
    |> Query.filter(range: %{"total" => %{"gte" => 50}})
  end)
""")
