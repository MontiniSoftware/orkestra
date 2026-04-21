defmodule Orkestra.CommandTest do
  use ExUnit.Case, async: true

  defmodule StartTask do
    use Orkestra.Command

    param :repo, :string, required: true
    param :branch, :string, default: "main"
    param :depth, :string, default: "standard"
    param :tags, :list, default: []
  end

  defmodule ValidatedCommand do
    use Orkestra.Command

    param :count, :integer, required: true

    @impl true
    def validate(%{count: count}) when is_integer(count) and count > 0, do: :ok
    def validate(_), do: {:error, :count_must_be_positive}
  end

  describe "new/2" do
    test "creates a command with required params" do
      assert {:ok, cmd} = StartTask.new(%{repo: "owner/repo"})
      assert cmd.params.repo == "owner/repo"
      assert cmd.params.branch == "main"
      assert cmd.params.depth == "standard"
      assert cmd.params.tags == []
    end

    test "generates a unique id" do
      {:ok, cmd1} = StartTask.new(%{repo: "a"})
      {:ok, cmd2} = StartTask.new(%{repo: "b"})
      assert cmd1.id != cmd2.id
    end

    test "sets the type from module name" do
      {:ok, cmd} = StartTask.new(%{repo: "a"})
      assert cmd.type == "Orkestra.CommandTest.StartTask"
    end

    test "attaches metadata" do
      {:ok, cmd} = StartTask.new(%{repo: "a"}, actor_id: "u1", source: "test")
      assert cmd.metadata.actor_id == "u1"
      assert cmd.metadata.source == "test"
      assert is_binary(cmd.metadata.correlation_id)
    end

    test "overrides defaults" do
      {:ok, cmd} = StartTask.new(%{repo: "a", branch: "dev", depth: "deep"})
      assert cmd.params.branch == "dev"
      assert cmd.params.depth == "deep"
    end

    test "accepts string keys" do
      {:ok, cmd} = StartTask.new(%{"repo" => "a", "branch" => "feat"})
      assert cmd.params.repo == "a"
      assert cmd.params.branch == "feat"
    end

    test "fails on missing required params" do
      assert {:error, {:missing_params, [:repo]}} = StartTask.new(%{branch: "dev"})
    end

    test "fails on nil required param" do
      assert {:error, {:missing_params, [:repo]}} = StartTask.new(%{repo: nil})
    end

    test "fails on empty string required param" do
      assert {:error, {:missing_params, [:repo]}} = StartTask.new(%{repo: ""})
    end
  end

  describe "new!/2" do
    test "returns command on success" do
      cmd = StartTask.new!(%{repo: "a"})
      assert cmd.params.repo == "a"
    end

    test "raises on failure" do
      assert_raise RuntimeError, ~r/validation failed/, fn ->
        StartTask.new!(%{})
      end
    end
  end

  describe "custom validate/1" do
    test "passes valid params" do
      assert {:ok, _} = ValidatedCommand.new(%{count: 5})
    end

    test "rejects invalid params" do
      assert {:error, :count_must_be_positive} = ValidatedCommand.new(%{count: -1})
    end
  end

  describe "param_definitions/0" do
    test "returns all param definitions" do
      defs = StartTask.param_definitions()
      assert length(defs) == 4

      {name, type, opts} = Enum.find(defs, fn {n, _, _} -> n == :repo end)
      assert name == :repo
      assert type == :string
      assert opts[:required] == true
    end
  end
end
