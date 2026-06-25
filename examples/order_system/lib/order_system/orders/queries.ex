defmodule OrderSystem.Orders.Queries do
  @moduledoc """
  ES query helpers for the Orders projection.

  Uses `Orkestra.Projection.ES.Query` pipe-based DSL to compose
  Elasticsearch queries and execute them via Snap.
  """
  alias Orkestra.Projection.ES.Query

  @cluster OrderSystem.ESCluster
  @index "orders"

  @doc "Search orders by arbitrary query built with the ES Query DSL."
  def search(build_fn, opts \\ []) do
    query =
      Query.new()
      |> build_fn.()
      |> Query.size(Keyword.get(opts, :size, 20))
      |> Query.from(Keyword.get(opts, :from, 0))
      |> Query.build()

    Snap.Search.search(@cluster, @index, query)
  end

  @doc "List all orders with pagination."
  def list(opts \\ []) do
    query =
      Query.new()
      |> Query.size(Keyword.get(opts, :size, 20))
      |> Query.from(Keyword.get(opts, :from, 0))
      |> Query.sort(%{"placed_at" => %{"order" => "desc"}})
      |> Query.build()

    Snap.Search.search(@cluster, @index, query)
  end

  @doc "Search orders by product name (full-text)."
  def search_by_product(product_name, opts \\ []) do
    search(fn query ->
      Query.must(query, match: %{"product_name" => product_name})
    end, opts)
  end

  @doc "Find orders by status (placed, cancelled)."
  def by_status(status, opts \\ []) do
    search(fn query ->
      Query.filter(query, term: %{"status" => status})
    end, opts)
  end

  @doc "Find orders above a total threshold."
  def expensive_orders(min_total, opts \\ []) do
    search(fn query ->
      query
      |> Query.filter(range: %{"total" => %{"gte" => min_total}})
      |> Query.sort(%{"total" => %{"order" => "desc"}})
    end, opts)
  end

  @doc "Get order count by status (aggregation)."
  def count_by_status do
    query =
      Query.new()
      |> Query.size(0)
      |> Query.aggs("status_breakdown", terms: %{"field" => "status", "size" => 10})
      |> Query.build()

    Snap.Search.search(@cluster, @index, query)
  end

  @doc "Get a single order by ID."
  def get(order_id) do
    Snap.Document.get(@cluster, @index, order_id)
  end
end
