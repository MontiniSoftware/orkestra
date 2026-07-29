defmodule OrkestraMcp.IntrospectionTest do
  use ExUnit.Case, async: true

  alias OrkestraMcp.Introspection

  @fixture_dir Path.join([__DIR__, "..", "fixtures", "sample_project"]) |> Path.expand()

  describe "discover/1" do
    test "discovers commands with params" do
      %{commands: commands} = Introspection.discover(@fixture_dir)

      place_order = Enum.find(commands, &(&1.module == "MyApp.Orders.Commands.PlaceOrder"))
      assert place_order
      assert length(place_order.params) == 2

      product_id = Enum.find(place_order.params, &(&1.name == "product_id"))
      assert product_id.type == "string"

      track_stock = Enum.find(commands, &(&1.module == "MyApp.Inventory.Commands.TrackStock"))
      assert track_stock
      assert length(track_stock.params) == 2
    end

    test "discovers events with fields" do
      %{events: events} = Introspection.discover(@fixture_dir)

      order_placed = Enum.find(events, &(&1.module == "MyApp.Orders.Events.OrderPlaced"))
      assert order_placed
      assert length(order_placed.fields) == 3

      order_id = Enum.find(order_placed.fields, &(&1.name == "order_id"))
      assert order_id.type == "string"
    end

    test "discovers command handlers" do
      %{command_handlers: handlers} = Introspection.discover(@fixture_dir)

      handler =
        Enum.find(handlers, &(&1.module == "MyApp.Orders.Handlers.PlaceOrderHandler"))

      assert handler
      assert handler.command == "MyApp.Orders.Commands.PlaceOrder"
    end

    test "discovers event handlers with single event" do
      %{event_handlers: handlers} = Introspection.discover(@fixture_dir)

      handler =
        Enum.find(handlers, &(&1.module == "MyApp.Orders.Handlers.SendConfirmation"))

      assert handler
      assert handler.event == "MyApp.Orders.Events.OrderPlaced"
    end

    test "discovers event handlers with multiple events" do
      %{event_handlers: handlers} = Introspection.discover(@fixture_dir)

      handler =
        Enum.find(handlers, &(&1.module == "MyApp.Orders.Handlers.UpdateIndex"))

      assert handler
      assert "MyApp.Orders.Events.OrderPlaced" in handler.events
    end

    test "discovers event handlers with topic" do
      %{event_handlers: handlers} = Introspection.discover(@fixture_dir)

      handler =
        Enum.find(handlers, &(&1.module == "MyApp.Orders.Handlers.AuditLogger"))

      assert handler
      assert handler.topic == "orders.events.*"
    end

    test "discovers aggregates" do
      %{aggregates: aggregates} = Introspection.discover(@fixture_dir)

      aggregate = Enum.find(aggregates, &(&1.module == "MyApp.Orders.OrderAggregate"))
      assert aggregate
    end

    test "discovers projectors" do
      %{projectors: projectors} = Introspection.discover(@fixture_dir)

      projector = Enum.find(projectors, &(&1.module == "MyApp.Orders.Projectors.OrderProjector"))
      assert projector
      assert projector.repo == "MyApp.OrderProjection.Repo"
      assert projector.backend == :postgres
      assert projector.cluster == nil
      assert projector.index == nil
      assert "MyApp.Orders.Events.OrderPlaced" in projector.events
      assert "MyApp.Orders.Events.OrderCancelled" in projector.events
    end

    test "discovers ES projectors" do
      %{projectors: projectors} = Introspection.discover(@fixture_dir)

      es_proj =
        Enum.find(projectors, &(&1.module == "MyApp.Orders.Projectors.OrderESProjector"))

      assert es_proj
      assert es_proj.backend == :elasticsearch
      assert es_proj.repo == "MyApp.OrderProjection.Repo"
      assert es_proj.cluster == "MyApp.ESCluster"
      assert es_proj.index == "orders"
      assert "MyApp.Orders.Events.OrderPlaced" in es_proj.events
    end

    test "returns empty lists for project with no Orkestra modules" do
      result = Introspection.discover("/tmp/empty_project_#{:rand.uniform(100_000)}")

      assert result.commands == []
      assert result.events == []
      assert result.command_handlers == []
      assert result.event_handlers == []
      assert result.aggregates == []
      assert result.projectors == []
    end
  end

  describe "build_domain_map/1" do
    test "produces a readable domain map" do
      map = Introspection.build_domain_map(@fixture_dir)

      assert map =~ "MyApp.Orders.Commands.PlaceOrder (command)"
      assert map =~ "-> MyApp.Orders.Handlers.PlaceOrderHandler (command_handler)"
      assert map =~ "MyApp.Orders.Events.OrderPlaced (event)"
      assert map =~ "-> MyApp.Orders.Handlers.SendConfirmation (event_handler)"
      assert map =~ "MyApp.Orders.OrderAggregate (aggregate)"
    end

    test "includes projectors in domain map" do
      map = Introspection.build_domain_map(@fixture_dir)

      assert map =~ "MyApp.Orders.Projectors.OrderProjector (projector, backend: postgres)"
      assert map =~ "MyApp.Orders.Events.OrderPlaced (projected_event)"
    end

    test "includes ES projectors in domain map" do
      map = Introspection.build_domain_map(@fixture_dir)

      assert map =~
               "MyApp.Orders.Projectors.OrderESProjector (projector, backend: elasticsearch, index: orders)"

      assert map =~ "MyApp.Orders.Events.OrderPlaced (projected_event)"
    end
  end
end
