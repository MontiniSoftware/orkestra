defmodule MyApp.Orders.Projectors.OrderESProjector do
  use Orkestra.Projector,
    backend: :elasticsearch,
    repo: MyApp.OrderProjection.Repo,
    cluster: MyApp.ESCluster,
    index: "orders",
    event_store: Orkestra.EventStore.InMemory

  @impl true
  def index_mapping do
    %{
      "mappings" => %{
        "properties" => %{
          "order_id" => %{"type" => "keyword"},
          "status" => %{"type" => "keyword"}
        }
      }
    }
  end

  project_es(MyApp.Orders.Events.OrderPlaced, fn _event, _position ->
    {:ok, %{}, nil}
  end)
end
