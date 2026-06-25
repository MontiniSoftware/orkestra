defmodule OrkestraMcp.GeneratorTest do
  use ExUnit.Case, async: true

  alias OrkestraMcp.{Generator, Naming}

  describe "gen_command/2" do
    test "generates valid Elixir command module" do
      params = [
        %{"name" => "product_id", "type" => "string", "required" => true},
        %{"name" => "quantity", "type" => "integer", "default" => 1}
      ]

      {source, file_path} = Generator.gen_command("MyApp.Orders.Commands.PlaceOrder", params)

      assert file_path == "lib/my_app/orders/commands/place_order.ex"
      assert source =~ "defmodule MyApp.Orders.Commands.PlaceOrder"
      assert source =~ "use Orkestra.Command"
      assert source =~ "param :product_id, :string, required: true"
      assert source =~ "param :quantity, :integer, default: 1"
      assert {:ok, _} = Code.string_to_quoted(source)
    end
  end

  describe "gen_event/2" do
    test "generates valid Elixir event module" do
      fields = [
        %{"name" => "order_id", "type" => "string", "required" => true},
        %{"name" => "total", "type" => "float"}
      ]

      {source, file_path} = Generator.gen_event("MyApp.Orders.Events.OrderPlaced", fields)

      assert file_path == "lib/my_app/orders/events/order_placed.ex"
      assert source =~ "defmodule MyApp.Orders.Events.OrderPlaced"
      assert source =~ "use Orkestra.Event"
      assert source =~ "field :order_id, :string, required: true"
      assert source =~ "field :total, :float"
      assert {:ok, _} = Code.string_to_quoted(source)
    end
  end

  describe "gen_command_handler/2" do
    test "generates valid Elixir command handler module" do
      {source, file_path} =
        Generator.gen_command_handler(
          "MyApp.Orders.Handlers.PlaceOrderHandler",
          "MyApp.Orders.Commands.PlaceOrder"
        )

      assert file_path == "lib/my_app/orders/handlers/place_order_handler.ex"
      assert source =~ "use Orkestra.CommandHandler, command: MyApp.Orders.Commands.PlaceOrder"
      assert source =~ "def execute(command, _metadata)"
      assert {:ok, _} = Code.string_to_quoted(source)
    end
  end

  describe "gen_event_handler/2" do
    test "generates single-event handler" do
      opts = %{"mode" => "single", "event" => "MyApp.Orders.Events.OrderPlaced"}
      {source, _} = Generator.gen_event_handler("MyApp.Handlers.Notify", opts)

      assert source =~ "use Orkestra.EventHandler, event: MyApp.Orders.Events.OrderPlaced"
      assert {:ok, _} = Code.string_to_quoted(source)
    end

    test "generates multi-event handler" do
      opts = %{"mode" => "multi", "events" => ["EventA", "EventB"]}
      {source, _} = Generator.gen_event_handler("MyApp.Handlers.Multi", opts)

      assert source =~ "use Orkestra.EventHandler, events: [EventA, EventB]"
      assert {:ok, _} = Code.string_to_quoted(source)
    end

    test "generates topic-based handler" do
      opts = %{"mode" => "topic", "topic" => "orders.events.*"}
      {source, _} = Generator.gen_event_handler("MyApp.Handlers.Audit", opts)

      assert source =~ ~s(use Orkestra.EventHandler, topic: "orders.events.*")
      assert {:ok, _} = Code.string_to_quoted(source)
    end
  end

  describe "gen_aggregate/4" do
    test "generates valid aggregate with decide/evolve clauses" do
      commands = ["MyApp.Orders.Commands.PlaceOrder"]
      events = ["MyApp.Orders.Events.OrderPlaced"]

      {source, file_path} =
        Generator.gen_aggregate(
          "MyApp.Orders.OrderAggregate",
          "order_id",
          commands,
          events
        )

      assert file_path == "lib/my_app/orders/order_aggregate.ex"
      assert source =~ "@behaviour Orkestra.Aggregate"
      assert source =~ "def stream_id(command)"
      assert source =~ "command.params.order_id"
      assert source =~ "def decide(state, %MyApp.Orders.Commands.PlaceOrder{} = command)"
      assert source =~ "def evolve(state, %MyApp.Orders.Events.OrderPlaced{} = event)"
      assert {:ok, _} = Code.string_to_quoted(source)
    end

    test "generates aggregate with empty commands/events" do
      {source, _} = Generator.gen_aggregate("MyApp.Agg", "id", [], [])

      assert source =~ "def decide(_state, command)"
      assert source =~ "def evolve(state, event)"
      assert {:ok, _} = Code.string_to_quoted(source)
    end
  end

  describe "write!/3" do
    test "writes file and creates directories" do
      tmp_dir = Path.join(System.tmp_dir!(), "orkestra_mcp_test_#{:rand.uniform(100_000)}")

      try do
        path = Generator.write!("defmodule Test do\nend", tmp_dir, "lib/test.ex")
        assert File.exists?(path)
        assert File.read!(path) =~ "defmodule Test"
      after
        File.rm_rf!(tmp_dir)
      end
    end
  end

  describe "gen_projection/3" do
    test "generates valid projector module with event clauses" do
      {source, file_path} =
        Generator.gen_projection(
          "MyApp.Orders.OrderProjector",
          "MyApp.OrderProjection.Repo",
          ["MyApp.Events.OrderPlaced", "MyApp.Events.OrderCancelled"]
        )

      assert file_path == "lib/my_app/orders/order_projector.ex"
      assert source =~ "use Orkestra.Projector"
      assert source =~ "repo: MyApp.OrderProjection.Repo"
      assert source =~ "project MyApp.Events.OrderPlaced"
      assert source =~ "project MyApp.Events.OrderCancelled"
      assert {:ok, _} = Code.string_to_quoted(source)
    end

    test "generates projector with empty events list" do
      {source, _file_path} =
        Generator.gen_projection(
          "MyApp.Orders.OrderProjector",
          "MyApp.OrderProjection.Repo",
          []
        )

      assert source =~ "TODO"
      assert {:ok, _} = Code.string_to_quoted(source)
    end
  end

  describe "gen_projection_migration/2" do
    test "generates valid migration with correct path" do
      {source, file_path} =
        Generator.gen_projection_migration("MyApp.Orders.OrderProjector", "20260624120000")

      assert String.starts_with?(file_path, "priv/projections/")
      assert String.ends_with?(file_path, ".exs")
      assert file_path =~ "my_app_orders_order_projector"
      assert source =~ "use Ecto.Migration"
      assert source =~ "def up"
      assert source =~ "def down"
      assert {:ok, _} = Code.string_to_quoted(source)
    end
  end

  describe "gen_read_model/2" do
    test "generates valid Ecto schema module" do
      fields = [
        %{"name" => "order_id", "type" => "binary_id"},
        %{"name" => "status", "type" => "string"}
      ]

      {source, file_path} = Generator.gen_read_model("MyApp.Orders.OrderReadModel", fields)

      assert file_path == "lib/my_app/orders/order_read_model.ex"
      assert source =~ "use Ecto.Schema"
      assert source =~ ~s(schema "order_read_models")
      assert source =~ "field :order_id, :binary_id"
      assert source =~ "field :status, :string"
      assert source =~ "timestamps()"
      assert {:ok, _} = Code.string_to_quoted(source)
    end
  end

  describe "gen_read_model_migration/2" do
    test "generates valid read model migration" do
      {source, file_path} =
        Generator.gen_read_model_migration("MyApp.Orders.OrderReadModel", "20260624120000")

      assert String.starts_with?(file_path, "priv/projections/")
      assert file_path =~ "order_read_models"
      assert source =~ "use Ecto.Migration"
      assert source =~ "create table"
      assert source =~ ":binary_id"
      assert {:ok, _} = Code.string_to_quoted(source)
    end
  end

  describe "gen_queries/2" do
    test "generates valid Queries module with list and get_by" do
      {source, file_path} =
        Generator.gen_queries("MyApp.Orders.Queries", "MyApp.Orders.OrderReadModel")

      assert file_path == "lib/my_app/orders/queries.ex"
      assert source =~ "import Ecto.Query"
      assert source =~ "def list(repo"
      assert source =~ "def get_by(repo"
      assert source =~ "page_size"
      assert source =~ "offset"
      assert {:ok, _} = Code.string_to_quoted(source)
    end
  end

  describe "gen_es_queries/2" do
    test "generates valid ES Queries module with search, list, and get_by_id" do
      {source, file_path} =
        Generator.gen_es_queries("MyApp.Orders.ESQueries", "MyApp.Orders.OrderESProjector")

      assert file_path == Naming.module_to_file_path("MyApp.Orders.ESQueries")
      assert file_path == "lib/my_app/orders/es_queries.ex"
      assert source =~ "alias Orkestra.Projection.ES.Query"
      assert source =~ "def search(cluster"
      assert source =~ "def list(cluster"
      assert source =~ "def get_by_id(cluster"
      assert source =~ "Snap.Search.search"
      assert source =~ "Snap.Document.get"
      assert {:ok, _} = Code.string_to_quoted(source)
    end

    test "references the projector module in moduledoc" do
      {source, _file_path} =
        Generator.gen_es_queries("MyApp.Orders.ESQueries", "MyApp.Orders.OrderESProjector")

      assert source =~ "MyApp.Orders.OrderESProjector"
    end
  end

  describe "gen_es_projection/5" do
    test "generates valid ES projector source with required attributes" do
      events = ["MyApp.Events.OrderPlaced", "MyApp.Events.OrderCancelled"]

      {source, _file_path} =
        Generator.gen_es_projection(
          "MyApp.Orders.OrderESProjector",
          "MyApp.OrderProjection.Repo",
          "MyApp.ESCluster",
          "orders",
          events
        )

      assert source =~ "use Orkestra.Projector"
      assert source =~ "backend: :elasticsearch"
      assert source =~ "repo: MyApp.OrderProjection.Repo"
      assert source =~ "cluster: MyApp.ESCluster"
      assert source =~ ~s(index: "orders")
      assert source =~ "project_es MyApp.Events.OrderPlaced"
      assert source =~ "@impl true"
      assert source =~ "def index_mapping"
      assert {:ok, _} = Code.string_to_quoted(source)
    end

    test "generates placeholder clause with TODO when events list is empty" do
      {source, _file_path} =
        Generator.gen_es_projection(
          "MyApp.Orders.OrderESProjector",
          "MyApp.OrderProjection.Repo",
          "MyApp.ESCluster",
          "orders",
          []
        )

      assert source =~ "TODO"
      assert source =~ "project_es"
      assert {:ok, _} = Code.string_to_quoted(source)
    end

    test "returns correct file_path via Naming.module_to_file_path" do
      {_source, file_path} =
        Generator.gen_es_projection(
          "MyApp.Orders.OrderESProjector",
          "MyApp.OrderProjection.Repo",
          "MyApp.ESCluster",
          "orders",
          []
        )

      assert file_path == Naming.module_to_file_path("MyApp.Orders.OrderESProjector")
      assert file_path == "lib/my_app/orders/order_es_projector.ex"
    end

    test "generates one project_es clause per event when multiple events given" do
      events = ["MyApp.Events.OrderPlaced", "MyApp.Events.OrderCancelled", "MyApp.Events.OrderShipped"]

      {source, _file_path} =
        Generator.gen_es_projection(
          "MyApp.Orders.OrderESProjector",
          "MyApp.OrderProjection.Repo",
          "MyApp.ESCluster",
          "orders",
          events
        )

      assert source =~ "project_es MyApp.Events.OrderPlaced"
      assert source =~ "project_es MyApp.Events.OrderCancelled"
      assert source =~ "project_es MyApp.Events.OrderShipped"
      assert {:ok, _} = Code.string_to_quoted(source)
    end
  end

  describe "module_to_table_name/1" do
    test "converts a multi-segment module to a pluralised table name" do
      assert Naming.module_to_table_name("MyApp.Orders.OrderReadModel") == "order_read_models"
    end

    test "converts a single-segment module to a pluralised table name" do
      assert Naming.module_to_table_name("UserProfile") == "user_profiles"
    end
  end
end
