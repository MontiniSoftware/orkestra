defmodule OrkestraMcp.Tools.GenAggregateTest do
  use ExUnit.Case, async: false

  alias OrkestraMcp.Tools.GenAggregate

  setup do
    tmp_dir = Path.join(System.tmp_dir!(), "orkestra_mcp_agg_test_#{:rand.uniform(100_000)}")
    File.mkdir_p!(tmp_dir)
    Application.put_env(:orkestra_mcp, :project_dir, tmp_dir)

    on_exit(fn ->
      File.rm_rf!(tmp_dir)
      Application.delete_env(:orkestra_mcp, :project_dir)
    end)

    %{tmp_dir: tmp_dir}
  end

  test "creates aggregate file", %{tmp_dir: tmp_dir} do
    commands_json = Jason.encode!(["MyApp.Commands.PlaceOrder"])
    events_json = Jason.encode!(["MyApp.Events.OrderPlaced"])

    {:ok, result} =
      GenAggregate.execute(
        %{
          module_name: "MyApp.OrderAggregate",
          stream_id_field: "order_id",
          commands: commands_json,
          events: events_json
        },
        nil
      )

    assert result =~ "Created"
    assert result =~ "@behaviour Orkestra.Aggregate"
    assert result =~ "command.params.order_id"

    file = Path.join(tmp_dir, "lib/my_app/order_aggregate.ex")
    assert File.exists?(file)
  end
end
