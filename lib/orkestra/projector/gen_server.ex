defmodule Orkestra.Projector.GenServer do
  @moduledoc """
  Runtime GenServer for Orkestra projection subsystem.

  Subscribes to the event store from the persisted checkpoint position, applies
  pushed events strictly sequentially (one per `handle_info` — OTP mailbox
  guarantees in-order, single-consumer processing — PROJ-04), commits the
  read-model write and the checkpoint upsert atomically in a single
  `Ecto.Multi` transaction (STORE-03), retries failed events with exponential
  backoff via `Process.send_after`, and parks exhausted events to dead-letter
  while staying alive in an idle halted state (ERR-04).

  ## Start Configuration

  Pass a map with the following keys when starting the GenServer:

      %{
        repo:             MyApp.OrderProjection.Repo,   # per-projection Ecto.Repo
        projector_name:   "MyApp.OrderProjection",      # unique string identifier
        storage_adapter:  Orkestra.Projection.Storage.Postgres,  # Storage behaviour
        event_store:      Orkestra.EventStore.InMemory,  # EventStore behaviour
        lifecycle_config: %{max_retries: 5, backoff_base_ms: 500, backoff_cap_ms: 30_000},
        adapter_opts:     [handler: &my_handler/3]       # forwarded to storage_adapter.write/4
      }

  An optional `:name` key sets the GenServer registered name.

  ## Deferred Init

  `init/1` does **not** call the Repo directly. Instead it enqueues a
  `:load_checkpoint` message so callers (e.g., tests) can call
  `Ecto.Adapters.SQL.Sandbox.allow/3` after `start_supervised!/1` returns but
  before the GenServer processes its first mailbox message (RESEARCH Pitfall 1).

  ## Halt Behaviour

  A halted projector discards incoming events and stays alive — it never
  returns a `stop` tuple from `handle_info`. This avoids supervisor restart
  loops and keeps the halted status observable via the persisted
  `projection_checkpoints` row.

  ## Step Name Convention

  The GenServer's checkpoint Multi steps are named `:checkpoint`,
  `:halted_checkpoint`, and `:dead_letter`. The injected storage adapter must
  use `:read_model_`-prefixed step names to prevent `Ecto.Multi.append/2` name
  clashes (RESEARCH Pitfall 2).
  """

  use GenServer

  require Logger

  alias Orkestra.Projector.Lifecycle
  alias Orkestra.Projection.{Checkpoint, DeadLetter}

  @typedoc """
  Internal GenServer state.

  All fields except the runtime fields (`subscription_ref`, `attempts`, `halted`)
  are populated from the start config and are immutable for the lifetime of the
  process.
  """
  @type state :: %{
          repo: module(),
          projector_name: String.t(),
          storage_adapter: module(),
          event_store: module(),
          lifecycle_config: Lifecycle.config(),
          adapter_opts: keyword(),
          subscription_ref: reference() | nil,
          attempts: non_neg_integer(),
          halted: boolean()
        }

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @doc """
  Starts the Projector GenServer linked to the calling process.

  `config` must be a map with the keys listed in the module doc. Pass an
  optional `:name` key to register the process under a name.
  """
  @spec start_link(map()) :: GenServer.on_start()
  def start_link(%{} = config) do
    {name_opt, config} = Map.pop(config, :name)
    opts = if name_opt, do: [name: name_opt], else: []
    GenServer.start_link(__MODULE__, config, opts)
  end

  # ---------------------------------------------------------------------------
  # GenServer callbacks
  # ---------------------------------------------------------------------------

  @doc false
  @impl GenServer
  def init(config) do
    state = %{
      repo: Map.fetch!(config, :repo),
      projector_name: Map.fetch!(config, :projector_name),
      storage_adapter: Map.fetch!(config, :storage_adapter),
      event_store: Map.fetch!(config, :event_store),
      lifecycle_config:
        Map.get(config, :lifecycle_config, %{
          max_retries: 5,
          backoff_base_ms: 500,
          backoff_cap_ms: 30_000
        }),
      adapter_opts: Map.get(config, :adapter_opts, []),
      subscription_ref: nil,
      attempts: 0,
      halted: false
    }

    # Defer all Repo calls — enqueue :load_checkpoint so the test can call
    # Sandbox.allow/3 after start_supervised!/1 returns (RESEARCH Pitfall 1).
    send(self(), :load_checkpoint)

    {:ok, state}
  end

  @doc false
  @impl GenServer
  def handle_info(:load_checkpoint, state) do
    %{repo: repo, projector_name: projector_name, event_store: event_store} = state

    case repo.get_by(Checkpoint, projector_name: projector_name) do
      nil ->
        # No checkpoint yet — replay from the beginning (position -1 → exclusive > gives 0+)
        {:ok, ref} = event_store.subscribe_from_position(:all, -1, self())

        Logger.info("Projector subscribed (no prior checkpoint)",
          projector: projector_name,
          last_position: -1,
          orkestra: :projector
        )

        {:noreply, %{state | subscription_ref: ref, halted: false}}

      %Checkpoint{halted: true} = checkpoint ->
        # Projector was halted — do NOT subscribe; stay idle until resolved
        Logger.warning("Projector started in halted state — discarding events until resolved",
          projector: projector_name,
          last_position: checkpoint.last_position,
          orkestra: :projector
        )

        {:noreply, %{state | halted: true}}

      %Checkpoint{last_position: last_position} ->
        # Resume from checkpoint (exclusive > semantics — D-01)
        {:ok, ref} = event_store.subscribe_from_position(:all, last_position, self())

        Logger.info("Projector subscribed (resuming from checkpoint)",
          projector: projector_name,
          last_position: last_position,
          orkestra: :projector
        )

        {:noreply, %{state | subscription_ref: ref, halted: false}}
    end
  end

  # Discard events when halted — log and return without touching the Repo
  @doc false
  @impl GenServer
  def handle_info(%{global_position: position} = _event, %{halted: true} = state) do
    Logger.warning("Projector is halted — discarding event",
      projector: state.projector_name,
      position: position,
      orkestra: :projector
    )

    {:noreply, state}
  end

  # Normal event processing
  @doc false
  @impl GenServer
  def handle_info(%{global_position: _} = event, state) do
    apply_event(event, state)
  end

  # Retry: re-attempt the same event after a scheduled delay
  @doc false
  @impl GenServer
  def handle_info({:retry_event, event}, state) do
    apply_event(event, state)
  end

  @doc false
  @impl GenServer
  def terminate(_reason, %{event_store: event_store, subscription_ref: ref})
      when is_reference(ref) do
    # Clean up the subscription if the adapter exports unsubscribe/1
    if function_exported?(event_store, :unsubscribe, 1) do
      event_store.unsubscribe(ref)
    end

    :ok
  end

  def terminate(_reason, _state), do: :ok

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  # Core event-application logic (shared by normal delivery and retry)
  defp apply_event(event, state) do
    %{
      repo: repo,
      projector_name: projector_name,
      storage_adapter: storage_adapter,
      adapter_opts: adapter_opts
    } = state

    position = event.global_position

    case storage_adapter.write(projector_name, event, position, adapter_opts) do
      {:ok, read_model_multi} ->
        now = DateTime.utc_now()

        checkpoint = %Checkpoint{
          projector_name: projector_name,
          last_position: position,
          halted: false,
          updated_at: now
        }

        checkpoint_multi =
          Ecto.Multi.new()
          |> Ecto.Multi.insert(:checkpoint, checkpoint,
            on_conflict: [set: [last_position: position, halted: false, updated_at: now]],
            conflict_target: :projector_name
          )

        # Read-model Multi first, checkpoint second — argument order matters (RESEARCH Pitfall 3)
        combined = Ecto.Multi.append(read_model_multi, checkpoint_multi)

        case repo.transaction(combined) do
          {:ok, _changes} ->
            Logger.debug("Projector applied event",
              projector: projector_name,
              position: position,
              orkestra: :projector
            )

            {:noreply, %{state | attempts: 0}}

          {:error, step, reason, _changes} ->
            Logger.warning("Projector event commit failed",
              projector: projector_name,
              position: position,
              step: step,
              reason: inspect(reason),
              orkestra: :projector
            )

            handle_failure(event, {step, reason}, state)
        end

      {:error, reason} ->
        Logger.warning("Projector storage_adapter.write/4 failed",
          projector: projector_name,
          position: position,
          reason: inspect(reason),
          orkestra: :projector
        )

        handle_failure(event, reason, state)
    end
  end

  # Decides whether to retry (with backoff) or park-and-halt
  defp handle_failure(event, reason, state) do
    new_attempts = state.attempts + 1

    case Lifecycle.classify(new_attempts, state.lifecycle_config) do
      :retry ->
        delay = Lifecycle.next_delay(new_attempts, state.lifecycle_config)

        Logger.warning("Projector scheduling retry",
          projector: state.projector_name,
          position: event.global_position,
          attempts: new_attempts,
          delay_ms: delay,
          orkestra: :projector
        )

        Process.send_after(self(), {:retry_event, event}, delay)
        {:noreply, %{state | attempts: new_attempts}}

      :park ->
        park_and_halt(event, reason, new_attempts, state)
    end
  end

  # Atomically writes the dead_letter row + halted checkpoint in one transaction,
  # then transitions the GenServer to idle halted state (no stop tuple — stays alive)
  defp park_and_halt(event, reason, attempts, state) do
    %{repo: repo, projector_name: projector_name} = state
    now = DateTime.utc_now()

    dead_letter = %DeadLetter{
      projector_name: projector_name,
      position: event.global_position,
      event_data: event,
      error: inspect(reason),
      attempts: attempts,
      occurred_at: now
    }

    # Do NOT advance last_position past the failing event so that on a future
    # restart (after the dead-letter is resolved) the event will be re-attempted.
    halted_checkpoint = %Checkpoint{
      projector_name: projector_name,
      last_position: event.global_position,
      halted: true,
      halted_at: now
    }

    halt_multi =
      Ecto.Multi.new()
      |> Ecto.Multi.insert(:dead_letter, dead_letter)
      |> Ecto.Multi.insert(:halted_checkpoint, halted_checkpoint,
        on_conflict: [
          set: [
            halted: true,
            halted_at: now,
            last_position: event.global_position,
            updated_at: now
          ]
        ],
        conflict_target: :projector_name
      )

    case repo.transaction(halt_multi) do
      {:ok, _} ->
        Logger.error("Projector halted after exhausting retries",
          projector: projector_name,
          position: event.global_position,
          attempts: attempts,
          reason: inspect(reason),
          orkestra: :projector
        )

      {:error, step, db_reason, _} ->
        Logger.error("Projector failed to persist halt — staying halted",
          projector: projector_name,
          position: event.global_position,
          step: step,
          db_reason: inspect(db_reason),
          orkestra: :projector
        )
    end

    # Always transition to halted state — a DB failure persisting the halt is
    # still a severe condition; stay alive to avoid supervisor restart loops
    # (plan prohibitions; no stop tuple).
    {:noreply, %{state | halted: true, attempts: 0}}
  end
end
