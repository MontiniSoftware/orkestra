defmodule Orkestra.EventStore.EventStoreDB.SubscriptionRelay do
  @moduledoc """
  A per-subscription relay process that adapts Spear's raw subscription delivery
  to the `Orkestra.EventStore` subscriber contract.

  `Spear.subscribe/4` pushes `t:Spear.Event.t/0` structs (plus
  `t:Spear.Filter.Checkpoint.t/0`, `{:caught_up, ref}`, `{:fell_behind, ref}`
  and `{:eos, ref, reason}` control messages) directly to the subscribing
  process. The Orkestra projector, however, is written against a single
  delivery contract shared with `Orkestra.EventStore.InMemory`: it receives
  **only** `t:Orkestra.EventStore.stored_event_with_position/0` maps (maps
  carrying a `:global_position` key) and has no `handle_info/2` clause for
  Spear's control structs — an unmatched `%Spear.Filter.Checkpoint{}` would
  crash it.

  This relay closes that gap. It becomes the Spear subscriber, and for each
  message it receives it:

    * transforms a `%Spear.Event{}` into a `stored_event_with_position()` map
      (via `Orkestra.EventStore.EventStoreDB.to_stored_event/1`, the *same*
      mapping used by `load_events/1,2`) and forwards it to the real
      subscriber — so the projector sees exactly the shape InMemory delivers;
    * silently drops every Spear control message (checkpoints, caught_up,
      fell_behind) — they carry no domain event;
    * stops (cancelling the underlying Spear subscription) when it receives an
      `{:eos, _, reason}` end-of-stream, or when the real subscriber dies (it
      `Process.monitor/1`s the subscriber), so no subscription is leaked.

  ## Subscription options (link-event de-duplication)

  For an `:all` subscription the relay passes `resolve_links?: false` and
  `filter: Spear.Filter.exclude_system_events()` to `Spear.subscribe/4`. With
  EventStoreDB standard projections enabled, an event is also surfaced through
  system link streams (`$ce-*`, `$et-*`) that share the original event's
  `commit_position`; `resolve_links?: true` (Spear's default) would therefore
  deliver the same event several times, inflating checkpoints and causing
  re-processing. Disabling link resolution and excluding `$`-prefixed system
  streams delivers each event exactly once.

  Note that orkestra's own `snapshot-<stream>` streams do **not** start with
  `$`, so their events still reach an `:all` subscriber. That is intentional:
  the projector's handler is expected to ignore event types it does not
  recognise (advancing the checkpoint without dead-lettering them).
  """

  require Logger

  alias Orkestra.EventStore.EventStoreDB

  @doc """
  Starts a relay linking a Spear subscription on `connection` to `subscriber`.

  Returns `{:ok, relay_pid}` once the Spear subscription is confirmed, or
  `{:error, reason}` if `Spear.subscribe/4` fails. The returned pid is the
  opaque subscription handle: pass it to
  `Orkestra.EventStore.EventStoreDB.unsubscribe/1` to tear the subscription
  down (this is also done automatically when `subscriber` dies).
  """
  @spec start(Spear.Connection.t(), Orkestra.EventStore.stream_id() | :all, term(), pid()) ::
          {:ok, pid()} | {:error, term()}
  def start(connection, stream_id_or_all, from, subscriber) do
    parent = self()
    ref = make_ref()

    pid =
      spawn(fn ->
        init(connection, stream_id_or_all, from, subscriber, parent, ref)
      end)

    # Wait for the relay to confirm (or fail) the Spear subscription before
    # returning, so the caller gets a definitive {:ok, _}/{:error, _} — and so
    # the subscription is live before the caller starts appending events.
    receive do
      {^ref, :ok} -> {:ok, pid}
      {^ref, {:error, reason}} -> {:error, reason}
    after
      10_000 -> {:error, :subscribe_timeout}
    end
  end

  @doc """
  Cancels the relay's Spear subscription and stops the relay process.

  Idempotent and safe to call with a dead pid.
  """
  @spec stop(pid()) :: :ok
  def stop(pid) when is_pid(pid) do
    if Process.alive?(pid), do: send(pid, :orkestra_unsubscribe)
    :ok
  end

  def stop(_), do: :ok

  # ── Private ─────────────────────────────────────────────────────

  defp init(connection, stream_id_or_all, from, subscriber, parent, ref) do
    monitor_ref = Process.monitor(subscriber)

    opts = subscribe_opts(stream_id_or_all, from)

    case Spear.subscribe(connection, self(), stream_id_or_all, opts) do
      {:ok, sub_ref} ->
        send(parent, {ref, :ok})
        loop(connection, subscriber, sub_ref, monitor_ref)

      {:error, reason} ->
        send(parent, {ref, {:error, reason}})
        :ok
    end
  end

  # `:all` supports a server-side filter; a named stream does not (Spear rejects
  # a `:filter` on a non-`:all` subscription). Link resolution is disabled in
  # both cases — orkestra never relies on link events.
  defp subscribe_opts(:all, from) do
    [from: from, resolve_links?: false, filter: Spear.Filter.exclude_system_events()]
  end

  defp subscribe_opts(_stream, from) do
    [from: from, resolve_links?: false]
  end

  defp loop(connection, subscriber, sub_ref, monitor_ref) do
    receive do
      %Spear.Event{} = event ->
        forward(event, subscriber)
        loop(connection, subscriber, sub_ref, monitor_ref)

      # Spear control messages — carry no domain event; drop them so they never
      # reach (and crash) the projector.
      %Spear.Filter.Checkpoint{} ->
        loop(connection, subscriber, sub_ref, monitor_ref)

      {:caught_up, _} ->
        loop(connection, subscriber, sub_ref, monitor_ref)

      {:fell_behind, _} ->
        loop(connection, subscriber, sub_ref, monitor_ref)

      {:eos, _sub, reason} ->
        Logger.warning("EventStoreDB subscription ended",
          reason: inspect(reason),
          orkestra: :event_store
        )

        # Best-effort cancel (the server may already have dropped it).
        Spear.cancel_subscription(connection, sub_ref)
        :ok

      {:DOWN, ^monitor_ref, :process, ^subscriber, _reason} ->
        # Subscriber gone — tear the subscription down so it is not leaked.
        Spear.cancel_subscription(connection, sub_ref)
        :ok

      :orkestra_unsubscribe ->
        Spear.cancel_subscription(connection, sub_ref)
        :ok

      _other ->
        loop(connection, subscriber, sub_ref, monitor_ref)
    end
  end

  # Transform to the InMemory-parity map and forward. Only events that carry a
  # real `:global_position` are forwarded; anything without one (which should
  # not occur on an `:all` feed) is dropped with a warning rather than sent as a
  # shape the projector cannot match.
  defp forward(%Spear.Event{} = event, subscriber) do
    case EventStoreDB.to_stored_event(event) do
      %{global_position: _} = stored ->
        send(subscriber, stored)

      _ ->
        Logger.warning("Dropping EventStoreDB event without a global position",
          type: event.type,
          orkestra: :event_store
        )
    end
  end
end
