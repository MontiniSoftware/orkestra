defmodule Orkestra.EventStore.InMemorySubscriptionTest do
  # async: false — InMemory adapter is a named singleton Agent; concurrent tests would share state
  use ExUnit.Case, async: false

  alias Orkestra.EventStore.InMemory

  setup do
    # Start a fresh InMemory adapter for each test; supervised so it is cleaned up after the test
    {:ok, _pid} = start_supervised(InMemory)
    :ok
  end

  describe "subscribe_from_position/3 — live delivery after subscribe" do
    test "after subscribing, 3 appended events are received in global-position order" do
      {:ok, _ref} = InMemory.subscribe_from_position(:all, -1, self())

      InMemory.append_events("stream-a", [%{id: "e1", type: "A", data: %{}, metadata: %{}}], :any)
      InMemory.append_events("stream-b", [%{id: "e2", type: "B", data: %{}, metadata: %{}}], :any)
      InMemory.append_events("stream-a", [%{id: "e3", type: "C", data: %{}, metadata: %{}}], :any)

      assert_receive %{id: "e1", global_position: pos1}
      assert_receive %{id: "e2", global_position: pos2}
      assert_receive %{id: "e3", global_position: pos3}

      # Global positions must be strictly increasing (D-01: monotonic)
      assert pos1 < pos2
      assert pos2 < pos3

      # No unexpected messages
      refute_receive _
    end
  end

  describe "subscribe_from_position/3 — exclusive history replay" do
    test "replays only events with global_position strictly > from_position (exclusive — Pitfall 1)" do
      # Append 2 events before subscribing
      InMemory.append_events(
        "stream-a",
        [
          %{id: "e1", type: "A", data: %{}, metadata: %{}},
          %{id: "e2", type: "B", data: %{}, metadata: %{}}
        ],
        :any
      )

      # Both events are at global_position 0 and 1.
      # Subscribe from position 0 — should replay only events > 0, i.e. event at position 1
      {:ok, _ref} = InMemory.subscribe_from_position(:all, 0, self())

      # Only the second event (global_position 1) replayed; first is excluded (0 is not > 0)
      assert_receive %{id: "e2", global_position: 1}
      refute_receive %{id: "e1"}
    end

    test "subscribing from -1 replays all existing events" do
      InMemory.append_events(
        "stream-a",
        [
          %{id: "e1", type: "A", data: %{}, metadata: %{}},
          %{id: "e2", type: "B", data: %{}, metadata: %{}}
        ],
        :any
      )

      {:ok, _ref} = InMemory.subscribe_from_position(:all, -1, self())

      assert_receive %{id: "e1", global_position: 0}
      assert_receive %{id: "e2", global_position: 1}
      refute_receive _
    end
  end

  describe "subscribe_from_position/3 — no history when already at head" do
    test "subscriber at latest position receives no history but gets subsequent events" do
      InMemory.append_events("stream-a", [%{id: "e1", type: "A", data: %{}, metadata: %{}}], :any)

      # Subscribe from position 0 (the position of the event just appended — exclusive means we're at head)
      {:ok, _ref} = InMemory.subscribe_from_position(:all, 0, self())

      # No replayed history (there is no event with global_position > 0 yet)
      refute_receive _

      # But new events ARE delivered
      InMemory.append_events("stream-b", [%{id: "e2", type: "B", data: %{}, metadata: %{}}], :any)
      assert_receive %{id: "e2", global_position: 1}
    end
  end

  describe "subscribe_from_position/3 — gap-free monotonic global_position" do
    test "global_position values are gap-free starting at 0 across all streams" do
      InMemory.append_events("stream-a", [%{id: "e1", type: "A", data: %{}, metadata: %{}}], :any)
      InMemory.append_events("stream-b", [%{id: "e2", type: "B", data: %{}, metadata: %{}}], :any)
      InMemory.append_events("stream-c", [%{id: "e3", type: "C", data: %{}, metadata: %{}}], :any)

      {:ok, _ref} = InMemory.subscribe_from_position(:all, -1, self())

      assert_receive %{id: "e1", global_position: 0}
      assert_receive %{id: "e2", global_position: 1}
      assert_receive %{id: "e3", global_position: 2}
    end

    test "subscribe_from_position/3 returns {:ok, ref}" do
      result = InMemory.subscribe_from_position(:all, -1, self())
      assert {:ok, ref} = result
      assert is_reference(ref)
    end
  end
end
