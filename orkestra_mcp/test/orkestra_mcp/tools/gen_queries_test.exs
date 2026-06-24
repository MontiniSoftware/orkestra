defmodule OrkestraMcp.Tools.GenQueriesTest do
  use ExUnit.Case, async: false

  alias OrkestraMcp.Tools.GenQueries

  setup do
    tmp_dir =
      Path.join(System.tmp_dir!(), "orkestra_mcp_qry_test_#{:rand.uniform(100_000)}")

    File.mkdir_p!(tmp_dir)
    Application.put_env(:orkestra_mcp, :project_dir, tmp_dir)

    on_exit(fn ->
      File.rm_rf!(tmp_dir)
      Application.delete_env(:orkestra_mcp, :project_dir)
    end)

    %{tmp_dir: tmp_dir}
  end

  test "creates queries module file", %{tmp_dir: tmp_dir} do
    {:ok, result} =
      GenQueries.execute(
        %{
          module_name: "MyApp.Orders.Queries",
          schema_module: "MyApp.Orders.OrderReadModel"
        },
        nil
      )

    assert result =~ "Created"
    assert result =~ "import Ecto.Query"

    queries_file = Path.join(tmp_dir, "lib/my_app/orders/queries.ex")
    assert File.exists?(queries_file)
  end
end
