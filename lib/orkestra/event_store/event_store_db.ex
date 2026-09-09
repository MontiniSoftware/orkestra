defmodule Orkestra.EventStore.EventStoreDB do
  @moduledoc """
  EventStoreDB adapter via Spear gRPC client.

  Requires `Spear.Connection` in the supervision tree.

  ## Configuration

      config :orkestra, Orkestra.EventStore.EventStoreDB,
        connection_string: "esdb://localhost:2113?tls=false"
  """

  @behaviour Orkestra.EventStore

  alias Orkestra.EventStore.EventStoreDB.SubscriptionRelay

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

    expect = map_expected_revision(expected_revision)

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

  The `from_position` is translated by `map_subscribe_from/2` (see there for the
  full mapping and rationale):

    * `-1` / `nil` → `:start` (replay from the beginning, exactly once).
    * `:all` + a non-negative commit_position → a `%Spear.Filter.Checkpoint{}`
      (a raw integer cannot be used for `:all` — Spear would raise
      `FunctionClauseError` in `map_all_position/1`).
    * a named stream + a non-negative revision → the integer revision.

  All non-`:start` forms are **exclusive** in Spear: `from: N` delivers only
  events strictly after `N`, matching the D-01 monotonic contract, InMemory's
  semantics, and the exactly-once projector — resuming from a saved checkpoint
  never re-delivers the event at that checkpoint, so no manual skip is required.

  ## Delivery shape (parity with InMemory)

  Delivery does **not** hand `subscriber` the raw `%Spear.Event{}` structs that
  `Spear.subscribe/4` pushes. Instead a
  `Orkestra.EventStore.EventStoreDB.SubscriptionRelay` process sits between
  Spear and `subscriber` and delivers `stored_event_with_position()` maps —
  `%{id, type, data, metadata, stream_revision, global_position}`, the same
  shape produced by `load_events/1,2` and the same shape delivered by
  `Orkestra.EventStore.InMemory`. That is exactly what
  `Orkestra.Projector.GenServer.handle_info/2` pattern-matches on
  (`%{global_position: _}`); handed raw Spear structs it would match nothing.
  The relay also drops Spear's control messages (`%Spear.Filter.Checkpoint{}`,
  `{:caught_up, _}`, `{:fell_behind, _}`) which the projector has no clause for,
  and applies the link-de-duplication subscription options (see the relay
  moduledoc).

  The returned handle is the **relay pid** (an opaque subscription handle, not a
  `Spear` reference). Pass it to `unsubscribe/1` to tear the subscription down;
  it is also torn down automatically when `subscriber` dies.

  Returns `{:ok, subscription_handle}` on success or `{:error, reason}` on
  failure.
  """
  @spec subscribe_from_position(
          Orkestra.EventStore.stream_id() | :all,
          integer(),
          pid()
        ) :: {:ok, pid()} | {:error, term()}
  @impl true
  def subscribe_from_position(stream_id_or_all, from_position, subscriber) do
    from = map_subscribe_from(stream_id_or_all, from_position)
    SubscriptionRelay.start(@connection, stream_id_or_all, from, subscriber)
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

  @doc """
  Cancels the subscription identified by `handle` (the relay pid returned by
  `subscribe_from_position/3`) and stops delivery.

  Idempotent: returns `:ok` whether or not the relay is still alive. The
  `Orkestra.Projector.GenServer` calls this on rebuild (to resubscribe from a
  reset checkpoint) and it is a no-op-safe cleanup path; on normal projector
  termination the relay tears itself down via its subscriber monitor, so an
  explicit call is not required there.
  """
  @spec unsubscribe(pid()) :: :ok
  def unsubscribe(handle), do: SubscriptionRelay.stop(handle)

  # ── Private ─────────────────────────────────────────────────────

  @doc false
  # Maps the adapter-agnostic `expected_revision()` to Spear's `:expect` value.
  #
  # `:no_stream` and the empty-stream head revision `-1` both assert an empty
  # stream, which Spear expresses as `:empty`. Mapping `-1 -> :empty` keeps
  # parity with the InMemory adapter *and* with `Orkestra.Aggregate.Root`, which
  # loads an empty stream as revision `-1` (see `load_events/1`) and passes that
  # value straight into `append_events/3` on first write. InMemory accepts `-1`
  # for an empty stream because the current revision of an empty stream is `-1`,
  # so its `expected_revision == current_revision` branch matches; the previous
  # comment here claiming "InMemory rejects it" was factually wrong and caused a
  # `CaseClauseError` on new-stream appends against real EventStoreDB.
  def map_expected_revision(:any), do: :any
  def map_expected_revision(:no_stream), do: :empty
  def map_expected_revision(-1), do: :empty
  def map_expected_revision(rev) when is_integer(rev) and rev >= 0, do: rev

  @doc false
  # Maps the adapter-agnostic `from_position` to Spear's `:from` option.
  #
  # Spear `from:` semantics (deps/spear/lib/spear.ex, `subscribe/4` docs, and
  # deps/spear/lib/spear/reading.ex `map_all_position/1` / `map_stream_revision/1`):
  #   * `:start` / `:end` are INCLUSIVE (`:start` returns the first event).
  #   * a plain integer is an EXCLUSIVE *stream revision* — valid only for a
  #     named stream, NOT for `:all` (`map_all_position/1` has no integer clause,
  #     so `from: <int>` on `:all` raises FunctionClauseError).
  #   * a `%Spear.Event{}` or `%Spear.Filter.Checkpoint{}` is EXCLUSIVE.
  #
  # This exclusivity is exactly the orkestra contract for `subscribe_from_position/3`:
  # resuming from position N must NOT re-deliver the event at N (the Postgres-backed
  # projector is exactly-once). So no manual skip is needed.
  #
  # `-1` (and `nil`) is the initial "no checkpoint" position → `:start`, which
  # replays every event from the beginning exactly once.
  #
  # A `$all` position is a `(commit_position, prepare_position)` pair; the orkestra
  # checkpoint only carries the commit_position (surfaced as `:global_position`),
  # so on resume we build a `%Spear.Filter.Checkpoint{}` using it for both fields.
  # This is exact for orkestra's single-event-per-append `$all` positions; see the
  # note on `global_position_from_spear_event/1` for the multi-event caveat.
  def map_subscribe_from(_stream, position) when position in [nil, -1], do: :start

  def map_subscribe_from(:all, position) when is_integer(position) and position >= 0 do
    %Spear.Filter.Checkpoint{commit_position: position, prepare_position: position}
  end

  def map_subscribe_from(_stream, position) when is_integer(position) and position >= 0 do
    position
  end

  # Extracts the commit_position from a Spear.Event and surfaces it as the
  # adapter-agnostic :global_position integer (D-01).
  #
  # WHY commit_position is a correct single-integer position on EventStoreDB
  # 24.10 (including the multi-event-append / resume case):
  #
  # A `$all` position is conceptually a `(commit_position, prepare_position)`
  # pair, and `$all` is ordered by that pair lexicographically. The concern
  # (classic on older ESDB log formats) is that a single atomic
  # `append_events/3` carrying MULTIPLE events (e.g. Aggregate.Root emitting
  # `[InviteAccepted, MemberJoined]` in one decide) writes them under ONE shared
  # commit_position with distinct prepare_positions; if only commit_position is
  # checkpointed, a crash between the two intra-commit events could skip the
  # second on resume (exclusive `from: {commit, commit}` would not re-deliver a
  # prepare < commit).
  #
  # This was verified empirically against a live `eventstore/eventstore:24.10.0`
  # (insecure, MEM_DB, RUN_PROJECTIONS=None): appending two events in a single
  # `Spear.append/4` call yields, on the `$all` feed, TWO DISTINCT
  # commit_positions (e.g. 1167 and 1288), and for every event
  # `commit_position == prepare_position`. In other words 24.10 assigns each
  # record its own unique, strictly-monotonic log position and reports it as
  # both fields. Consequently:
  #
  #   * commit_position is unique per event (no intra-commit collision), so it is
  #     a valid gap-containing-but-monotonic `:global_position` and a valid
  #     unique key for the projector's `(projector_name, position)` read-model
  #     index; and
  #   * resuming with `%Spear.Filter.Checkpoint{commit: P, prepare: P}` is EXACT
  #     — since the boundary event has commit == prepare == P, exclusive `>`
  #     delivers strictly the events after it, with neither loss nor duplication.
  #
  # The single-integer checkpoint schema is therefore correct for 24.10 and no
  # schema change (storing both positions) is needed. The intra-commit
  # multi-event + mid-restart resume path is covered by an acceptance test
  # (test/integration/projector_event_store_db_test.exs). CAVEAT: on a
  # hypothetical ESDB configuration that DID share one commit_position across an
  # atomic multi-event append, this resume could skip intra-commit events; that
  # regime is not produced by 24.10 as used here.
  defp global_position_from_spear_event(%Spear.Event{metadata: meta}) do
    case meta do
      %{commit_position: pos} when is_integer(pos) -> pos
      _ -> nil
    end
  end

  @doc false
  # Maps a `%Spear.Event{}` (as read or delivered by Spear) to the
  # adapter-agnostic stored-event map. Shared by `load_events/1,2` (plain reads,
  # where `commit_position` may be absent → no `:global_position` key) and by
  # `SubscriptionRelay` (subscription delivery, where `$all` events always carry
  # a `commit_position` → the map is a `stored_event_with_position()`). Public
  # (`@doc false`) so the relay and connection-free unit tests can exercise the
  # transformation directly.
  def to_stored_event(%Spear.Event{} = event) do
    base =
      %{
        id: event.id,
        type: event.type,
        # Spear decodes the JSON body into a STRING-keyed map. Normalize the
        # first-level keys back to the event struct's atom fields so this adapter
        # delivers the same atom-keyed `:data` the InMemory adapter does (the
        # projector and `Aggregate.Root.evolve/2` read `event.data.field` via
        # atoms). Unknown/foreign event types keep their string keys (see
        # `Orkestra.Event.atomize_data/2`); nested values are left untouched.
        data: Orkestra.Event.atomize_data(event.type, event.body),
        metadata: extract_custom_metadata(event),
        stream_revision: event.metadata.stream_revision
      }
      |> put_stream_id(event)

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

  # Adds `:stream_id` (the originating stream) to the stored-event map when Spear
  # surfaces it (`metadata.stream_name`, present on read/subscription events).
  # This mirrors the InMemory adapter, which stamps `:stream_id` on every stored
  # event — keeping the delivered/loaded shape at parity across adapters so
  # consumers can filter by stream. Reads before/without a stream_name simply
  # omit the key.
  defp put_stream_id(base, %Spear.Event{metadata: %{stream_name: name}}) when is_binary(name),
    do: Map.put(base, :stream_id, name)

  defp put_stream_id(base, _event), do: base

  # EventStoreDB / Spear surfaces `custom_metadata` as a binary (typically a
  # JSON string), never a map (see deps/spear/lib/spear/event.ex). Decode it
  # back into the metadata map written on append (CR-04).
  defp extract_custom_metadata(%Spear.Event{metadata: %{custom_metadata: bin}})
       when is_binary(bin) and bin != "" do
    case Jason.decode(bin) do
      # Normalize the JSON-decoded (string-keyed) metadata's first-level known
      # keys back to the `%Orkestra.Metadata{}` atom fields, at parity with the
      # atom-keyed known fields a caller reads on the InMemory adapter. Custom
      # (non-Metadata) keys and all values stay as decoded.
      {:ok, map} when is_map(map) -> Orkestra.Metadata.normalize_map(map)
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
