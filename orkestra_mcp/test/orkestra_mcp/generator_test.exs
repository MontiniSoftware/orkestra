defmodule OrkestraMcp.GeneratorTest do
  use ExUnit.Case, async: true

  alias OrkestraMcp.Generator

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
end
