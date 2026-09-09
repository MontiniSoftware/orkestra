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

  # Ensure the module is loaded before any export check — `function_exported?/3`
  # returns false for a not-yet-loaded module, which made the export tests flaky
  # under randomized async ordering.
  setup_all do
    {:module, _} = Code.ensure_loaded(Orkestra.EventStore.EventStoreDB)
    :ok
  end

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

  alias Orkestra.EventStore.EventStoreDB

  describe "map_expected_revision/1 — expected_revision → Spear :expect (no connection)" do
    test ":any maps to :any" do
      assert EventStoreDB.map_expected_revision(:any) == :any
    end

    test ":no_stream maps to :empty (Spear's empty-stream expectation)" do
      assert EventStoreDB.map_expected_revision(:no_stream) == :empty
    end

    test "-1 (empty-stream head revision from load_events/1) maps to :empty" do
      # Regression: Aggregate.Root passes -1 for a first write to a new stream.
      # The old `case` had no -1 clause and raised CaseClauseError.
      assert EventStoreDB.map_expected_revision(-1) == :empty
    end

    test "a non-negative revision passes through unchanged" do
      assert EventStoreDB.map_expected_revision(0) == 0
      assert EventStoreDB.map_expected_revision(41) == 41
    end
  end

  describe "map_subscribe_from/2 — from_position → Spear :from (no connection)" do
    test "-1 maps to :start for :all (replay from beginning)" do
      assert EventStoreDB.map_subscribe_from(:all, -1) == :start
    end

    test "nil maps to :start" do
      assert EventStoreDB.map_subscribe_from(:all, nil) == :start
      assert EventStoreDB.map_subscribe_from("stream-1", nil) == :start
    end

    test ":all with a non-negative commit_position maps to an exclusive Checkpoint" do
      # Regression: passing a bare integer for :all raised FunctionClauseError in
      # Spear's map_all_position/1. It must be a %Spear.Filter.Checkpoint{}.
      assert %Spear.Filter.Checkpoint{commit_position: 42, prepare_position: 42} =
               EventStoreDB.map_subscribe_from(:all, 42)
    end

    test "a named stream with a non-negative revision passes the integer through" do
      assert EventStoreDB.map_subscribe_from("stream-1", 7) == 7
    end
  end

  describe "to_stored_event/1 — Spear.Event → stored_event map (no connection)" do
    test "a $all-delivered event maps to a stored_event_with_position map" do
      # An event as delivered on a subscription: metadata carries stream_revision,
      # commit_position (the $all position) and JSON-encoded custom_metadata.
      spear_event = %Spear.Event{
        id: "evt-1",
        type: "MemberJoined",
        body: %{"member_id" => "m-1"},
        metadata: %{
          stream_revision: 3,
          commit_position: 4242,
          prepare_position: 4242,
          custom_metadata: Jason.encode!(%{"correlation_id" => "c-1", "actor_id" => "u-1"}),
          stream_name: "workspace-1"
        }
      }

      stored = EventStoreDB.to_stored_event(spear_event)

      # Same keys/types the projector matches on and InMemory delivers.
      assert stored.id == "evt-1"
      assert stored.type == "MemberJoined"
      # "MemberJoined" is not a loaded Orkestra.Event module, so the data keys
      # stay as decoded (string). See the normalization describe-block below for
      # the known-event (atom-key) case.
      assert stored.data == %{"member_id" => "m-1"}
      # Metadata known keys are atomized to the %Orkestra.Metadata{} contract
      # regardless of event type; custom keys would stay strings.
      assert stored.metadata == %{correlation_id: "c-1", actor_id: "u-1"}
      assert stored.stream_revision == 3
      # commit_position surfaced as the monotonic :global_position (D-01).
      assert stored.global_position == 4242
      # stream_name surfaced as :stream_id (parity with InMemory).
      assert stored.stream_id == "workspace-1"
    end

    test "an event without a commit_position omits :global_position (plain read shape)" do
      # load_events/1,2 reuse to_stored_event/1; a plain read has no position.
      spear_event = %Spear.Event{
        id: "evt-2",
        type: "Created",
        body: %{"x" => 1},
        metadata: %{stream_revision: 0, custom_metadata: ""}
      }

      stored = EventStoreDB.to_stored_event(spear_event)

      assert stored.id == "evt-2"
      assert stored.stream_revision == 0
      refute Map.has_key?(stored, :global_position)
    end

    test "empty custom_metadata decodes to an empty map" do
      spear_event = %Spear.Event{
        id: "evt-3",
        type: "Created",
        body: %{},
        metadata: %{stream_revision: 0, commit_position: 7, custom_metadata: ""}
      }

      stored = EventStoreDB.to_stored_event(spear_event)
      assert stored.metadata == %{}
      assert stored.global_position == 7
    end

    test "a negative commit_position is not surfaced as :global_position" do
      # Guards the WR-05 arithmetic contract: :global_position is only added when
      # a real non-negative position is present.
      spear_event = %Spear.Event{
        id: "evt-4",
        type: "Created",
        body: %{},
        metadata: %{stream_revision: 0, commit_position: -1, custom_metadata: ""}
      }

      refute Map.has_key?(EventStoreDB.to_stored_event(spear_event), :global_position)
    end
  end

  # A real Orkestra.Event module, so `to_stored_event/1` can resolve it and
  # atomize the JSON-decoded (string-keyed) data back to the field atoms.
  defmodule KnownEvent do
    use Orkestra.Event

    field(:workspace_id, :string, required: true)
    field(:name, :string)
    field(:settings, :map, default: %{})
  end

  describe "to_stored_event/1 — data/metadata key normalization (parity with InMemory)" do
    test "a KNOWN event's data keys are atomized to the struct fields (first level)" do
      # Regression for the real host-app bug: Spear decodes the JSON body into a
      # STRING-keyed map, so `event.data.workspace_id` crashed with KeyError.
      spear_event = %Spear.Event{
        id: "evt-known",
        type: %KnownEvent{}.type,
        body: %{
          "workspace_id" => "ws-1",
          "name" => "Acme",
          # Nested values are NOT recursed into — the inner "role" key stays a
          # string (enum/datetime/value-object conversion is the domain's job).
          "settings" => %{"role" => "admin"}
        },
        metadata: %{stream_revision: 0, commit_position: 1, custom_metadata: ""}
      }

      stored = EventStoreDB.to_stored_event(spear_event)

      # First-level field keys are atoms now — `stored.data.workspace_id` works.
      assert stored.data.workspace_id == "ws-1"
      assert stored.data.name == "Acme"
      # Nested map is untouched (still string-keyed).
      assert stored.data.settings == %{"role" => "admin"}
      # No stray string keys left at the top level.
      assert Map.keys(stored.data) |> Enum.all?(&is_atom/1)
    end

    test "an UNKNOWN event type leaves data keys as string (no raise, no atom churn)" do
      spear_event = %Spear.Event{
        id: "evt-unknown",
        type: "Some.Foreign.Event.That.Does.Not.Exist",
        body: %{"workspace_id" => "ws-9", "arbitrary" => 1},
        metadata: %{stream_revision: 0, commit_position: 2, custom_metadata: ""}
      }

      stored = EventStoreDB.to_stored_event(spear_event)

      # Untouched: unknown module ⇒ string keys preserved, never crashes.
      assert stored.data == %{"workspace_id" => "ws-9", "arbitrary" => 1}
    end

    test "metadata known keys are atomized while custom keys stay strings" do
      spear_event = %Spear.Event{
        id: "evt-meta",
        type: %KnownEvent{}.type,
        body: %{"workspace_id" => "ws-2"},
        metadata: %{
          stream_revision: 0,
          commit_position: 3,
          custom_metadata:
            Jason.encode!(%{
              "correlation_id" => "corr-1",
              "actor_type" => "user",
              # Not a %Orkestra.Metadata{} field → must remain a string key.
              "tenant_id" => "t-1"
            })
        }
      }

      stored = EventStoreDB.to_stored_event(spear_event)

      assert stored.metadata.correlation_id == "corr-1"
      # Value is left as-is (string "user"), only the key is atomized.
      assert stored.metadata.actor_type == "user"
      assert stored.metadata["tenant_id"] == "t-1"
      refute Map.has_key?(stored.metadata, "correlation_id")
    end
  end
end
