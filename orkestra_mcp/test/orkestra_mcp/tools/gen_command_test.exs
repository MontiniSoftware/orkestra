defmodule OrkestraMcp.Tools.GenCommandTest do
  use ExUnit.Case, async: false

  alias OrkestraMcp.Tools.GenCommand

  setup do
    tmp_dir = Path.join(System.tmp_dir!(), "orkestra_mcp_tool_test_#{:rand.uniform(100_000)}")
    File.mkdir_p!(tmp_dir)
    Application.put_env(:orkestra_mcp, :project_dir, tmp_dir)

    on_exit(fn ->
      File.rm_rf!(tmp_dir)
      Application.delete_env(:orkestra_mcp, :project_dir)
    end)

    %{tmp_dir: tmp_dir}
  end

  test "creates command file", %{tmp_dir: tmp_dir} do
    params_json = Jason.encode!([%{name: "user_id", type: "string", required: true}])

    {:ok, result} =
      GenCommand.execute(
        %{module_name: "MyApp.Users.Commands.CreateUser", params: params_json},
        nil
      )

    assert result =~ "Created"
    assert result =~ "param :user_id, :string, required: true"

    file = Path.join(tmp_dir, "lib/my_app/users/commands/create_user.ex")
    assert File.exists?(file)
    assert File.read!(file) =~ "defmodule MyApp.Users.Commands.CreateUser"
  end
end
