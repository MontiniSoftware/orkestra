defmodule Orkestra.Projector.GenServerResubscribeTest do
  @moduledoc """
  Connection-free tests for the resilient subscribe / re-subscribe path of
  `Orkestra.Projector.GenServer` (0.2.3).

  No EventStoreDB and no Postgres are required: a fake repo returns `nil` for the
  checkpoint (so the projector subscribes from -1) and a fake event store drives
  the `{:error, reason}` / relay-death paths deterministically.

  Regression target: with EventStoreDB unreachable, `subscribe_from_position/3`
  returns `{:error, :closed}`. The pre-0.2.3 hard match `{:ok, ref} = ...` raised
  a MatchError and crash-looped the projector until the host supervisor's restart
  intensity was exceeded and the whole application exited. The projector must now
  stay alive, retry with backoff, and subscribe once the store returns — WITHOUT
  consuming the `max_retries` (dead-letter/poison-event) budget.
  """

  use ExUnit.Case, async: false

  alias Orkestra.Projector.GenServer, as: ProjectorGenServer

  # A repo stub with no checkpoint row → the projector subscribes from -1.
  defmodule NoCheckpointRepo do
    def get_by(_schema, _clauses), do: nil
    def transaction(_multi), do: {:ok, %{}}
  end

  # Storage adapter stub — never exercised (no events are delivered here). It must
  # NOT export init/1 so init/1 sends :load_checkpoint straight away.
  defmodule NoopStorage do
    def write(_name, _event, _position, _opts), do: {:ok, Ecto.Multi.new()}
  end

  # Event store that fails `subscribe_from_position/3` the first `fail_times`
  # calls (simulating a down connection), then succeeds returning a plain
  # reference (InMemory-style handle → not monitored).
  defmodule FlakyEventStore do
    use Agent

    def start_link(fail_times) do
      Agent.start_link(fn -> %{remaining: fail_times, calls: 0} end, name: __MODULE__)
    end

    def calls, do: Agent.get(__MODULE__, & &1.calls)

    def subscribe_from_position(_all, _from, _subscriber) do
      Agent.get_and_update(__MODULE__, fn s ->
        s = %{s | calls: s.calls + 1}

        if s.remaining > 0 do
          {{:error, :closed}, %{s | remaining: s.remaining - 1}}
        else
          {{:ok, make_ref()}, s}
        end
      end)
    end

    def unsubscribe(_ref), do: :ok
  end

  # Event store that always succeeds, returning a fresh spawned PID (relay-style
  # handle → monitored by the projector). Records every handle so the test can
  # kill the "relay" and assert re-subscription.
  defmodule PidEventStore do
    use Agent

    def start_link(_ \\ nil) do
      Agent.start_link(fn -> %{calls: 0, last_pid: nil} end, name: __MODULE__)
    end

    def calls, do: Agent.get(__MODULE__, & &1.calls)
    def last_pid, do: Agent.get(__MODULE__, & &1.last_pid)

    def subscribe_from_position(_all, _from, _subscriber) do
      relay = spawn(fn -> Process.sleep(:infinity) end)

      Agent.update(__MODULE__, fn s -> %{s | calls: s.calls + 1, last_pid: relay} end)

      {:ok, relay}
    end

    def unsubscribe(_ref), do: :ok
  end

  # Fast backoff so the retry loop resolves within the test timeout.
  @fast_lifecycle %{max_retries: 2, backoff_base_ms: 5, backoff_cap_ms: 20}

  defp config(event_store) do
    %{
      repo: NoCheckpointRepo,
      projector_name: "resub_#{:erlang.unique_integer([:positive])}",
      storage_adapter: NoopStorage,
      event_store: event_store,
      lifecycle_config: @fast_lifecycle,
      adapter_opts: []
    }
  end

  defp wait_until(max_ms \\ 2_000, fun) do
    deadline = System.monotonic_time(:millisecond) + max_ms
    poll(deadline, fun)
  end

  defp poll(deadline, fun) do
    cond do
      fun.() ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        {:error, :timeout}

      true ->
        Process.sleep(5)
        poll(deadline, fun)
    end
  end

  test "subscribe failure ({:error, :closed}) retries with backoff and eventually subscribes; the projector never crashes" do
    {:ok, _} = start_supervised({FlakyEventStore, 3})

    pid = start_supervised!({ProjectorGenServer, config(FlakyEventStore)})

    # It stayed alive through the failing subscribes...
    assert Process.alive?(pid)

    # ...and eventually subscribed (4 calls: 3 failures + 1 success).
    assert :ok = wait_until(fn -> FlakyEventStore.calls() == 4 end)

    state = :sys.get_state(pid)
    assert state.subscription_ref != nil, "expected a live subscription handle after recovery"
    # subscribe_attempts is reset to 0 once the subscribe succeeds.
    assert state.subscribe_attempts == 0
    # CRUCIAL: the event/dead-letter retry budget was untouched by the outage.
    assert state.attempts == 0
    refute state.halted

    assert Process.alive?(pid)
  end

  test "a relay that dies after a successful subscribe (dropped connection) is detected and re-subscribed; the projector is not left deaf" do
    {:ok, _} = start_supervised(PidEventStore)

    pid = start_supervised!({ProjectorGenServer, config(PidEventStore)})

    assert :ok = wait_until(fn -> PidEventStore.calls() == 1 end)

    state = :sys.get_state(pid)
    relay = state.subscription_ref
    assert is_pid(relay)
    assert state.subscription_monitor_ref != nil, "relay must be monitored"

    # Simulate the Spear connection dropping after a successful subscribe: the
    # relay process exits. Pre-0.2.3 the projector held the dead pid and went
    # deaf forever; now it must notice (monitor) and re-subscribe.
    Process.exit(relay, :kill)

    assert :ok = wait_until(fn -> PidEventStore.calls() == 2 end)

    assert Process.alive?(pid)
    new_state = :sys.get_state(pid)
    assert is_pid(new_state.subscription_ref)
    assert new_state.subscription_ref != relay
    assert new_state.attempts == 0
  end
end
