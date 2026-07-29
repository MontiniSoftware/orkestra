defmodule OrkestraMcp.Tools.GenEsProjectionTest do
  use ExUnit.Case, async: false

  alias OrkestraMcp.Tools.GenEsProjection

  setup do
    tmp_dir =
      Path.join(System.tmp_dir!(), "orkestra_mcp_es_proj_test_#{:rand.uniform(100_000)}")

    File.mkdir_p!(tmp_dir)
    Application.put_env(:orkestra_mcp, :project_dir, tmp_dir)

    on_exit(fn ->
      File.rm_rf!(tmp_dir)
      Application.delete_env(:orkestra_mcp, :project_dir)
    end)

    %{tmp_dir: tmp_dir}
  end

  test "creates ES projector module file", %{tmp_dir: tmp_dir} do
    {:ok, result} =
      GenEsProjection.execute(
        %{
          module_name: "MyApp.Orders.OrderESProjector",
          repo_module: "MyApp.OrderProjection.Repo",
          cluster_module: "MyApp.ESCluster",
          index: "orders",
          events: ~s(["MyApp.Events.OrderPlaced"])
        },
        nil
      )

    assert result =~ "Created"
    assert result =~ "backend: :elasticsearch"

    projector_file = Path.join(tmp_dir, "lib/my_app/orders/order_es_projector.ex")
    assert File.exists?(projector_file)
  end

  test "generated file contains index_mapping and project_es", %{tmp_dir: tmp_dir} do
    GenEsProjection.execute(
      %{
        module_name: "MyApp.Orders.OrderESProjector",
        repo_module: "MyApp.OrderProjection.Repo",
        cluster_module: "MyApp.ESCluster",
        index: "orders",
        events: ~s(["MyApp.Events.OrderPlaced"])
      },
      nil
    )

    projector_file = Path.join(tmp_dir, "lib/my_app/orders/order_es_projector.ex")
    content = File.read!(projector_file)

    assert content =~ "def index_mapping"
    assert content =~ "project_es"
    assert content =~ "@impl true"
  end

  test "handles empty events array" do
    {:ok, result} =
      GenEsProjection.execute(
        %{
          module_name: "MyApp.Orders.OrderESProjector",
          repo_module: "MyApp.OrderProjection.Repo",
          cluster_module: "MyApp.ESCluster",
          index: "orders",
          events: "[]"
        },
        nil
      )

    assert result =~ "Created"
    assert result =~ "TODO"
  end
end
