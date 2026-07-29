defmodule Orkestra.EventStore do
  @moduledoc """
  Behaviour for event persistence with optimistic concurrency.

  Two adapters provided:
  - `EventStore.InMemory` — Agent-based, for tests
  - `EventStore.EventStoreDB` — gRPC adapter via Spear for EventStoreDB

  ## Configuration

      config :orkestra, Orkestra.EventStore,
        adapter: Orkestra.EventStore.EventStoreDB
  """

  @type stream_id :: String.t()
  @type revision :: non_neg_integer() | -1
  @type expected_revision :: non_neg_integer() | :any | :no_stream

  @type stored_event :: %{
          id: String.t(),
          type: String.t(),
          data: map(),
          metadata: map(),
          stream_revision: non_neg_integer()
        }

  @typedoc """
  A `stored_event()` extended with a `:global_position` key, delivered to
  subscribers of `subscribe_from_position/3`.

  The `:global_position` is a non-negative monotonic integer (D-01):
  - InMemory adapter: gap-free counter starting at 0 across all streams.
  - EventStoreDB adapter: `commit_position` from the `$all` stream (monotonic,
    but not necessarily gap-free).
  """
  @type stored_event_with_position :: %{
          id: String.t(),
          type: String.t(),
          data: map(),
          metadata: map(),
          stream_revision: non_neg_integer(),
          global_position: non_neg_integer()
        }

  @doc """
  Loads all events from a stream. Returns `{:ok, events, current_revision}` or
  `{:error, reason}`.

  The returned revision is the stream's current head revision. For a genuinely
  empty (non-existent) stream the returned revision is `-1` and the event list
  is empty (WR-02).
  """
  @callback load_events(stream_id()) ::
              {:ok, [stored_event()], revision()} | {:error, term()}

  @doc """
  Loads events from a stream starting after `from_revision`.

  The third tuple element is always the stream's **current head revision**,
  independent of the filter: when `from_revision` is at or beyond the head the
  event list is empty but the returned revision is still the head revision (not
  `-1`). The `-1` empty revision is reserved for a genuinely empty stream, as in
  `load_events/1` (WR-02).
  """
  @callback load_events(stream_id(), from_revision :: non_neg_integer()) ::
              {:ok, [stored_event()], revision()} | {:error, term()}

  @doc """
  Appends events to a stream with optimistic concurrency.
  Returns `{:ok, new_revision}` or `{:error, :wrong_expected_version}`.
  """
  @callback append_events(stream_id(), events :: [stored_event()], expected_revision()) ::
              {:ok, revision()} | {:error, :wrong_expected_version} | {:error, term()}

  @doc """
  Asynchronously subscribes `subscriber` to receive events starting after
  `from_position` (exclusive). Use `:all` as `stream_id` to subscribe across
  all streams.

  Pushes messages of type `stored_event_with_position()` to `subscriber` — a
  `stored_event()` map extended with a `:global_position` key (D-01).

  Position semantics are **exclusive**: `from_position: N` delivers events with
  `global_position > N`. This matches Spear's `from:` semantics for
  EventStoreDB subscriptions. Starting from `-1` replays all events from the
  beginning.

  Returns `{:ok, subscription_ref}` on success, or `{:error, reason}` on
  failure.
  """
  @callback subscribe_from_position(
              stream_id :: stream_id() | :all,
              from_position :: integer(),
              subscriber :: pid()
            ) :: {:ok, reference()} | {:error, term()}

  @doc "Returns the configured EventStore adapter."
  @spec impl() :: module()
  def impl do
    Application.get_env(:orkestra, __MODULE__, [])
    |> Keyword.get(:adapter, Orkestra.EventStore.InMemory)
  end
end
