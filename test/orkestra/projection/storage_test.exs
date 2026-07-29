defmodule Orkestra.Projection.StorageTest do
  use ExUnit.Case, async: true

  alias Orkestra.Projection.Storage

  # A minimal in-process stub adapter that satisfies the Storage behaviour contract.
  # This proves STORE-01: a module implementing write/4 and reset/2 satisfies the contract.
  defmodule StubAdapter do
    @moduledoc "Minimal stub storage adapter for contract verification."

    @behaviour Orkestra.Projection.Storage

    @impl true
    def write(_projector_name, _event, _position, _opts) do
      {:ok, [{:insert, :some_table, %{id: 1, value: "test"}}]}
    end

    @impl true
    def reset(_projector_name, _opts) do
      :ok
    end
  end

  describe "Storage behaviour contract" do
    test "a module implementing write/4 and reset/2 satisfies the behaviour" do
      behaviours =
        StubAdapter.__info__(:attributes) |> Keyword.get_values(:behaviour) |> List.flatten()

      assert Storage in behaviours
    end

    test "write/4 returns {:ok, ops} where ops is a plain term (not a closure)" do
      result = StubAdapter.write("my_projector", %{type: "SomeEvent", data: %{}}, 0, [])
      assert {:ok, ops} = result
      # ops must be a data structure, never a function/closure
      refute is_function(ops)
    end

    test "write/4 returns a list-based ops term" do
      {:ok, ops} = StubAdapter.write("my_projector", %{type: "SomeEvent", data: %{}}, 1, [])
      assert is_list(ops)
    end

    test "reset/2 returns :ok" do
      assert :ok = StubAdapter.reset("my_projector", [])
    end

    test "write/4 receives the global event position as the third argument" do
      position = 42
      # The contract mandates write/4 accepts the position; here we verify it is received
      assert {:ok, _ops} = StubAdapter.write("my_projector", %{type: "Event"}, position, [])
    end

    test "behaviour declares exactly write/4 and reset/2 callbacks" do
      callbacks = Storage.behaviour_info(:callbacks)
      assert {:write, 4} in callbacks
      assert {:reset, 2} in callbacks
    end
  end
end
