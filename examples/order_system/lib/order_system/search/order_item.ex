defmodule OrderSystem.Search.OrderItem do
  @moduledoc """
  Embedded Elasticsearch schema for a single order line item.

  Declared with `embedded: true`, so it has no index of its own: it lives
  inside `OrderSystem.Search.Order` under the `items` embed (`mode: :nested`,
  which preserves per-item correlation for combined filters such as
  `sku == "X" and quantity >= 2` on the same line).

  The `name` field is full-text searchable and reuses the root's
  `:product_search` analyzer — analyzer references in embedded schemas are
  resolved and validated by the root schema.
  """
  use Orkestra.ES.Schema, embedded: true

  schema do
    field(:sku, :keyword)
    field(:name, :text, analyzer: :product_search, searchable: true)
    field(:quantity, :integer)
  end
end
