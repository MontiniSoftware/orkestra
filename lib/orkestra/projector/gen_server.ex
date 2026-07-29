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
  require OpenTelemetry.Tracer, as: Tracer

  alias Orkestra.Projector.Lifecycle
  alias Orkestra.Telemetry, as: OTel
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
          halted: boolean(),
          writes_paused: boolean(),
          last_seen_position: non_neg_integer() | nil,
          rebuild_total: non_neg_integer() | nil,
          rebuild_events_replayed: non_neg_integer(),
          es_buffer: list(),
          es_batch_size: non_neg_integer(),
          es_mode: :live | :catching_up
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
      halted: false,
      writes_paused: false,
      last_seen_position: nil,
      rebuild_total: Map.get(config, :rebuild_total, nil),
      rebuild_events_replayed: 0,
      es_buffer: [],
      es_batch_size: Map.get(config, :es_batch_size, 500),
      es_mode: if(Map.get(config, :rebuild_total), do: :catching_up, else: :live)
    }

    # Defer all Repo/HTTP calls. If the storage adapter exports init/1
    # (e.g. Storage.Elasticsearch), send :init_adapter first so it can perform
    # engine detection and index creation before the checkpoint is loaded.
    # This preserves the Sandbox.allow/3 window for tests (RESEARCH Pitfall 1).
    #
    # `Code.ensure_loaded?/1` is required: `function_exported?/3` returns false
    # for a not-yet-loaded module (and does not force-load it). In dev/test,
    # lazy module loading means the storage adapter may be unloaded at projector
    # start, which would silently skip adapter init — leaving an ES read model
    # to land in an auto-created plain index instead of the schema's alias +
    # versioned index (a real bug surfaced by the integration suite).
    storage_adapter = Map.fetch!(config, :storage_adapter)

    if Code.ensure_loaded?(storage_adapter) and function_exported?(storage_adapter, :init, 1) do
      send(self(), :init_adapter)
    else
      send(self(), :load_checkpoint)
    end

    {:ok, state}
  end

  @doc false
  @impl GenServer
  def handle_call(:pause_writes, _from, state) do
    Logger.info("Projector writes paused for rebuild",
      projector: state.projector_name,
      orkestra: :projector
    )

    {:reply, :ok, %{state | writes_paused: true}}
  end

  @doc false
  @impl GenServer
  def handle_call(:resume_writes, _from, state) do
    # Unsubscribe from the old subscription if active (RBLD-03)
    if state.subscription_ref && function_exported?(state.event_store, :unsubscribe, 1) do
      state.event_store.unsubscribe(state.subscription_ref)
    end

    Logger.info("Projector writes resumed — resubscribing from checkpoint",
      projector: state.projector_name,
      orkestra: :projector
    )

    # Trigger checkpoint reload which will resubscribe from the current
    # (reset) checkpoint position. The Mix task resets the checkpoint to -1
    # before calling :resume_writes, so the GenServer replays from 0.
    send(self(), :load_checkpoint)

    {:reply, :ok,
     %{state | writes_paused: false, subscription_ref: nil, es_buffer: [], es_mode: :live}}
  end

  @doc false
  @impl GenServer
  def handle_info(:init_adapter, state) do
    case state.storage_adapter.init(state.adapter_opts) do
      {:ok, %{engine: engine}} ->
        # Write detected engine back into adapter_opts so that commit_es_single_doc
        # and flush_es_buffer use the correct engine atom in OTel spans (T-08-03).
        new_adapter_opts = Keyword.put(state.adapter_opts, :engine, engine)
        send(self(), :load_checkpoint)
        {:noreply, %{state | adapter_opts: new_adapter_opts}}

      {:ok, _adapter_state} ->
        # init/1 succeeded but returned no engine — proceed without engine update
        send(self(), :load_checkpoint)
        {:noreply, state}

      {:error, reason} ->
        # Do NOT log adapter_opts (credential risk T-08-02)
        Logger.error("Projector adapter init failed",
          projector: state.projector_name,
          reason: inspect(reason),
          orkestra: :projector
        )

        {:stop, {:adapter_init_failed, reason}, state}
    end
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

    {:noreply, %{state | last_seen_position: position}}
  end

  # Discard events when writes are paused for rebuild (RBLD-03).
  # Events accumulate in the mailbox but are not processed. After resume,
  # the GenServer resubscribes from the reset checkpoint and replays everything.
  @doc false
  @impl GenServer
  def handle_info(%{global_position: _position} = _event, %{writes_paused: true} = state) do
    {:noreply, state}
  end

  # Normal event processing
  @doc false
  @impl GenServer
  def handle_info(%{global_position: _} = event, state) do
    apply_event(event, %{state | last_seen_position: event.global_position})
  end

  # Retry: re-attempt the same event after a scheduled delay
  @doc false
  @impl GenServer
  def handle_info({:retry_event, event}, state) do
    apply_event(event, state)
  end

  @doc false
  @impl GenServer
  def terminate(_reason, %{es_buffer: [_ | _]} = state) do
    # Best-effort flush of remaining buffered ES operations before shutdown.
    # Ensures partial batches are not silently dropped on graceful termination.
    flush_es_buffer_on_terminate(state)
    # Delegate to the unsubscribe clause (with cleared buffer so no recursion)
    terminate(:shutdown, %{state | es_buffer: []})
  end

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

    Tracer.with_span "orkestra.projector.apply_event",
      attributes: OTel.projector_span_attrs(projector_name, event, position) do
      case storage_adapter.write(projector_name, event, position, adapter_opts) do
        {:ok, %{action: :index} = es_op} ->
          # ES path — live single-doc write or catch-up bulk accumulation
          apply_es_event(event, es_op, position, state)

        {:ok, %{action: :skip}} ->
          # ES skip — no document to write, but checkpoint must still advance
          update_es_checkpoint_only(event, position, state)

        {:ok, read_model_multi} ->
          # Postgres path (Ecto.Multi) — unchanged
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

              # TEL-02: Emit lag metric after successful commit so operators can
              # monitor how far behind this projector is from the latest event.
              lag = (state.last_seen_position || position) - position

              :telemetry.execute(
                [:orkestra, :projector, :lag],
                %{lag: lag},
                %{projector_name: projector_name}
              )

              # TEL-03: Emit rebuild progress when in rebuild mode so operators
              # can track completion percentage during long replays.
              new_state =
                if state.rebuild_total && state.rebuild_total > 0 do
                  replayed = state.rebuild_events_replayed + 1

                  :telemetry.execute(
                    [:orkestra, :projector, :rebuild_progress],
                    %{events_replayed: replayed, total_events: state.rebuild_total},
                    %{
                      projector_name: projector_name,
                      percent: Float.round(replayed / state.rebuild_total * 100, 1)
                    }
                  )

                  %{state | attempts: 0, rebuild_events_replayed: replayed}
                else
                  %{state | attempts: 0}
                end

              {:noreply, new_state}

            {:error, step, reason, _changes} ->
              # TEL-01: Mark span as error on transaction failure
              Tracer.set_status(:error, inspect(reason))

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
          # TEL-01: Mark span as error on storage adapter failure
          Tracer.set_status(:error, inspect(reason))

          Logger.warning("Projector storage_adapter.write/4 failed",
            projector: projector_name,
            position: position,
            reason: inspect(reason),
            orkestra: :projector
          )

          handle_failure(event, reason, state)
      end
    end
  end

  # Branches between live single-doc write and catch-up bulk buffer accumulation
  defp apply_es_event(event, %{action: :index, id: id, doc: doc}, position, state) do
    action = %Snap.Bulk.Action.Index{id: id, doc: doc}

    case state.es_mode do
      :live ->
        commit_es_single_doc(event, action, position, state)

      :catching_up ->
        new_buffer = state.es_buffer ++ [{position, action}]

        if length(new_buffer) >= state.es_batch_size do
          flush_es_buffer(event, new_buffer, %{state | es_buffer: []})
        else
          {:noreply, %{state | es_buffer: new_buffer}}
        end
    end
  end

  # Live mode: writes a single document immediately via Snap.Document.index/6
  defp commit_es_single_doc(event, action, position, state) do
    %{adapter_opts: adapter_opts, projector_name: projector_name} = state
    cluster = Keyword.fetch!(adapter_opts, :cluster)
    index = Keyword.fetch!(adapter_opts, :index)
    engine = Keyword.get(adapter_opts, :engine, :elasticsearch)

    result =
      Tracer.with_span "orkestra.es.single_doc_index",
        attributes:
          Map.put(
            OTel.es_span_attrs(projector_name, index, engine),
            "orkestra.projector.position",
            position
          ) do
        case Snap.Document.index(cluster, index, action.doc, action.id) do
          {:ok, _} ->
            :ok

          {:error, reason} ->
            Tracer.set_status(:error, inspect(reason))
            {:error, reason}
        end
      end

    case result do
      :ok ->
        commit_es_checkpoint(event, position, state)

      {:error, reason} ->
        Logger.warning("ES single-doc index failed",
          projector: projector_name,
          position: position,
          reason: inspect(reason),
          orkestra: :projector
        )

        handle_failure(event, reason, state)
    end
  end

  # Catch-up mode: bulk-flushes the accumulated buffer via Snap.Bulk.perform/4
  defp flush_es_buffer(last_event, buffer, state) do
    %{adapter_opts: adapter_opts, projector_name: projector_name} = state
    cluster = Keyword.fetch!(adapter_opts, :cluster)
    index = Keyword.fetch!(adapter_opts, :index)
    engine = Keyword.get(adapter_opts, :engine, :elasticsearch)

    actions = Enum.map(buffer, fn {_pos, action} -> action end)
    {last_position, _} = List.last(buffer)

    started_at = System.monotonic_time(:millisecond)

    result =
      Tracer.with_span "orkestra.es.bulk_flush",
        attributes: OTel.es_span_attrs(projector_name, index, engine, length(actions)) do
        # Always pass page_size + page_wait: 0 for bounded GenServer buffers
        # to avoid the 15-second default page_wait in Snap.Bulk (T-07-05)
        case Snap.Bulk.perform(actions, cluster, index,
               page_size: length(actions),
               page_wait: 0
             ) do
          :ok ->
            :ok

          {:error, reason} ->
            Tracer.set_status(:error, inspect(reason))
            {:error, reason}
        end
      end

    elapsed_ms = System.monotonic_time(:millisecond) - started_at

    case result do
      :ok ->
        :telemetry.execute(
          [:orkestra, :projector, :es_bulk_flush],
          %{batch_size: length(actions), duration_ms: elapsed_ms},
          %{projector_name: projector_name, index: index, engine: engine}
        )

        # Advance checkpoint to last position in the flushed batch
        state_after_flush = %{
          state
          | es_buffer: [],
            rebuild_events_replayed: state.rebuild_events_replayed + length(buffer)
        }

        commit_es_checkpoint(last_event, last_position, state_after_flush)

      {:error, %Snap.BulkError{errors: errors} = bulk_err} ->
        Logger.warning("ES bulk flush partial failure",
          projector: projector_name,
          error_count: length(errors),
          errors:
            Enum.map(errors, fn e -> %{type: e.type, message: e.message, status: e.status} end),
          orkestra: :projector
        )

        # Do NOT advance checkpoint on partial failure (T-07-01) — at-least-once replay
        handle_failure(last_event, bulk_err, %{state | es_buffer: []})

      {:error, reason} ->
        Logger.warning("ES bulk flush failed",
          projector: projector_name,
          reason: inspect(reason),
          orkestra: :projector
        )

        handle_failure(last_event, reason, %{state | es_buffer: []})
    end
  end

  # Commits the Postgres checkpoint after a successful ES write (ES-first semantics)
  defp commit_es_checkpoint(event, position, state) do
    %{repo: repo, projector_name: projector_name} = state
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

    # ES path: checkpoint transaction runs standalone (not via Ecto.Multi.append)
    case repo.transaction(checkpoint_multi) do
      {:ok, _} ->
        Logger.debug("ES projector checkpoint updated",
          projector: projector_name,
          position: position,
          orkestra: :projector
        )

        lag = (state.last_seen_position || position) - position

        :telemetry.execute(
          [:orkestra, :projector, :lag],
          %{lag: lag},
          %{projector_name: projector_name}
        )

        new_state =
          if state.rebuild_total && state.rebuild_total > 0 do
            replayed = state.rebuild_events_replayed

            :telemetry.execute(
              [:orkestra, :projector, :rebuild_progress],
              %{events_replayed: replayed, total_events: state.rebuild_total},
              %{
                projector_name: projector_name,
                percent: Float.round(replayed / state.rebuild_total * 100, 1)
              }
            )

            %{state | attempts: 0}
          else
            %{state | attempts: 0}
          end

        {:noreply, new_state}

      {:error, step, reason, _} ->
        Logger.warning("ES projector checkpoint commit failed",
          projector: projector_name,
          position: position,
          step: step,
          reason: inspect(reason),
          orkestra: :projector
        )

        handle_failure(event, {step, reason}, state)
    end
  end

  # Skip path: event handler returned :skip — advance checkpoint without ES write
  defp update_es_checkpoint_only(event, position, state) do
    %{projector_name: projector_name} = state

    Logger.debug("ES projector skipping event (no write needed)",
      projector: projector_name,
      position: position,
      orkestra: :projector
    )

    commit_es_checkpoint(event, position, state)
  end

  # Best-effort flush of remaining ES buffer on GenServer termination.
  # Uses synchronous Snap.Bulk.perform without OTel (process is terminating).
  # On failure, logs a warning — events will be replayed on restart (at-least-once semantics).
  defp flush_es_buffer_on_terminate(state) do
    %{adapter_opts: adapter_opts, projector_name: projector_name, es_buffer: buffer} = state
    cluster = Keyword.fetch!(adapter_opts, :cluster)
    index = Keyword.fetch!(adapter_opts, :index)

    actions = Enum.map(buffer, fn {_pos, action} -> action end)
    {last_position, _} = List.last(buffer)

    case Snap.Bulk.perform(actions, cluster, index,
           page_size: length(actions),
           page_wait: 0
         ) do
      :ok ->
        now = DateTime.utc_now()

        checkpoint = %Checkpoint{
          projector_name: projector_name,
          last_position: last_position,
          halted: false,
          updated_at: now
        }

        checkpoint_multi =
          Ecto.Multi.new()
          |> Ecto.Multi.insert(:checkpoint, checkpoint,
            on_conflict: [set: [last_position: last_position, halted: false, updated_at: now]],
            conflict_target: :projector_name
          )

        case state.repo.transaction(checkpoint_multi) do
          {:ok, _} ->
            Logger.debug("ES projector terminate flush: checkpoint updated",
              projector: projector_name,
              last_position: last_position,
              orkestra: :projector
            )

          {:error, step, reason, _} ->
            Logger.warning("ES projector terminate flush: checkpoint update failed",
              projector: projector_name,
              step: step,
              reason: inspect(reason),
              orkestra: :projector
            )
        end

      {:error, reason} ->
        Logger.warning(
          "ES projector terminate flush failed — buffered events will be replayed on restart",
          projector: projector_name,
          buffer_size: length(buffer),
          reason: inspect(reason),
          orkestra: :projector
        )
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

        :telemetry.execute(
          [:orkestra, :projector, :retry],
          %{attempts: new_attempts, delay_ms: delay},
          %{projector_name: state.projector_name, position: event.global_position}
        )

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

    # Set last_position to position - 1 so that on a future restart the
    # failing event is NOT skipped: subscribe_from_position uses exclusive >
    # semantics, so subscribing from (position - 1) delivers events at
    # global_position > (position - 1), which includes the failing event (PROJ-03).
    halt_position = event.global_position - 1

    halted_checkpoint = %Checkpoint{
      projector_name: projector_name,
      last_position: halt_position,
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
            last_position: halt_position,
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

    # TEL-04: Emit halt telemetry regardless of DB success/failure — the
    # GenServer is halting either way and operators need alerting.
    :telemetry.execute(
      [:orkestra, :projector, :halted],
      %{attempts: attempts},
      %{
        projector_name: projector_name,
        position: event.global_position,
        reason: inspect(reason)
      }
    )

    Tracer.add_event("projector.halted", %{
      "orkestra.projector.name" => projector_name,
      "orkestra.projector.position" => event.global_position,
      "error.attempts" => attempts
    })

    # Always transition to halted state — a DB failure persisting the halt is
    # still a severe condition; stay alive to avoid supervisor restart loops
    # (plan prohibitions; no stop tuple).
    {:noreply, %{state | halted: true, attempts: 0}}
  end
end
