defmodule Orkestra.EventStore.EventStoreDBIntegrationTest do
  @moduledoc """
  Integration tests for `Orkestra.EventStore.EventStoreDB` against a *real*
  EventStoreDB (docker `eventstore/eventstore:24.10.0`, insecure, port 2113).

  Tagged `:integration` and therefore excluded from a default `mix test` run.
  Bring the backend up with:

      docker run -d --name orkestra-esdb-test -p 2113:2113 \\
        -e EVENTSTORE_INSECURE=true \\
        -e EVENTSTORE_MEM_DB=true \\
        -e EVENTSTORE_RUN_PROJECTIONS=None \\
        eventstore/eventstore:24.10.0

  then run `mix test --only integration`.

  These tests cover the adapter bugs found via the host-app smoke test:

    * appending to a brand-new stream with expected revision `-1` (the value
      `Orkestra.Aggregate.Root` passes on a first write) and with `:no_stream`;
    * subscribing to `$all` from position `-1` (the projector's initial
      checkpoint) and resuming from a saved commit_position without duplicates
      (exclusive `from:` semantics);
    * the delivery contract: subscribers receive `stored_event_with_position()`
      **maps** (parity with `InMemory`), not raw `%Spear.Event{}` structs, and
      never receive Spear control messages (checkpoints/caught_up/fell_behind).
  """

  use ExUnit.Case, async: false

  @moduletag :integration

  alias Orkestra.EventStore.EventStoreDB

  # The adapter talks to a hard-coded connection name (`@connection` =
  # Orkestra.EventStore.EventStoreDB.Connection), so we start a Spear.Connection
  # under exactly that name for the whole module.
  setup_all do
    conn_name = Orkestra.EventStore.EventStoreDB.Connection

    # start_supervised! ties the connection's lifetime to the module (not to the
    # short-lived setup_all process, which would take a plain start_link'd,
    # linked connection down with it and leave every test with a dead socket).
    start_supervised!(
      {Spear.Connection, name: conn_name, connection_string: "esdb://localhost:2113?tls=false"}
    )

    # Wait until the HTTP/2 connection is actually writable before the tests run.
    wait_ready(conn_name, 40)
    :ok
  end

  defp wait_ready(_conn, 0), do: flunk("EventStoreDB connection never became ready")

  defp wait_ready(conn, attempts) do
    probe = Spear.Event.new("ReadinessProbe", %{})

    case Spear.append([probe], conn, "orkestra-it-readiness", expect: :any) do
      :ok ->
        :ok

      _ ->
        Process.sleep(250)
        wait_ready(conn, attempts - 1)
    end
  end

  # Each test gets a fresh, globally-unique stream id. A random suffix (not just
  # System.unique_integer/1, which resets per BEAM run) guarantees uniqueness
  # even across repeated `mix test` runs against a persistent EventStoreDB.
  setup do
    {:ok, stream: "orkestra-it-#{Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)}"}
  end

  defp evt(id, type \\ "TestEvent", data \\ %{"n" => 1}, metadata \\ %{"correlation_id" => "c1"}) do
    %{id: id, type: type, data: data, metadata: metadata, stream_revision: 0}
  end

  describe "append_events/3 — new stream expected revision" do
    test "appends to a brand-new stream with expected_revision -1 (Aggregate.Root first write)",
         %{stream: stream} do
      # Regression for bug #1: the old `case expected_revision` had no -1 clause
      # and raised CaseClauseError against real EventStoreDB.
      assert {:ok, 0} = EventStoreDB.append_events(stream, [evt("e1")], -1)
    end

    test "appends to a brand-new stream with :no_stream", %{stream: stream} do
      assert {:ok, 0} = EventStoreDB.append_events(stream, [evt("e1")], :no_stream)
    end

    test "a second append with :no_stream on an existing stream conflicts", %{stream: stream} do
      assert {:ok, 0} = EventStoreDB.append_events(stream, [evt("e1")], :no_stream)

      assert {:error, :wrong_expected_version} =
               EventStoreDB.append_events(stream, [evt("e2")], :no_stream)
    end

    test "-1 on an existing (non-empty) stream conflicts, matching :no_stream",
         %{stream: stream} do
      assert {:ok, 0} = EventStoreDB.append_events(stream, [evt("e1")], -1)

      assert {:error, :wrong_expected_version} =
               EventStoreDB.append_events(stream, [evt("e2")], -1)
    end

    test "sequential appends with the correct expected revision advance the head",
         %{stream: stream} do
      assert {:ok, 0} = EventStoreDB.append_events(stream, [evt("e1")], :no_stream)
      assert {:ok, 1} = EventStoreDB.append_events(stream, [evt("e2")], 0)
      assert {:ok, 2} = EventStoreDB.append_events(stream, [evt("e3")], 1)
    end

    test "a stale expected revision conflicts", %{stream: stream} do
      assert {:ok, 0} = EventStoreDB.append_events(stream, [evt("e1")], :no_stream)
      # Head is 0; expecting 5 must fail.
      assert {:error, :wrong_expected_version} =
               EventStoreDB.append_events(stream, [evt("e2")], 5)
    end
  end

  describe "load_events/1,2 — round-trip" do
    test "load_events/1 on an empty stream returns {:ok, [], -1}", %{stream: stream} do
      assert {:ok, [], -1} = EventStoreDB.load_events(stream)
    end

    test "load_events/1 round-trips data, metadata and revision", %{stream: stream} do
      meta = %{"correlation_id" => "corr-9", "actor_id" => "u-1"}

      {:ok, _} =
        EventStoreDB.append_events(stream, [evt("e1", "Created", %{"x" => 10}, meta)], -1)

      {:ok, _} = EventStoreDB.append_events(stream, [evt("e2", "Updated", %{"x" => 20}, meta)], 0)

      assert {:ok, [ev1, ev2], 1} = EventStoreDB.load_events(stream)

      assert ev1.type == "Created"
      assert ev1.data == %{"x" => 10}
      # Known %Orkestra.Metadata{} keys are atomized on the way out (parity with
      # a caller reading atom keys); the string-keyed `meta` we wrote becomes
      # atom-keyed here. "Created" is not a real event module, so `data` keys are
      # left as decoded (string).
      assert ev1.metadata == %{correlation_id: "corr-9", actor_id: "u-1"}
      assert ev1.stream_revision == 0

      assert ev2.type == "Updated"
      assert ev2.data == %{"x" => 20}
      assert ev2.stream_revision == 1
    end

    test "load_events/2 reads only events after from_revision (exclusive)", %{stream: stream} do
      {:ok, _} = EventStoreDB.append_events(stream, [evt("e1")], -1)
      {:ok, _} = EventStoreDB.append_events(stream, [evt("e2")], 0)
      {:ok, _} = EventStoreDB.append_events(stream, [evt("e3")], 1)

      assert {:ok, [only], 2} = EventStoreDB.load_events(stream, 1)
      assert only.stream_revision == 2
    end
  end

  describe "subscribe_from_position/3 — $all delivery contract" do
    test "subscribing to :all from -1 delivers stored_event maps (not Spear structs)",
         %{stream: stream} do
      {:ok, sub} = EventStoreDB.subscribe_from_position(:all, -1, self())

      meta = %{"correlation_id" => "c-1"}
      {:ok, _} = EventStoreDB.append_events(stream, [evt("s1", "SubA", %{"k" => 1}, meta)], -1)
      {:ok, _} = EventStoreDB.append_events(stream, [evt("s2", "SubB", %{"k" => 2}, meta)], 0)

      # The adapter delivers stored_event_with_position() MAPS, never
      # %Spear.Event{}. Filter to our unique stream (via :stream_id, at parity
      # with InMemory) so unrelated $all traffic does not interfere.
      e1 = assert_receive_stored(stream)
      e2 = assert_receive_stored(stream)

      assert e1.type == "SubA"
      assert e1.data == %{"k" => 1}
      # correlation_id is a known metadata field → atomized on delivery.
      assert e1.metadata == %{correlation_id: "c-1"}
      assert is_integer(e1.global_position) and e1.global_position >= 0

      assert e2.type == "SubB"
      # $all positions are strictly increasing between events.
      assert e2.global_position > e1.global_position

      :ok = EventStoreDB.unsubscribe(sub)
    end

    test "resuming from a saved global_position does not re-deliver that event (exclusive)",
         %{stream: stream} do
      {:ok, sub1} = EventStoreDB.subscribe_from_position(:all, -1, self())
      {:ok, _} = EventStoreDB.append_events(stream, [evt("r1", "R1")], -1)
      {:ok, _} = EventStoreDB.append_events(stream, [evt("r2", "R2")], 0)
      {:ok, _} = EventStoreDB.append_events(stream, [evt("r3", "R3")], 1)

      e1 = assert_receive_stored(stream)
      e2 = assert_receive_stored(stream)
      _e3 = assert_receive_stored(stream)
      :ok = EventStoreDB.unsubscribe(sub1)

      assert e1.type == "R1"
      pos2 = e2.global_position
      assert is_integer(pos2)

      # Resume from R2's position. Exclusive semantics: we must NOT see R2 again —
      # the first event delivered for this stream must be R3.
      {:ok, sub2} = EventStoreDB.subscribe_from_position(:all, pos2, self())
      resumed = assert_receive_stored(stream)

      assert resumed.type == "R3",
             "expected exclusive resume to skip R2 (pos #{pos2}) and deliver R3, got #{resumed.type}"

      :ok = EventStoreDB.unsubscribe(sub2)
    end

    test "the subscriber never receives Spear control messages", %{stream: stream} do
      {:ok, sub} = EventStoreDB.subscribe_from_position(:all, -1, self())
      {:ok, _} = EventStoreDB.append_events(stream, [evt("c1", "CtrlA")], -1)

      _ = assert_receive_stored(stream)

      # Drain the mailbox briefly: nothing that is not a stored_event map (i.e.
      # no %Spear.Filter.Checkpoint{} / %Spear.Event{} / {:caught_up, _}) must
      # arrive. The relay swallows all of those.
      refute_receive %Spear.Filter.Checkpoint{}, 300
      refute_receive %Spear.Event{}, 10
      refute_receive {:caught_up, _}, 10
      refute_receive {:fell_behind, _}, 10

      :ok = EventStoreDB.unsubscribe(sub)
    end
  end

  # Receive the next delivered stored_event map for `stream_id`, skipping events
  # from other streams/tests carried by the $all feed. Filtering by the unique
  # per-run stream (not by type) keeps the test robust across repeated runs
  # against a persistent (MEM_DB) EventStoreDB where event types recur.
  defp assert_receive_stored(stream_id, timeout \\ 5_000) do
    receive do
      %{global_position: _, stream_id: ^stream_id} = e ->
        e

      %{global_position: _} ->
        assert_receive_stored(stream_id, timeout)
    after
      timeout -> flunk("timed out waiting for a stored event on #{stream_id}")
    end
  end
end
