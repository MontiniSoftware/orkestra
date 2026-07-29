defmodule OrderSystem.Orders.Projectors.OrderESProjector do
  @moduledoc """
  Projects order events into the `orders` Elasticsearch read model.

  Uses `Orkestra.Projector` with `backend: :elasticsearch` and a declared
  `schema:` (`OrderSystem.Search.Order`). The projector writes to the schema's
  alias and the index mapping is generated from the schema — there is no manual
  `index_mapping/0`.

  Each `project_es/2` handler returns `{:ok, %OrderSystem.Search.Order{}}`; the
  document and its deterministic `_id` (the `order_id` primary key) are derived
  from the struct via the schema's `to_doc/1`. Writes are idempotent full-doc
  upserts, batched via `Snap.Bulk.perform/4` in catch-up/rebuild mode.
  """
  use Orkestra.Projector,
    backend: :elasticsearch,
    repo: OrderSystem.Repo,
    cluster: OrderSystem.ESCluster,
    schema: OrderSystem.Search.Order,
    event_store: Orkestra.EventStore.InMemory

  alias OrderSystem.Orders.Events.{OrderPlaced, OrderCancelled}
  alias OrderSystem.Search.Order
  alias Orkestra.ES.Facet

  project_es(OrderPlaced, fn event, _position ->
    order = %Order{
      order_id: event.data.order_id,
      product_name: event.data.product_name,
      quantity: event.data.quantity,
      price: event.data.price,
      total: event.data.total,
      customer_email: event.data.customer_email,
      status: "placed",
      placed_at: DateTime.utc_now(),
      attributes: [
        %Facet.Attribute{
          code: "category",
          name: "Category",
          values: [%Facet.Value{code: "books", name: "Books"}]
        }
      ]
    }

    {:ok, order}
  end)

  project_es(OrderCancelled, fn event, _position ->
    order = %Order{
      order_id: event.data.order_id,
      status: "cancelled",
      cancel_reason: event.data.reason,
      cancelled_at: event.data.cancelled_at
    }

    {:ok, order}
  end)
end
