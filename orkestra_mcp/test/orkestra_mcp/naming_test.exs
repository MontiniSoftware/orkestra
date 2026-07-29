defmodule OrkestraMcp.NamingTest do
  use ExUnit.Case, async: true

  alias OrkestraMcp.Naming

  describe "module_to_file_path/1" do
    test "converts a simple module name" do
      assert Naming.module_to_file_path("MyApp.Orders.Commands.PlaceOrder") ==
               "lib/my_app/orders/commands/place_order.ex"
    end

    test "converts a single-segment module name" do
      assert Naming.module_to_file_path("MyApp") == "lib/my_app.ex"
    end

    test "handles acronyms via Macro.underscore" do
      assert Naming.module_to_file_path("MyApp.HTTPClient") ==
               "lib/my_app/http_client.ex"
    end
  end

  describe "infer_app_module/1" do
    test "extracts module name from mix.exs" do
      fixture_dir = Path.join([__DIR__, "..", "fixtures", "sample_project"]) |> Path.expand()
      assert {:ok, "MyApp"} = Naming.infer_app_module(fixture_dir)
    end

    test "returns error for missing mix.exs" do
      assert {:error, :enoent} = Naming.infer_app_module("/nonexistent/path")
    end
  end
end
