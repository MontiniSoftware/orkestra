defmodule OrkestraMcp.Tools.GenCommandHandlerTest do
  use ExUnit.Case, async: false

  alias OrkestraMcp.Tools.GenCommandHandler

  setup do
    tmp_dir = Path.join(System.tmp_dir!(), "orkestra_mcp_ch_test_#{:rand.uniform(100_000)}")
    File.mkdir_p!(tmp_dir)
    Application.put_env(:orkestra_mcp, :project_dir, tmp_dir)

    on_exit(fn ->
      File.rm_rf!(tmp_dir)
      Application.delete_env(:orkestra_mcp, :project_dir)
    end)

    %{tmp_dir: tmp_dir}
  end

  test "creates command handler file", %{tmp_dir: tmp_dir} do
    {:ok, result} =
      GenCommandHandler.execute(
        %{
          module_name: "MyApp.Handlers.CreateUserHandler",
          command_module: "MyApp.Commands.CreateUser"
        },
        nil
      )

    assert result =~ "Created"
    assert result =~ "use Orkestra.CommandHandler, command: MyApp.Commands.CreateUser"

    file = Path.join(tmp_dir, "lib/my_app/handlers/create_user_handler.ex")
    assert File.exists?(file)
  end
end
