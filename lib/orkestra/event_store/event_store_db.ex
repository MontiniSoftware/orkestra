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

  @doc """
  Subscribes `subscriber` to receive events from `stream_id_or_all` starting
  after `from_position` (exclusive).

  Delegates to `Spear.subscribe/4` with `from: from_position`. Spear's `from:`
  parameter is exclusive — it delivers events with position > `from_position`,
  matching the D-01 monotonic-integer contract and InMemory's semantics.

  The `subscriber` process will receive `Spear.Event.t()` messages. Use
  `global_position_from_spear_event/1` to extract the `:global_position` integer
  (mapped from `commit_position`) for checkpoint updates.

  > **Phase 2 note:** The live `$all` exclusive `from:` semantics and the
  > `commit_position` integer mapping (RESEARCH.md A4/A5 — Open Question 1) are
  > verified against a live EventStoreDB instance in Phase 2 integration tests.
  > The Phase 1 test is compile/wiring-level only.

  Returns `{:ok, subscription_ref}` on success or `{:error, exception}` on failure.
  """
  @spec subscribe_from_position(
          Orkestra.EventStore.stream_id() | :all,
          integer(),
          pid()
        ) :: {:ok, reference()} | {:error, term()}
  @impl true
  def subscribe_from_position(stream_id_or_all, from_position, subscriber) do
    Spear.subscribe(@connection, subscriber, stream_id_or_all, from: from_position)
  rescue
    e ->
      Logger.error("EventStoreDB subscribe failed",
        stream: inspect(stream_id_or_all),
        from: from_position,
        error: Exception.message(e),
        orkestra: :event_store
      )

      {:error, e}
  end

  # ── Private ─────────────────────────────────────────────────────

  # Extracts the commit_position from a Spear.Event and surfaces it as the
  # adapter-agnostic :global_position integer (D-01).
  #
  # NOTE: `commit_position` is used directly as the monotonic integer per D-01.
  # For :all stream subscriptions where `prepare_position != commit_position`,
  # the Spear docs recommend using `Spear.Event.to_checkpoint/1` for idempotent
  # position tracking. Whether `from: commit_position_integer` works directly
  # or requires a checkpoint struct for :all subscriptions in all EventStoreDB
  # versions is verified against a live EventStoreDB in Phase 2 (RESEARCH.md
  # Open Question 1, Assumptions A4 and A5).
  defp global_position_from_spear_event(%Spear.Event{metadata: meta}) do
    case meta do
      %{commit_position: pos} when is_integer(pos) -> pos
      _ -> nil
    end
  end

  defp to_stored_event(%Spear.Event{} = event) do
    %{
      id: event.id,
      type: event.type,
      data: event.body,
      metadata: extract_custom_metadata(event),
      stream_revision: event.metadata.stream_revision,
      global_position: global_position_from_spear_event(event)
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
