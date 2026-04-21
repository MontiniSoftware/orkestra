defmodule Orkestra.EventStore do
  @moduledoc """
  Behaviour for event persistence with optimistic concurrency.

  Two adapters provided:
  - `EventStore.InMemory` — Agent-based, for tests
  - `EventStore.EventStoreDB` — gRPC adapter via Spear for EventStoreDB

  ## Configuration

      config :ultimus, Orkestra.EventStore,
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

  @doc "Loads all events from a stream. Returns `{:ok, events, current_revision}` or `{:error, reason}`."
  @callback load_events(stream_id()) ::
              {:ok, [stored_event()], revision()} | {:error, term()}

  @doc "Loads events from a stream starting after `from_revision`."
  @callback load_events(stream_id(), from_revision :: non_neg_integer()) ::
              {:ok, [stored_event()], revision()} | {:error, term()}

  @doc """
  Appends events to a stream with optimistic concurrency.
  Returns `{:ok, new_revision}` or `{:error, :wrong_expected_version}`.
  """
  @callback append_events(stream_id(), events :: [stored_event()], expected_revision()) ::
              {:ok, revision()} | {:error, :wrong_expected_version} | {:error, term()}

  @doc "Returns the configured EventStore adapter."
  @spec impl() :: module()
  def impl do
    Application.get_env(:ultimus, __MODULE__, [])
    |> Keyword.get(:adapter, Orkestra.EventStore.InMemory)
  end
end
