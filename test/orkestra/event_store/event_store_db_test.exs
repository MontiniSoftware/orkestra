defmodule Orkestra.EventStore.EventStoreDBTest do
  use ExUnit.Case, async: true

  @moduledoc """
  Compile/wiring-level tests for the EventStoreDB adapter.

  These tests verify that `Orkestra.EventStore.EventStoreDB` satisfies the
  `Orkestra.EventStore` behaviour contract and exports the expected callbacks.
  No live EventStoreDB connection is required — live `$all` subscription
  behavior and `commit_position` integer mapping (RESEARCH.md A4/A5) are
  verified against a live EventStoreDB in Phase 2 integration tests.
  """

  describe "Orkestra.EventStore.EventStoreDB module wiring" do
    test "module is available and loadable" do
      assert {:module, Orkestra.EventStore.EventStoreDB} =
               Code.ensure_loaded(Orkestra.EventStore.EventStoreDB)
    end

    test "module declares @behaviour Orkestra.EventStore" do
      behaviours =
        Orkestra.EventStore.EventStoreDB.__info__(:attributes)
        |> Keyword.get_values(:behaviour)
        |> List.flatten()

      assert Orkestra.EventStore in behaviours
    end

    test "subscribe_from_position/3 is exported" do
      assert function_exported?(Orkestra.EventStore.EventStoreDB, :subscribe_from_position, 3)
    end

    test "load_events/1 is exported" do
      assert function_exported?(Orkestra.EventStore.EventStoreDB, :load_events, 1)
    end

    test "load_events/2 is exported" do
      assert function_exported?(Orkestra.EventStore.EventStoreDB, :load_events, 2)
    end

    test "append_events/3 is exported" do
      assert function_exported?(Orkestra.EventStore.EventStoreDB, :append_events, 3)
    end

    test "all EventStore behaviour callbacks are satisfied" do
      # Verify that the module exports all required callbacks
      required_callbacks = Orkestra.EventStore.behaviour_info(:callbacks)

      for {name, arity} <- required_callbacks do
        assert function_exported?(Orkestra.EventStore.EventStoreDB, name, arity),
               "Expected #{name}/#{arity} to be exported on Orkestra.EventStore.EventStoreDB"
      end
    end
  end
end
