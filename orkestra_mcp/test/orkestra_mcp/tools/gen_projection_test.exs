defmodule OrkestraMcp.Tools.GenProjectionTest do
  use ExUnit.Case, async: false

  alias OrkestraMcp.Tools.GenProjection

  setup do
    tmp_dir =
      Path.join(System.tmp_dir!(), "orkestra_mcp_proj_test_#{:rand.uniform(100_000)}")

    File.mkdir_p!(tmp_dir)
    Application.put_env(:orkestra_mcp, :project_dir, tmp_dir)

    on_exit(fn ->
      File.rm_rf!(tmp_dir)
      Application.delete_env(:orkestra_mcp, :project_dir)
    end)

    %{tmp_dir: tmp_dir}
  end

  test "creates projector file and migration file", %{tmp_dir: tmp_dir} do
    {:ok, result} =
      GenProjection.execute(
        %{
          module_name: "MyApp.Orders.OrderProjector",
          repo_module: "MyApp.OrderProjection.Repo",
          events: Jason.encode!(["MyApp.Events.OrderPlaced"])
        },
        nil
      )

    assert result =~ "Created"
    assert result =~ "use Orkestra.Projector"

    projector_file = Path.join(tmp_dir, "lib/my_app/orders/order_projector.ex")
    assert File.exists?(projector_file)

    migration_files =
      Path.wildcard(Path.join(tmp_dir, "priv/projections/**/migrations/*.exs"))

    assert migration_files != [], "Expected a migration file under priv/projections/"
  end
end
