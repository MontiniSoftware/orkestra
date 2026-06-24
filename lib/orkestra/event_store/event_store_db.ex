defmodule Orkestra.EventStore.EventStoreDB do
  @moduledoc """
  EventStoreDB adapter via Spear gRPC client.

  Requires `Spear.Connection` in the supervision tree.

  ## Configuration

      config :orkestra, Orkestra.EventStore.EventStoreDB,
        connection_string: "esdb://localhost:2113?tls=false"
  """

  @behaviour Orkestra.EventStore

  require Logger

  # Spear exposes the gpb-generated EventStoreDB protobuf records as little
  # record macros. We use them to decode the raw `append_resp` returned by
  # `Spear.append/4` with `raw?: true`, so we can read the post-write revision
  # (which the parsed `:ok` return signature does not surface).
  require Spear.Records.Streams, as: Streams

  @connection __MODULE__.Connection

  @impl true
  def load_events(stream_id) do
    # Full-stream load: read from the beginning; the empty-stream revision is -1.
    do_load(stream_id, [direction: :forwards], -1)
  end

  @impl true
  def load_events(stream_id, from_revision) do
    # Incremental load: read after `from_revision` (Spear `from:` is exclusive of
    # the supplied revision when reading forwards); the empty-slice revision is
    # `from_revision` (the caller's current position).
    do_load(stream_id, [direction: :forwards, from: from_revision + 1], from_revision)
  end

  # Shared load body for both `load_events/1` and `load_events/2`. Logs uniformly
  # on non-`:not_found` Spear errors and on the generic rescue (WR-04), so the
  # incremental-load path no longer fails silently.
  defp do_load(stream_id, stream_opts, empty_revision) do
    try do
      events =
        Spear.stream!(@connection, stream_id, stream_opts)
        |> Enum.to_list()

      case events do
        [] ->
          {:ok, [], empty_revision}

        events ->
          stored = Enum.map(events, &to_stored_event/1)
          revision = List.last(events).metadata.stream_revision
          {:ok, stored, revision}
      end
    rescue
      e in Spear.Grpc.Response ->
        if e.status == :not_found do
          {:ok, [], empty_revision}
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
  def append_events(stream_id, events, expected_revision) do
    spear_events =
      Enum.map(events, fn event ->
        # `Spear.Event.new/3` does not accept a `:metadata` option — it accepts
        # `:custom_metadata` (a binary). Serialize the event metadata map to JSON
        # so correlation/causation/actor metadata survives the append (CR-03).
        Spear.Event.new(
          event.type,
          event.data,
          custom_metadata: Jason.encode!(event.metadata)
        )
      end)

    # Keep the input contract identical to the InMemory adapter and the declared
    # `expected_revision()` type (`non_neg_integer() | :any | :no_stream`). We do
    # NOT special-case `-1`: InMemory rejects it (falls to wrong-version), so a
    # bare `-1` would diverge between adapters (WR-06). Use `:no_stream` to assert
    # an empty stream.
    expect =
      case expected_revision do
        :any -> :any
        :no_stream -> :empty
        rev when is_integer(rev) and rev >= 0 -> rev
      end

    case Spear.append(spear_events, @connection, stream_id, expect: expect, raw?: true) do
      {:ok, response} ->
        case extract_revision(response) do
          {:ok, new_revision} ->
            Logger.debug("Events appended",
              stream: stream_id,
              count: length(events),
              revision: new_revision,
              orkestra: :event_store
            )

            {:ok, new_revision}

          {:error, :wrong_expected_version} ->
            Logger.warning("Wrong expected version",
              stream: stream_id,
              expected: expected_revision,
              orkestra: :event_store
            )

            {:error, :wrong_expected_version}

          :error ->
            Logger.error("Unexpected EventStoreDB append response",
              stream: stream_id,
              response: inspect(response),
              orkestra: :event_store
            )

            {:error, {:unexpected_append_response, response}}
        end

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
    base = %{
      id: event.id,
      type: event.type,
      data: event.body,
      metadata: extract_custom_metadata(event),
      stream_revision: event.metadata.stream_revision
    }

    # Only add `:global_position` when a real non-negative position is present.
    # `to_stored_event/1` is shared by plain reads (where `commit_position` may
    # be absent) and subscription delivery. Emitting `global_position: nil` would
    # violate the `stored_event_with_position()` type and break downstream
    # checkpoint arithmetic with an ArithmeticError (WR-05). The plain
    # `stored_event()` type does not include `:global_position`, so omitting it
    # on reads is correct.
    case global_position_from_spear_event(event) do
      pos when is_integer(pos) and pos >= 0 -> Map.put(base, :global_position, pos)
      _ -> base
    end
  end

  # EventStoreDB / Spear surfaces `custom_metadata` as a binary (typically a
  # JSON string), never a map (see deps/spear/lib/spear/event.ex). Decode it
  # back into the metadata map written on append (CR-04).
  defp extract_custom_metadata(%Spear.Event{metadata: %{custom_metadata: bin}})
       when is_binary(bin) and bin != "" do
    case Jason.decode(bin) do
      {:ok, map} when is_map(map) -> map
      _ -> %{}
    end
  end

  defp extract_custom_metadata(_), do: %{}

  # With `raw?: true`, `Spear.append/4` returns `{:ok, append_resp_record}`.
  # The success branch carries the post-write revision in the nested
  # `AppendResp.Success` record's `current_revision_option` oneof; a new stream
  # reports `{:no_stream, _}` (revision -1). A `wrong_expected_version` result
  # is also possible here when Spear is in raw mode. Returns `{:ok, revision}`,
  # `{:error, :wrong_expected_version}`, or `:error` for an unexpected shape
  # (CR-02). Never returns a silent hardcoded -1 on the fall-through.
  defp extract_revision(Streams.append_resp(result: {:success, success})) do
    case Streams.append_resp_success(success, :current_revision_option) do
      {:current_revision, rev} when is_integer(rev) -> {:ok, rev}
      {:no_stream, _} -> {:ok, -1}
      _ -> :error
    end
  end

  defp extract_revision(Streams.append_resp(result: {:wrong_expected_version, _})) do
    {:error, :wrong_expected_version}
  end

  defp extract_revision(_), do: :error
end
