defmodule Orkestra.Projection.SupervisorTest do
  @moduledoc false

  use ExUnit.Case, async: false

  # ---------------------------------------------------------------------------
  # Minimal fake projectors — return Agent child specs so tests run without DB
  # ---------------------------------------------------------------------------

  defmodule FakeProjectorA do
    @moduledoc false

    def child_spec(opts) do
      name = Keyword.get(opts, :name, __MODULE__)

      %{
        id: __MODULE__,
        start: {Agent, :start_link, [fn -> :running end, [name: name]]}
      }
    end
  end

  defmodule FakeProjectorB do
    @moduledoc false

    def child_spec(opts) do
      name = Keyword.get(opts, :name, __MODULE__)

      %{
        id: __MODULE__,
        start: {Agent, :start_link, [fn -> :running end, [name: name]]}
      }
    end
  end

  # ---------------------------------------------------------------------------
  # Tests
  # ---------------------------------------------------------------------------

  describe "start_link/1 — bare module list" do
    test "starts all projectors from list" do
      start_supervised!(
        {Orkestra.Projection.Supervisor,
         projectors: [FakeProjectorA, FakeProjectorB],
         name: :"test_sup_#{System.unique_integer([:positive])}"}
      )

      assert Agent.get(FakeProjectorA, & &1) == :running
      assert Agent.get(FakeProjectorB, & &1) == :running
    end
  end

  describe "one_for_one isolation" do
    test "stopping one projector does not affect the other" do
      sup_name = :"test_sup_isolation_#{System.unique_integer([:positive])}"

      start_supervised!(
        {Orkestra.Projection.Supervisor,
         projectors: [FakeProjectorA, FakeProjectorB], name: sup_name}
      )

      assert Agent.get(FakeProjectorA, & &1) == :running
      assert Agent.get(FakeProjectorB, & &1) == :running

      # Terminate FakeProjectorA — FakeProjectorB must stay alive
      :ok = Supervisor.terminate_child(sup_name, FakeProjectorA)

      # FakeProjectorB still alive
      assert Agent.get(FakeProjectorB, & &1) == :running

      # FakeProjectorA is gone (raises after terminate)
      assert_raise RuntimeError, fn ->
        _ = Process.whereis(FakeProjectorA) || raise "not registered"
        # If registered by atom it may return nil — either way it's not running
      end
    end
  end

  describe "tuple form {module, opts}" do
    test "accepts {module, opts} tuple form and passes opts to child_spec" do
      sup_name = :"test_sup_tuple_#{System.unique_integer([:positive])}"
      agent_name = :"custom_a_#{System.unique_integer([:positive])}"

      start_supervised!(
        {Orkestra.Projection.Supervisor,
         projectors: [{FakeProjectorA, name: agent_name}], name: sup_name}
      )

      assert Agent.get(agent_name, & &1) == :running
    end
  end

  describe "error handling" do
    test "raises if :projectors key is missing" do
      assert_raise KeyError, fn ->
        Orkestra.Projection.Supervisor.start_link([])
      end
    end
  end
end
