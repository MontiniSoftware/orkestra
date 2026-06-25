defmodule OrderSystem.Orders.Projectors.OrderESProjector do
  @moduledoc """
  Projects order events into an Elasticsearch index.

  Uses `Orkestra.Projector` with `backend: :elasticsearch`.
  Each event handler returns `{:ok, document, id}` where:
  - `document` is the ES document map
  - `id` is the deterministic document ID for idempotent upserts

  The adapter writes full-document `index` operations (PUT _doc/{id})
  — creating or overwriting. In catch-up/rebuild mode, writes are
  batched via `Snap.Bulk.perform/4`.
  """
  use Orkestra.Projector,
    backend: :elasticsearch,
    repo: OrderSystem.Repo,
    cluster: OrderSystem.ESCluster,
    index: "orders",
    event_store: Orkestra.EventStore.InMemory

  alias OrderSystem.Orders.Events.{OrderPlaced, OrderCancelled}

  def index_mapping do
    %{
      "mappings" => %{
        "properties" => %{
          "order_id" => %{"type" => "keyword"},
          "product_name" => %{"type" => "text", "fields" => %{"keyword" => %{"type" => "keyword"}}},
          "quantity" => %{"type" => "integer"},
          "price" => %{"type" => "float"},
          "total" => %{"type" => "float"},
          "customer_email" => %{"type" => "keyword"},
          "status" => %{"type" => "keyword"},
          "cancel_reason" => %{"type" => "text"},
          "cancelled_at" => %{"type" => "date"},
          "placed_at" => %{"type" => "date"}
        }
      }
    }
  end

  @doc "Derives a deterministic document ID from the event for idempotent writes."
  def document_id(event) do
    event.data.order_id
  end

  project_es OrderPlaced, fn event, _position ->
    doc = %{
      "order_id" => event.data.order_id,
      "product_name" => event.data.product_name,
      "quantity" => event.data.quantity,
      "price" => event.data.price,
      "total" => event.data.total,
      "customer_email" => event.data.customer_email,
      "status" => "placed",
      "placed_at" => DateTime.utc_now() |> DateTime.to_iso8601()
    }

    {:ok, doc, event.data.order_id}
  end

  project_es OrderCancelled, fn event, _position ->
    doc = %{
      "order_id" => event.data.order_id,
      "status" => "cancelled",
      "cancel_reason" => event.data.reason,
      "cancelled_at" => event.data.cancelled_at
    }

    {:ok, doc, event.data.order_id}
  end
end
