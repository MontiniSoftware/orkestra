defmodule OrkestraMcp.Tools.GenEsQueriesTest do
  use ExUnit.Case, async: false

  alias OrkestraMcp.Tools.GenEsQueries

  setup do
    tmp_dir =
      Path.join(System.tmp_dir!(), "orkestra_mcp_es_qry_test_#{:rand.uniform(100_000)}")

    File.mkdir_p!(tmp_dir)
    Application.put_env(:orkestra_mcp, :project_dir, tmp_dir)

    on_exit(fn ->
      File.rm_rf!(tmp_dir)
      Application.delete_env(:orkestra_mcp, :project_dir)
    end)

    %{tmp_dir: tmp_dir}
  end

  test "creates ES queries module file", %{tmp_dir: tmp_dir} do
    {:ok, result} =
      GenEsQueries.execute(
        %{module_name: "MyApp.Orders.ESQueries", projector_module: "MyApp.Orders.OrderESProjector"},
        nil
      )

    assert result =~ "Created"
    assert result =~ "Orkestra.ES.Query"

    queries_file = Path.join(tmp_dir, "lib/my_app/orders/es_queries.ex")
    assert File.exists?(queries_file)
  end
end
