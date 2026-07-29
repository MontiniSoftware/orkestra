defmodule OrderSystem.Orders.Queries do
  @moduledoc """
  Query helpers for the Orders Elasticsearch read model.

  These delegate to the generated `OrderSystem.Search.Orders` repository
  (`get/2`, `get_paged/1`, …), which returns decoded `OrderSystem.Search.Order`
  structs and `Orkestra.ES.Page` results. `raw_search/2` is kept as an escape
  hatch showing the lower-level `Orkestra.ES.Query` DSL.
  """
  alias OrderSystem.Search.Orders
  alias Orkestra.ES.Query

  @cluster OrderSystem.ESCluster
  @index "orders"

  @doc """
  Lists orders, newest first, with offset pagination and optional facets.

  Returns `{:ok, %Orkestra.ES.Page{}}` whose `entries` are `Order` structs.
  """
  def list(opts \\ []) do
    Orders.get_paged(
      sort: [placed_at: :desc],
      facets: Keyword.get(opts, :facets, false),
      page: Keyword.get(opts, :page, 1),
      page_size: Keyword.get(opts, :page_size, 20)
    )
  end

  @doc "Full-text search on the product name, with facets enabled."
  def search_by_product(product_name, opts \\ []) do
    Orders.get_paged(
      search: product_name,
      facets: true,
      page: Keyword.get(opts, :page, 1),
      page_size: Keyword.get(opts, :page_size, 20)
    )
  end

  @doc "Filters orders by status (`\"placed\"`, `\"cancelled\"`)."
  def by_status(status, opts \\ []) do
    Orders.get_paged(
      filters: [status: status],
      page: Keyword.get(opts, :page, 1),
      page_size: Keyword.get(opts, :page_size, 20)
    )
  end

  @doc """
  Finds orders containing an item that matches **both** conditions at once:
  the given SKU and at least `min_quantity` units — on the same line item.

  Demonstrates the correlated nested-embed filter form: because
  `OrderSystem.Search.Order` declares `embeds_many :items, ..., mode: :nested`,
  the sub-filters below compile to a single `nested` query and must hold on
  the **same** item entry (with `mode: :object` they would be evaluated
  independently across items, allowing cross-item false positives).
  """
  def with_item(sku, min_quantity \\ 1, opts \\ []) do
    Orders.get_paged(
      filters: [items: [sku: sku, quantity: {:gte, min_quantity}]],
      page: Keyword.get(opts, :page, 1),
      page_size: Keyword.get(opts, :page_size, 20)
    )
  end

  @doc "Finds orders above a total threshold, most expensive first."
  def expensive_orders(min_total, opts \\ []) do
    Orders.get_paged(
      filters: [total: {:gte, min_total}],
      sort: [total: :desc],
      page: Keyword.get(opts, :page, 1),
      page_size: Keyword.get(opts, :page_size, 20)
    )
  end

  @doc "Fetches a single order by id — `{:ok, %Order{}}` | `{:error, :not_found}`."
  def get(order_id), do: Orders.get(order_id)

  @doc "Total number of indexed orders."
  def count, do: Orders.count()

  @doc """
  Escape hatch: run a raw query built with the `Orkestra.ES.Query` DSL.

  Demonstrates dropping down to the low-level query builder when the repository
  helpers are not expressive enough (here: a terms aggregation on `status`).
  """
  def raw_search(build_fn, opts \\ []) do
    query =
      Query.new()
      |> build_fn.()
      |> Query.size(Keyword.get(opts, :size, 20))
      |> Query.from(Keyword.get(opts, :from, 0))
      |> Query.build()

    Snap.Search.search(@cluster, @index, query)
  end

  @doc "Order count grouped by status (raw aggregation via the Query DSL)."
  def count_by_status do
    query =
      Query.new()
      |> Query.size(0)
      |> Query.aggs("status_breakdown", terms: %{"field" => "status", "size" => 10})
      |> Query.build()

    Snap.Search.search(@cluster, @index, query)
  end
end
