defmodule Orkestra.EventStore.EventStoreDB do
  @moduledoc """
  EventStoreDB adapter via Spear gRPC client.

  Requires `Spear.Connection` in the supervision tree.

  ## Configuration

      config :ultimus, Orkestra.EventStore.EventStoreDB,
        connection_string: "esdb://localhost:2113?tls=false"
  """

  @behaviour Orkestra.EventStore

  require Logger

  @connection __MODULE__.Connection

  @impl true
  def load_events(stream_id) do
    try do
      events =
        Spear.stream!(@connection, stream_id, direction: :forwards)
        |> Enum.to_list()

      case events do
        [] ->
          {:ok, [], -1}

        events ->
          stored = Enum.map(events, &to_stored_event/1)
          revision = List.last(events).metadata.stream_revision
          {:ok, stored, revision}
      end
    rescue
      e in Spear.Grpc.Response ->
        if e.status == :not_found do
          {:ok, [], -1}
        else
          Logger.error("EventStoreDB load failed",
            stream: stream_id,
            error: inspect(e),
            orkestra: :event_store
          )

          {:error, e}
        end

      e ->
        Logger.error("EventStoreDB load failed",
          stream: stream_id,
          error: Exception.message(e),
          orkestra: :event_store
        )

        {:error, e}
    end
  end

  @impl true
  def load_events(stream_id, from_revision) do
    try do
      events =
        Spear.stream!(@connection, stream_id,
          direction: :forwards,
          from: from_revision + 1
        )
        |> Enum.to_list()

      case events do
        [] ->
          {:ok, [], from_revision}

        events ->
          stored = Enum.map(events, &to_stored_event/1)
          revision = List.last(events).metadata.stream_revision
          {:ok, stored, revision}
      end
    rescue
      e in Spear.Grpc.Response ->
        if e.status == :not_found do
          {:ok, [], from_revision}
        else
          {:error, e}
        end

      e ->
        {:error, e}
    end
  end

  @impl true
  def append_events(stream_id, events, expected_revision) do
    spear_events =
      Enum.map(events, fn event ->
        Spear.Event.new(
          event.type,
          event.data,
          metadata: event.metadata
        )
      end)

    expect =
      case expected_revision do
        :any -> :any
        :no_stream -> :empty
        -1 -> :empty
        rev when is_integer(rev) -> rev
      end

    case Spear.append(spear_events, @connection, stream_id, expect: expect, raw?: true) do
      {:ok, response} ->
        new_revision = extract_revision(response)

        Logger.debug("Events appended",
          stream: stream_id,
          count: length(events),
          revision: new_revision,
          orkestra: :event_store
        )

        {:ok, new_revision}

      {:error, %Spear.ExpectationViolation{}} ->
        Logger.warning("Wrong expected version",
          stream: stream_id,
          expected: expected_revision,
          orkestra: :event_store
        )

        {:error, :wrong_expected_version}

      {:error, reason} ->
        Logger.error("EventStoreDB append failed",
          stream: stream_id,
          error: inspect(reason),
          orkestra: :event_store
        )

        {:error, reason}
    end
  end

  # ── Private ─────────────────────────────────────────────────────

  defp to_stored_event(%Spear.Event{} = event) do
    %{
      id: event.id,
      type: event.type,
      data: event.body,
      metadata: extract_custom_metadata(event),
      stream_revision: event.metadata.stream_revision
    }
  end

  defp extract_custom_metadata(%Spear.Event{metadata: %{custom_metadata: meta}})
       when is_map(meta),
       do: meta

  defp extract_custom_metadata(_), do: %{}

  defp extract_revision(response) do
    case response do
      %{current_revision: rev} when is_integer(rev) -> rev
      _ -> -1
    end
  end
end
