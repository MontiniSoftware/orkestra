defmodule Orkestra.Aggregate.Root do
  @moduledoc """
  The imperative shell for functional aggregates.

  Orchestrates the load → fold → decide → append → publish pipeline,
  handling all I/O while keeping aggregate logic pure.

  ## Usage

      alias Orkestra.Aggregate.Root

      {:ok, events, new_state} = Root.execute(MyAggregate, command)

      # With options
      {:ok, events, new_state} = Root.execute(MyAggregate, command,
        max_retries: 5,
        publish: true
      )

  ## Optimistic concurrency

  If another process appends events to the same stream between our load
  and append, EventStore returns `:wrong_expected_version`. The shell
  automatically retries by re-loading, re-folding, and re-deciding.
  """

  alias Orkestra.{EventEnvelope, EventStore, MessageBus, Metadata}
  alias Orkestra.EventStore.Snapshot
  alias Orkestra.Telemetry, as: OTel

  require Logger
  require OpenTelemetry.Tracer, as: Tracer

  @default_max_retries 3

  @type execute_result :: {:ok, [map()], term()} | {:error, term()}

  @doc """
  Executes a command against an aggregate.

  ## Options
  - `:max_retries` — retries on concurrency conflict (default: 3)
  - `:publish` — publish events to MessageBus after append (default: true)
  - `:metadata` — Orkestra Metadata for event creation context
  """
  @spec execute(module(), map(), keyword()) :: execute_result()
  def execute(aggregate_module, command, opts \\ []) do
    command = hydrate_command(command)
    stream_id = aggregate_module.stream_id(command)
    max_retries = Keyword.get(opts, :max_retries, @default_max_retries)
    publish? = Keyword.get(opts, :publish, true)

    OTel.set_logger_metadata(command.metadata)

    Tracer.with_span "orkestra.aggregate.execute",
      attributes: %{
        "orkestra.aggregate.module" => inspect(aggregate_module),
        "orkestra.aggregate.stream_id" => stream_id,
        "orkestra.command.type" => command.type,
        "orkestra.command.id" => command.id
      } do
      Logger.info("Executing aggregate command",
        aggregate: inspect(aggregate_module),
        stream_id: stream_id,
        command_type: command.type,
        orkestra: :aggregate
      )

      result = do_execute(aggregate_module, command, stream_id, publish?, max_retries, 0)

      case result do
        {:ok, events, _state} ->
          Logger.info("Aggregate command succeeded",
            aggregate: inspect(aggregate_module),
            stream_id: stream_id,
            events_count: length(events),
            orkestra: :aggregate
          )

        {:error, reason} ->
          Tracer.set_status(:error, inspect(reason))

          Logger.warning("Aggregate command failed",
            aggregate: inspect(aggregate_module),
            stream_id: stream_id,
            reason: inspect(reason),
            orkestra: :aggregate
          )
      end

      result
    end
  after
    OTel.clear_logger_metadata()
  end

  # ── Internal pipeline ──────────────────────────────────────────

  defp do_execute(aggregate, command, stream_id, publish?, max_retries, attempt) do
    with {:ok, state, revision, event_count} <- load_and_fold(aggregate, stream_id),
         {:ok, new_events} <- decide(aggregate, state, command),
         {:ok, new_revision} <- append(stream_id, new_events, revision) do
      new_state = Enum.reduce(new_events, state, &aggregate.evolve(&2, &1))
      total_events = event_count + length(new_events)

      if publish?, do: publish_events(new_events, command)
      maybe_snapshot(aggregate, stream_id, new_state, new_revision, total_events)

      {:ok, new_events, new_state}
    else
      {:error, :wrong_expected_version} when attempt < max_retries ->
        Logger.warning("Concurrency conflict, retrying",
          stream_id: stream_id,
          attempt: attempt + 1,
          max_retries: max_retries,
          orkestra: :aggregate
        )

        Tracer.add_event("concurrency_retry", %{
          "attempt" => attempt + 1,
          "max_retries" => max_retries,
          "orkestra.aggregate.stream_id" => stream_id
        })

        do_execute(aggregate, command, stream_id, publish?, max_retries, attempt + 1)

      {:error, :wrong_expected_version} ->
        Logger.error("Concurrency conflict exhausted retries",
          stream_id: stream_id,
          max_retries: max_retries,
          orkestra: :aggregate
        )

        {:error, :concurrency_conflict}

      {:error, _} = err ->
        err
    end
  end

  defp load_and_fold(aggregate, stream_id) do
    Tracer.with_span "orkestra.aggregate.load",
      attributes: %{
        "orkestra.aggregate.stream_id" => stream_id
      } do
      store = EventStore.impl()

      {initial_state, from_revision, snapshot_events, snapshot_loaded?} =
        case Snapshot.load(stream_id) do
          {:ok, %{state: state, revision: rev}} ->
            Logger.debug("Loaded snapshot",
              stream_id: stream_id,
              revision: rev,
              orkestra: :aggregate
            )

            {state, rev, rev + 1, true}

          {:error, :no_snapshot} ->
            {aggregate.init_state(), -1, 0, false}
        end

      Tracer.set_attribute("orkestra.aggregate.snapshot_loaded", snapshot_loaded?)

      events_result =
        if from_revision >= 0 do
          store.load_events(stream_id, from_revision)
        else
          store.load_events(stream_id)
        end

      case events_result do
        {:ok, events, revision} ->
          Tracer.with_span "orkestra.aggregate.fold",
            attributes: %{
              "orkestra.aggregate.event_count" => length(events),
              "orkestra.aggregate.stream_id" => stream_id
            } do
            state = fold(aggregate, initial_state, events)
            total_event_count = snapshot_events + length(events)
            {:ok, state, revision, total_event_count}
          end

        {:error, _} = err ->
          err
      end
    end
  end

  defp fold(aggregate, initial_state, events) do
    Enum.reduce(events, initial_state, fn event, state ->
      hydrated = hydrate_event(event)
      aggregate.evolve(state, hydrated)
    end)
  end

  # Reconstruct Event structs from stored event maps.
  # stored events have %{type: "Module.Name", data: %{...}}
  defp hydrate_event(%{type: type, data: data} = stored) when is_binary(type) do
    module = String.to_existing_atom("Elixir.#{type}")

    if function_exported?(module, :__struct__, 0) do
      struct(module, %{
        id: stored[:id],
        type: type,
        data: data,
        metadata: nil,
        occurred_at: nil
      })
    else
      stored
    end
  rescue
    _ -> stored
  end

  defp hydrate_event(event), do: event

  # Reconstruct Command structs from deserialized command maps.
  defp hydrate_command(%{__struct__: :deserialized_command, type: type, params: params} = cmd) do
    module = String.to_existing_atom("Elixir.#{type}")

    if function_exported?(module, :__struct__, 0) do
      struct(module, %{
        id: cmd.id,
        type: type,
        params: params,
        metadata: cmd.metadata
      })
    else
      cmd
    end
  rescue
    _ -> cmd
  end

  defp hydrate_command(command), do: command

  defp decide(aggregate, state, command) do
    Tracer.with_span "orkestra.aggregate.decide",
      attributes: %{
        "orkestra.aggregate.stream_id" => aggregate.stream_id(command),
        "orkestra.command.type" => command.type
      } do
      case aggregate.decide(state, command) do
        {:ok, events} when is_list(events) ->
          {:ok, events}

        {:error, _} = err ->
          Tracer.set_status(:error, inspect(err))
          err
      end
    end
  end

  defp append(stream_id, events, expected_revision) do
    Tracer.with_span "orkestra.aggregate.append",
      attributes: %{
        "orkestra.aggregate.events_count" => length(events),
        "orkestra.aggregate.stream_id" => stream_id,
        "orkestra.aggregate.expected_revision" => expected_revision
      } do
      store = EventStore.impl()

      stored_events =
        Enum.map(events, fn event ->
          %{
            id: event.id,
            type: event.type,
            data: event.data,
            metadata: serialize_metadata(event.metadata),
            stream_revision: 0
          }
        end)

      store.append_events(stream_id, stored_events, expected_revision)
    end
  end

  defp publish_events(events, _command) do
    Tracer.with_span "orkestra.aggregate.publish",
      attributes: %{
        "orkestra.aggregate.events_count" => length(events)
      } do
      bus = MessageBus.impl()

      Enum.each(events, fn event ->
        envelope = EventEnvelope.wrap(event)
        bus.publish(envelope)
      end)
    end
  rescue
    e ->
      Logger.error("Failed to publish events",
        error: Exception.message(e),
        orkestra: :aggregate
      )
  end

  defp maybe_snapshot(aggregate, stream_id, state, revision, total_events) do
    if Snapshot.should_snapshot?(aggregate, total_events) do
      Tracer.with_span "orkestra.aggregate.snapshot",
        attributes: %{
          "orkestra.aggregate.stream_id" => stream_id,
          "orkestra.aggregate.revision" => revision
        } do
        Snapshot.save(stream_id, state, revision)
      end
    end
  end

  defp serialize_metadata(nil), do: %{}

  defp serialize_metadata(%Metadata{} = meta) do
    %{
      "correlation_id" => meta.correlation_id,
      "causation_id" => meta.causation_id,
      "actor_id" => meta.actor_id,
      "actor_type" => to_string(meta.actor_type),
      "source" => meta.source
    }
  end
end
