defmodule OrderSystem.Search.Order do
  @moduledoc """
  Elasticsearch read-model schema for orders.

  Declares the fields, analyzers and a facets slot for the `orders` index using
  the `Orkestra.ES.Schema` DSL. The `OrderSystem.Orders.Projectors.OrderESProjector`
  projects order events into this schema, and `OrderSystem.Search.Orders`
  generates the query repository over it.

  This is a mono-culture schema (no `cultures:`), so it maps to a single
  unsuffixed `orders` alias.
  """
  use Orkestra.ES.Schema, index: "orders"

  settings number_of_shards: 1, number_of_replicas: 0 do
    # Full-text analyzer for product names: lowercase + accent folding so that
    # "Elixir" matches "elixir" and "café" matches "cafe".
    analyzer(:product_search, tokenizer: "standard", filter: ["lowercase", "asciifolding"])
  end

  schema do
    field(:order_id, :keyword, primary_key: true)
    field(:product_name, :text, analyzer: :product_search, searchable: true, keyword: true)
    field(:quantity, :integer)
    field(:price, :float)
    field(:total, :float, sortable: true)
    field(:customer_email, :keyword)
    field(:status, :keyword)
    field(:cancel_reason, :text)
    field(:cancelled_at, :date)
    field(:placed_at, :date, sortable: true)
    # Dynamic facets (attribute {code, name} + values {code, name}) — e.g. the
    # product category — aggregatable via `get_paged(facets: true)`.
    facets(:attributes)
  end
end
