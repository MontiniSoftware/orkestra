defmodule OrkestraMcp.Tools.GenReadModelTest do
  use ExUnit.Case, async: false

  alias OrkestraMcp.Tools.GenReadModel

  setup do
    tmp_dir =
      Path.join(System.tmp_dir!(), "orkestra_mcp_rm_test_#{:rand.uniform(100_000)}")

    File.mkdir_p!(tmp_dir)
    Application.put_env(:orkestra_mcp, :project_dir, tmp_dir)

    on_exit(fn ->
      File.rm_rf!(tmp_dir)
      Application.delete_env(:orkestra_mcp, :project_dir)
    end)

    %{tmp_dir: tmp_dir}
  end

  test "creates schema file and migration file", %{tmp_dir: tmp_dir} do
    {:ok, result} =
      GenReadModel.execute(
        %{
          module_name: "MyApp.Orders.OrderReadModel",
          fields:
            Jason.encode!([
              %{"name" => "order_id", "type" => "binary_id"},
              %{"name" => "status", "type" => "string"}
            ])
        },
        nil
      )

    assert result =~ "Created"
    assert result =~ "use Ecto.Schema"

    schema_file = Path.join(tmp_dir, "lib/my_app/orders/order_read_model.ex")
    assert File.exists?(schema_file)

    migration_files =
      Path.wildcard(Path.join(tmp_dir, "priv/projections/**/migrations/*.exs"))

    assert migration_files != [], "Expected a migration file under priv/projections/"
  end
end
