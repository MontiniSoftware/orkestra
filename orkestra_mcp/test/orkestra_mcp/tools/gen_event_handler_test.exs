defmodule OrkestraMcp.Tools.GenEventHandlerTest do
  use ExUnit.Case, async: false

  alias OrkestraMcp.Tools.GenEventHandler

  setup do
    tmp_dir = Path.join(System.tmp_dir!(), "orkestra_mcp_eh_test_#{:rand.uniform(100_000)}")
    File.mkdir_p!(tmp_dir)
    Application.put_env(:orkestra_mcp, :project_dir, tmp_dir)

    on_exit(fn ->
      File.rm_rf!(tmp_dir)
      Application.delete_env(:orkestra_mcp, :project_dir)
    end)

    %{tmp_dir: tmp_dir}
  end

  test "creates single-event handler file", %{tmp_dir: tmp_dir} do
    opts_json = Jason.encode!(%{mode: "single", event: "MyApp.Events.UserCreated"})

    {:ok, result} =
      GenEventHandler.execute(
        %{module_name: "MyApp.Handlers.WelcomeEmail", opts: opts_json},
        nil
      )

    assert result =~ "Created"
    assert result =~ "use Orkestra.EventHandler, event: MyApp.Events.UserCreated"

    file = Path.join(tmp_dir, "lib/my_app/handlers/welcome_email.ex")
    assert File.exists?(file)
  end
end
