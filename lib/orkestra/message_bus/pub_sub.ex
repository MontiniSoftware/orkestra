defmodule Orkestra.MessageBus.PubSub do
  @moduledoc """
  In-process MessageBus implementation using Phoenix.PubSub.

  Commands are dispatched to a single registered handler (point-to-point).
  Events are broadcast to all subscribers.

  Ack/nack is synchronous: the handler return value determines the outcome.

  ## Setup

  Add the registry to your supervision tree (done automatically if using Orkestra):

      Orkestra.MessageBus.PubSub

  """

  @behaviour Orkestra.MessageBus

  use GenServer

  alias Orkestra.{CommandEnvelope, EventEnvelope, MessageBus}
  alias Orkestra.Telemetry, as: OTel

  require Logger
  require OpenTelemetry.Tracer, as: Tracer

  defp pubsub_name do
    Application.get_env(:orkestra, __MODULE__, [])
    |> Keyword.get(:pubsub, Orkestra.PubSub)
  end

  # ── Client API ──────────────────────────────────────────────────

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl Orkestra.MessageBus
  def dispatch(%CommandEnvelope{} = envelope) do
    OTel.with_span("orkestra.command.dispatch", OTel.command_attrs(envelope), fn ->
      topic = MessageBus.topic_for_envelope(envelope)

      case lookup_command_handler(topic) do
        nil ->
          Logger.error("No command handler registered", topic: topic, orkestra: :pubsub)
          {:error, {:no_handler, topic}}

        handler ->
          dispatch_with_retry(handler, envelope)
      end
    end)
  end

  @impl Orkestra.MessageBus
  def publish(%EventEnvelope{} = envelope) do
    OTel.with_span("orkestra.event.publish", OTel.event_attrs(envelope), fn ->
      topic = MessageBus.topic_for_envelope(envelope)
      envelope = EventEnvelope.mark_published(envelope)

      Phoenix.PubSub.broadcast(pubsub_name(), "orkestra:events:#{topic}", {:event, envelope})

      # Also dispatch to registered handlers synchronously for ack tracking
      handlers = lookup_event_handlers(topic)

      Enum.each(handlers, fn {handler, opts} ->
        max_retries = Keyword.get(opts, :max_retries, 0)
        attempt_with_retry(handler, envelope, max_retries)
      end)

      :ok
    end)
  end

  @impl Orkestra.MessageBus
  def subscribe_command(topic, handler) do
    GenServer.call(__MODULE__, {:register_command, topic, handler})
  end

  @impl Orkestra.MessageBus
  def subscribe_event(topic, handler, opts \\ []) do
    GenServer.call(__MODULE__, {:register_event, topic, handler, opts})
  end

  # ── GenServer ───────────────────────────────────────────────────

  @impl GenServer
  def init(_opts) do
    {:ok, %{commands: %{}, events: %{}}}
  end

  @impl GenServer
  def handle_call({:register_command, topic, handler}, _from, state) do
    if Map.has_key?(state.commands, topic) do
      Logger.warning("Overwriting command handler",
        topic: topic,
        handler: inspect(handler),
        orkestra: :pubsub
      )
    end

    Logger.info("Registered command handler",
      handler: inspect(handler),
      topic: topic,
      orkestra: :pubsub
    )

    {:reply, :ok, %{state | commands: Map.put(state.commands, topic, handler)}}
  end

  def handle_call({:register_event, topic, handler, opts}, _from, state) do
    handlers = Map.get(state.events, topic, [])
    updated = [{handler, opts} | handlers]

    Logger.info("Registered event handler",
      handler: inspect(handler),
      topic: topic,
      orkestra: :pubsub
    )

    {:reply, :ok, %{state | events: Map.put(state.events, topic, updated)}}
  end

  @impl GenServer
  def handle_call(:state, _from, state), do: {:reply, state, state}

  # ── Private ─────────────────────────────────────────────────────

  defp lookup_command_handler(topic) do
    GenServer.call(__MODULE__, :state)
    |> Map.get(:commands, %{})
    |> Map.get(topic)
  end

  defp lookup_event_handlers(topic) do
    state = GenServer.call(__MODULE__, :state)
    direct = Map.get(state.events, topic, [])

    # Also match wildcard subscriptions (e.g. "tasks.events.*")
    wildcards =
      state.events
      |> Enum.filter(fn {pattern, _handlers} ->
        pattern != topic and topic_matches?(topic, pattern)
      end)
      |> Enum.flat_map(fn {_pattern, handlers} -> handlers end)

    direct ++ wildcards
  end

  defp topic_matches?(topic, pattern) do
    pattern_parts = String.split(pattern, ".")
    topic_parts = String.split(topic, ".")

    match_parts?(topic_parts, pattern_parts)
  end

  defp match_parts?([], []), do: true
  defp match_parts?(_, ["*"]), do: true
  defp match_parts?(_, ["#"]), do: true
  defp match_parts?([h | t1], [h | t2]), do: match_parts?(t1, t2)
  defp match_parts?(_, _), do: false

  defp dispatch_with_retry(handler, %CommandEnvelope{} = envelope) do
    max_retries = envelope.max_retries
    attempt_with_retry(handler, CommandEnvelope.mark_dispatched(envelope), max_retries)
  end

  defp attempt_with_retry(handler, envelope, max_retries, attempt \\ 0) do
    case safe_handle(handler, envelope) do
      :ok ->
        :ok

      {:error, reason} when attempt < max_retries ->
        OTel.with_span("orkestra.retry", %{
          "orkestra.retry.attempt" => attempt + 1,
          "orkestra.retry.max" => max_retries,
          "orkestra.retry.handler" => inspect(handler),
          "orkestra.retry.reason" => inspect(reason)
        }, fn ->
          Logger.warning("Handler failed, retrying",
            handler: inspect(handler),
            attempt: attempt + 1,
            max_retries: max_retries,
            reason: inspect(reason),
            orkestra: :pubsub
          )

          attempt_with_retry(handler, envelope, max_retries, attempt + 1)
        end)

      {:error, reason} ->
        Logger.error("Handler exhausted retries, sending to dead letter",
          handler: inspect(handler),
          max_retries: max_retries,
          reason: inspect(reason),
          orkestra: :pubsub
        )

        dead_letter(handler, envelope, reason)
        {:error, reason}
    end
  end

  defp dead_letter(handler, envelope, reason) do
    dead_letter_entry = %{
      handler: inspect(handler),
      envelope: envelope,
      reason: inspect(reason),
      dead_lettered_at: DateTime.utc_now()
    }

    Tracer.add_event("dead_letter", %{
      "orkestra.dead_letter.handler" => inspect(handler),
      "orkestra.dead_letter.reason" => inspect(reason)
    })

    # Broadcast to dead letter topic for monitoring/alerting
    Phoenix.PubSub.broadcast(
      pubsub_name(),
      "orkestra:deadletter",
      {:dead_letter, dead_letter_entry}
    )

    Logger.error("Dead letter recorded",
      handler: inspect(handler),
      reason: inspect(reason),
      orkestra: :pubsub
    )
  end

  defp safe_handle(handler, envelope) do
    handler.handle(envelope)
  rescue
    e ->
      Logger.error("Handler raised exception",
        handler: inspect(handler),
        exception: Exception.message(e),
        orkestra: :pubsub
      )

      {:error, {:handler_exception, e}}
  end
end
