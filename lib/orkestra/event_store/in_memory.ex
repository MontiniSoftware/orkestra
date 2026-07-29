defmodule Orkestra.EventStore.InMemory do
  @moduledoc """
  In-memory EventStore adapter backed by an Agent.
  For tests and local development without EventStoreDB.

  ## Agent State

  The Agent holds a map with the following keys:

  - `:streams` — map of `stream_id => [stored_event()]` for per-stream events
  - `:global_counter` — non-negative integer; incremented on each appended event
    to assign gap-free monotonic `:global_position` values (D-01)
  - `:subscribers` — list of `{ref, pid, stream_or_all}` tuples registered via
    `subscribe_from_position/3`. The `stream_or_all` is the subscribed stream id
    (or `:all`) and is used to filter live delivery; `ref` is the handle returned
    to the caller and accepted by `unsubscribe/1`.
  - `:global_events` — list of all events in global-append order, each extended
    with `:global_position`

  ## Subscriber Delivery (D-03)

  When a subscriber registers via `subscribe_from_position/3`, the adapter:

  1. Atomically registers the subscriber pid and snapshots `global_events` inside
     a single `Agent.get_and_update`, preventing races with concurrent appends
     (RESEARCH.md Pitfall 3).
  2. Replays snapshotted events with `global_position > from_position` (exclusive,
     matching Spear's `from:` semantics — Pitfall 1).
  3. On each subsequent `append_events/3`, pushes new events to each registered
     subscriber in order, filtered by the subscriber's subscribed stream
     (`:all` subscribers receive every event; a per-stream subscriber receives
     only events stamped with its `stream_id`).

  This push model mirrors EventStoreDB's subscription model so the Phase 2
  Projector GenServer can code against a single delivery interface.

  > Note: the Agent is a named singleton. InMemory subscription tests must use
  > `async: false` and start the adapter per-test via `start_supervised/1`.
  """

  @behaviour Orkestra.EventStore

  require Logger

  use Agent

  @doc "Starts the InMemory adapter. Accepts an optional `:name` in `opts`."
  @spec start_link(keyword()) :: Agent.on_start()
  def start_link(opts \\ []) do
    name = opts[:name] || __MODULE__

    Agent.start_link(
      fn ->
        %{
          streams: %{},
          global_counter: 0,
          subscribers: [],
          global_events: []
        }
      end,
      name: name
    )
  end

  @doc "Resets all stored events and subscriber state. Useful in test setup."
  @spec reset!(atom()) :: :ok
  def reset!(name \\ __MODULE__) do
    Agent.update(name, fn _ ->
      %{
        streams: %{},
        global_counter: 0,
        subscribers: [],
        global_events: []
      }
    end)
  end

  @impl true
  @spec load_events(Orkestra.EventStore.stream_id()) ::
          {:ok, [Orkestra.EventStore.stored_event()], Orkestra.EventStore.revision()}
          | {:error, term()}
  def load_events(stream_id) do
    events = Agent.get(__MODULE__, fn state -> Map.get(state.streams, stream_id, []) end)

    case events do
      [] -> {:ok, [], -1}
      events -> {:ok, events, length(events) - 1}
    end
  end

  @impl true
  @spec load_events(Orkestra.EventStore.stream_id(), non_neg_integer()) ::
          {:ok, [Orkestra.EventStore.stored_event()], Orkestra.EventStore.revision()}
          | {:error, term()}
  def load_events(stream_id, from_revision) do
    case load_events(stream_id) do
      {:ok, [], -1} ->
        {:ok, [], -1}

      {:ok, events, revision} ->
        filtered = Enum.filter(events, fn e -> e.stream_revision > from_revision end)
        {:ok, filtered, revision}
    end
  end

  @impl true
  @spec append_events(
          Orkestra.EventStore.stream_id(),
          [Orkestra.EventStore.stored_event()],
          Orkestra.EventStore.expected_revision()
        ) ::
          {:ok, Orkestra.EventStore.revision()}
          | {:error, :wrong_expected_version}
          | {:error, term()}
  def append_events(stream_id, events, expected_revision) do
    Agent.get_and_update(__MODULE__, fn state ->
      current_events = Map.get(state.streams, stream_id, [])
      current_revision = length(current_events) - 1

      cond do
        expected_revision == :any ->
          do_append(state, stream_id, current_events, events)

        expected_revision == :no_stream and current_events == [] ->
          do_append(state, stream_id, current_events, events)

        expected_revision == :no_stream ->
          {{:error, :wrong_expected_version}, state}

        expected_revision == current_revision ->
          do_append(state, stream_id, current_events, events)

        true ->
          {{:error, :wrong_expected_version}, state}
      end
    end)
  end

  @doc """
  Subscribes `subscriber` to receive events from `stream_id_or_all` starting
  after `from_position` (exclusive).

  Atomically registers the subscriber and snapshots existing events inside a
  single `Agent.get_and_update`, then replays the snapshot to the subscriber
  (filtered to `stream_id_or_all`). Subsequent calls to `append_events/3` push
  new events to all registered subscribers in order, filtered by each
  subscriber's subscribed stream.

  Returns `{:ok, subscription_ref}`. The returned ref is a real handle: pass it
  to `unsubscribe/1` to stop delivery and remove the subscriber from state.
  """
  @spec subscribe_from_position(Orkestra.EventStore.stream_id() | :all, integer(), pid()) ::
          {:ok, reference()} | {:error, term()}
  @impl true
  def subscribe_from_position(stream_id_or_all, from_position, subscriber) do
    ref = make_ref()

    # Atomically register the subscriber and snapshot current global_events.
    # This prevents a race where an append between registration and replay would
    # either be delivered twice (in replay AND live) or not at all (gap).
    # Agent.get_and_update/3 returns the first element of the tuple returned by
    # the callback; the second element becomes the new agent state.
    snapshot =
      Agent.get_and_update(__MODULE__, fn state ->
        snapshot = state.global_events

        new_state = %{
          state
          | subscribers: [{ref, subscriber, stream_id_or_all} | state.subscribers]
        }

        {snapshot, new_state}
      end)

    # Replay history outside the Agent update (the snapshot is a local copy).
    # Exclusive filter: deliver only events with global_position > from_position (Pitfall 1).
    snapshot
    |> filter_for_stream(stream_id_or_all)
    |> Enum.filter(fn e -> e.global_position > from_position end)
    |> Enum.each(fn e -> send(subscriber, e) end)

    Logger.debug("Subscribed to event stream",
      stream: inspect(stream_id_or_all),
      from_position: from_position,
      subscriber: inspect(subscriber),
      orkestra: :event_store
    )

    {:ok, ref}
  end

  @doc """
  Removes the subscription identified by `ref` so the subscriber stops
  receiving live events.

  Returns `:ok` whether or not a matching subscription existed (idempotent).
  """
  @spec unsubscribe(reference()) :: :ok
  def unsubscribe(ref) do
    Agent.update(__MODULE__, fn state ->
      %{
        state
        | subscribers: Enum.reject(state.subscribers, fn {r, _pid, _stream} -> r == ref end)
      }
    end)
  end

  # ── Private ─────────────────────────────────────────────────────

  defp do_append(state, stream_id, current_events, new_events) do
    base_revision = length(current_events)
    base_position = state.global_counter

    # Revision integrity is load-bearing for concurrency correctness. Assert the
    # invariant that the gap-free global counter equals the number of recorded
    # global events; any divergence indicates a bug in append bookkeeping and is
    # surfaced loudly here rather than silently corrupting ordering (WR-03).
    ^base_position = length(state.global_events)

    # Stamp each new event with stream_revision and global_position.
    # global_position is gap-free across all streams (D-01).
    stamped =
      new_events
      |> Enum.with_index(0)
      |> Enum.map(fn {event, idx} ->
        event
        |> Map.put(:stream_id, stream_id)
        |> Map.put(:stream_revision, base_revision + idx)
        |> Map.put(:global_position, base_position + idx)
      end)

    all_stream_events = current_events ++ stamped
    new_revision = length(all_stream_events) - 1
    new_counter = base_position + length(stamped)
    new_global_events = state.global_events ++ stamped

    new_state = %{
      state
      | streams: Map.put(state.streams, stream_id, all_stream_events),
        global_counter: new_counter,
        global_events: new_global_events
    }

    # Push each newly-appended event to all registered subscribers in order,
    # filtered by each subscriber's subscribed stream (CR-05). A `:stream_id`
    # subscriber receives only events for its stream; an `:all` subscriber
    # receives everything. This happens inside the Agent.get_and_update so the
    # state update and push are serialized — no concurrent append can interleave
    # deliveries (Pitfall 3).
    Enum.each(state.subscribers, fn {_ref, subscriber_pid, sub_stream} ->
      stamped
      |> filter_for_stream(sub_stream)
      |> Enum.each(fn e -> send(subscriber_pid, e) end)
    end)

    {{:ok, new_revision}, new_state}
  end

  # Filter global_events for a specific stream or return all for :all
  defp filter_for_stream(events, :all), do: events

  defp filter_for_stream(events, stream_id) do
    Enum.filter(events, fn e -> Map.get(e, :stream_id) == stream_id end)
  end
end
