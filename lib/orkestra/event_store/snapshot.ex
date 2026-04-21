defmodule Orkestra.EventStore.Snapshot do
  @moduledoc """
  Snapshot support for aggregates.

  Snapshots are stored in a separate stream: `snapshot-{stream_id}`.
  They capture the aggregate state at a given revision, enabling
  faster state reconstruction by skipping event replay.
  """

  alias Orkestra.EventStore

  require Logger

  @snapshot_type "Orkestra.Snapshot"

  @doc "Checks if a snapshot should be taken based on the aggregate's config."
  @spec should_snapshot?(module(), non_neg_integer()) :: boolean()
  def should_snapshot?(aggregate_module, total_event_count) do
    interval = snapshot_interval(aggregate_module)
    interval != :never and total_event_count > 0 and rem(total_event_count, interval) == 0
  end

  @doc "Loads the latest snapshot for a stream."
  @spec load(String.t()) :: {:ok, %{state: term(), revision: non_neg_integer()}} | {:error, :no_snapshot}
  def load(stream_id) do
    snapshot_stream = snapshot_stream_id(stream_id)
    store = EventStore.impl()

    case store.load_events(snapshot_stream) do
      {:ok, [], _} ->
        {:error, :no_snapshot}

      {:ok, events, _} ->
        latest = List.last(events)

        case deserialize_state(latest.data) do
          {:ok, state, revision} ->
            {:ok, %{state: state, revision: revision}}

          {:error, _} = err ->
            Logger.warning("Failed to deserialize snapshot",
              stream: stream_id,
              orkestra: :snapshot
            )

            err
        end

      {:error, _} ->
        {:error, :no_snapshot}
    end
  end

  @doc "Saves a snapshot for a stream."
  @spec save(String.t(), term(), non_neg_integer()) :: :ok | {:error, term()}
  def save(stream_id, state, revision) do
    snapshot_stream = snapshot_stream_id(stream_id)
    store = EventStore.impl()

    event = %{
      id: Orkestra.Event.generate_id(),
      type: @snapshot_type,
      data: serialize_state(state, revision),
      metadata: %{},
      stream_revision: 0
    }

    case store.append_events(snapshot_stream, [event], :any) do
      {:ok, _} ->
        Logger.info("Snapshot saved",
          stream: stream_id,
          revision: revision,
          orkestra: :snapshot
        )

        :ok

      {:error, reason} ->
        Logger.error("Snapshot save failed",
          stream: stream_id,
          reason: inspect(reason),
          orkestra: :snapshot
        )

        {:error, reason}
    end
  end

  defp snapshot_stream_id(stream_id), do: "snapshot-#{stream_id}"

  defp snapshot_interval(aggregate_module) do
    if function_exported?(aggregate_module, :snapshot_every, 0) do
      aggregate_module.snapshot_every()
    else
      :never
    end
  end

  defp serialize_state(state, revision) do
    %{
      "state" => Base.encode64(:erlang.term_to_binary(state)),
      "revision" => revision,
      "taken_at" => DateTime.utc_now() |> DateTime.to_iso8601()
    }
  end

  defp deserialize_state(%{"state" => encoded, "revision" => revision}) do
    state = encoded |> Base.decode64!() |> :erlang.binary_to_term([:safe])
    {:ok, state, revision}
  rescue
    e -> {:error, e}
  end

  defp deserialize_state(_), do: {:error, :invalid_snapshot}
end
