defmodule Orkestra.EventStore.InMemory do
  @moduledoc """
  In-memory EventStore adapter backed by an Agent.
  For tests and local development without EventStoreDB.
  """

  @behaviour Orkestra.EventStore

  use Agent

  def start_link(opts \\ []) do
    name = opts[:name] || __MODULE__
    Agent.start_link(fn -> %{} end, name: name)
  end

  @doc "Resets all stored events. Useful in test setup."
  def reset!(name \\ __MODULE__) do
    Agent.update(name, fn _ -> %{} end)
  end

  @impl true
  def load_events(stream_id) do
    events = Agent.get(__MODULE__, &Map.get(&1, stream_id, []))

    case events do
      [] -> {:ok, [], -1}
      events -> {:ok, events, length(events) - 1}
    end
  end

  @impl true
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
  def append_events(stream_id, events, expected_revision) do
    Agent.get_and_update(__MODULE__, fn state ->
      current_events = Map.get(state, stream_id, [])
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

  defp do_append(state, stream_id, current_events, new_events) do
    base_revision = length(current_events)

    stamped =
      new_events
      |> Enum.with_index(base_revision)
      |> Enum.map(fn {event, rev} ->
        Map.put(event, :stream_revision, rev)
      end)

    all = current_events ++ stamped
    new_revision = length(all) - 1
    new_state = Map.put(state, stream_id, all)
    {{:ok, new_revision}, new_state}
  end
end
