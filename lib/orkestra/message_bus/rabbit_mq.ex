defmodule Orkestra.MessageBus.RabbitMQ do
  @moduledoc """
  Distributed MessageBus implementation using RabbitMQ.

  Commands use exchange `orkestra.commands` with one queue per command type (competing consumers).
  Events use exchange `orkestra.events` with one queue per subscriber (fan-out per handler).

  Ack/nack is handled natively via AMQP: handler returns `:ok` → ack. A handler
  returning `{:error, _}` (or raising) gets the message again **a bounded number
  of times**: the message is republished to that handler's queue only (default
  exchange, routing key = queue) with `x-retry-count` incremented and a short
  backoff, then the original is acked. Once the retries are exhausted it is
  rejected without requeue and lands in the dead-letter queue. The bound is the
  subscriber's `:max_retries` (`Orkestra.EventHandler`'s option), else the
  message's `x-max-retries` header, else 3.

  Every delivery is handled in a task, started with
  `OpentelemetryProcessPropagator.Task` when that optional dependency is
  present (the trace context follows), with `Task` otherwise.

  ## Setup

      # In your supervision tree
      {Orkestra.MessageBus.RabbitMQ, []}

  Then register handlers:

      alias Orkestra.MessageBus.RabbitMQ, as: Bus

      Bus.subscribe_command("tasks.commands.start_assessment", MyCommandHandler)
      Bus.subscribe_event("tasks.events.assessment_completed", MyEventHandler)
  """

  @behaviour Orkestra.MessageBus

  use GenServer

  alias Orkestra.{CommandEnvelope, EventEnvelope, MessageBus}
  alias Orkestra.Telemetry, as: OTel

  require Logger
  require OpenTelemetry.Tracer, as: Tracer

  @doc false
  defp get_channel do
    config = Application.get_env(:orkestra, __MODULE__, [])
    channel_provider = Keyword.fetch!(config, :channel_provider)
    channel_provider.()
  end

  @commands_exchange "orkestra.commands"
  @events_exchange "orkestra.events"
  @dlx_exchange "orkestra.deadletter"
  @dlx_queue "orkestra.deadletter.queue"
  @default_max_retries 3

  # ── Client API ──────────────────────────────────────────────────

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl Orkestra.MessageBus
  def dispatch(%CommandEnvelope{} = envelope) do
    topic = MessageBus.topic_for_envelope(envelope)
    envelope = CommandEnvelope.mark_dispatched(envelope)
    do_publish(@commands_exchange, topic, envelope)
  end

  @impl Orkestra.MessageBus
  def publish(%EventEnvelope{} = envelope) do
    topic = MessageBus.topic_for_envelope(envelope)
    envelope = EventEnvelope.mark_published(envelope)
    do_publish(@events_exchange, topic, envelope)
  end

  @impl Orkestra.MessageBus
  def subscribe_command(topic, handler) do
    GenServer.call(__MODULE__, {:subscribe_command, topic, handler})
  end

  @impl Orkestra.MessageBus
  def subscribe_event(topic, handler, opts \\ []) do
    GenServer.call(__MODULE__, {:subscribe_event, topic, handler, opts})
  end

  # ── GenServer ───────────────────────────────────────────────────

  @impl GenServer
  def init(_opts) do
    send(self(), :setup_exchanges)
    {:ok, %{consumers: []}}
  end

  @impl GenServer
  def handle_info(:setup_exchanges, state) do
    case get_channel() do
      {:ok, channel} ->
        AMQP.Exchange.declare(channel, @commands_exchange, :topic, durable: true)
        AMQP.Exchange.declare(channel, @events_exchange, :topic, durable: true)

        # Dead letter exchange and queue — failed messages land here
        AMQP.Exchange.declare(channel, @dlx_exchange, :topic, durable: true)
        AMQP.Queue.declare(channel, @dlx_queue, durable: true)
        AMQP.Queue.bind(channel, @dlx_queue, @dlx_exchange, routing_key: "#")

        Logger.info("Exchanges and DLX declared", orkestra: :rabbitmq)
        {:noreply, state}

      {:error, _} ->
        Process.send_after(self(), :setup_exchanges, 5_000)
        {:noreply, state}
    end
  end

  def handle_info({:basic_deliver, body, meta}, state) do
    # Find the handler for this consumer tag
    case find_consumer(state.consumers, meta.consumer_tag) do
      nil ->
        Logger.warning("No handler for consumer",
          consumer_tag: meta.consumer_tag,
          orkestra: :rabbitmq
        )

        {:noreply, state}

      consumer ->
        start_task(fn -> handle_delivery(consumer, body, meta) end)

        {:noreply, state}
    end
  end

  def handle_info({:basic_consume_ok, _}, state), do: {:noreply, state}
  def handle_info({:basic_cancel, _}, state), do: {:noreply, state}
  def handle_info({:basic_cancel_ok, _}, state), do: {:noreply, state}

  @impl GenServer
  def handle_call({:subscribe_command, topic, handler}, _from, state) do
    # Commands: shared queue per topic (competing consumers)
    queue = "orkestra.cmd.#{topic}"

    case setup_consumer(@commands_exchange, queue, topic, handler, nil) do
      {:ok, consumer} ->
        {:reply, :ok, %{state | consumers: [consumer | state.consumers]}}

      {:error, _} = err ->
        {:reply, err, state}
    end
  end

  def handle_call({:subscribe_event, topic, handler, opts}, _from, state) do
    # Events: dedicated queue per handler (fan-out)
    handler_name = handler |> Module.split() |> List.last() |> Macro.underscore()
    queue = "orkestra.evt.#{topic}.#{handler_name}"

    case setup_consumer(@events_exchange, queue, topic, handler, opts[:max_retries]) do
      {:ok, consumer} ->
        {:reply, :ok, %{state | consumers: [consumer | state.consumers]}}

      {:error, _} = err ->
        {:reply, err, state}
    end
  end

  # ── Private ─────────────────────────────────────────────────────

  defp do_publish(exchange, routing_key, envelope) do
    Tracer.with_span "orkestra.rabbitmq.publish", %{kind: :producer} do
      case get_channel() do
        {:ok, channel} ->
          body = serialize(envelope)

          max_retries = envelope_max_retries(envelope)
          otel_headers = OTel.inject_context_to_headers()

          headers =
            [{"x-max-retries", :long, max_retries}] ++ otel_headers

          AMQP.Basic.publish(channel, exchange, routing_key, body,
            content_type: "application/json",
            persistent: true,
            message_id: envelope_id(envelope),
            correlation_id: envelope_correlation_id(envelope),
            type: envelope_type(envelope),
            headers: headers
          )

        {:error, :not_connected} ->
          Logger.error("Cannot publish: not connected", orkestra: :rabbitmq)
          {:error, :not_connected}
      end
    end
  end

  defp setup_consumer(exchange, queue, routing_key, handler, max_retries) do
    queue_opts = [
      durable: true,
      arguments: [
        {"x-dead-letter-exchange", :longstr, @dlx_exchange},
        {"x-dead-letter-routing-key", :longstr, "#{queue}.deadletter"}
      ]
    ]

    with {:ok, channel} <- get_channel(),
         :ok <- AMQP.Basic.qos(channel, prefetch_count: 10),
         {:ok, _} <- AMQP.Queue.declare(channel, queue, queue_opts),
         :ok <- AMQP.Queue.bind(channel, queue, exchange, routing_key: routing_key),
         {:ok, consumer_tag} <- AMQP.Basic.consume(channel, queue) do
      {:ok,
       %{
         tag: consumer_tag,
         handler: handler,
         channel: channel,
         queue: queue,
         max_retries: max_retries
       }}
    end
  end

  # The trace context follows the delivery into its task when the optional
  # `opentelemetry_process_propagator` is there.
  defp start_task(fun) do
    if Code.ensure_loaded?(OpentelemetryProcessPropagator.Task),
      do: apply(OpentelemetryProcessPropagator.Task, :start, [fun]),
      else: Task.start(fun)
  end

  defp handle_delivery(%{channel: channel, handler: handler} = consumer, body, meta) do
    OTel.extract_context_from_headers(headers(meta))

    Tracer.with_span "orkestra.rabbitmq.consume", %{kind: :consumer} do
      retry_count = get_retry_count(meta)
      max_retries = consumer.max_retries || get_max_retries(meta)

      result =
        try do
          case deserialize(body) do
            {:ok, envelope} -> handler.handle(envelope)
            {:error, reason} -> {:error, {:deserialize, reason}}
          end
        rescue
          e -> {:error, {:exception, Exception.message(e)}}
        end

      case result do
        :ok ->
          AMQP.Basic.ack(channel, meta.delivery_tag)

        {:error, {:deserialize, reason}} ->
          Logger.error("Deserialize failed, sending to DLQ",
            reason: inspect(reason),
            orkestra: :rabbitmq
          )

          AMQP.Basic.reject(channel, meta.delivery_tag, requeue: false)

        {:error, reason} ->
          handle_failure(consumer, body, meta, reason, retry_count, max_retries)
      end
    end
  end

  defp handle_failure(consumer, body, meta, reason, retry_count, max_retries) do
    %{channel: channel, handler: handler} = consumer

    if retry_count < max_retries do
      Tracer.add_event("message.retry", %{
        "retry.count" => retry_count + 1,
        "retry.max" => max_retries,
        "error.reason" => inspect(reason),
        "handler" => inspect(handler)
      })

      Logger.warning("Handler failed, retrying",
        handler: inspect(handler),
        attempt: retry_count + 1,
        max_retries: max_retries,
        reason: inspect(reason),
        orkestra: :rabbitmq
      )

      retry(consumer, body, meta, retry_count + 1)
    else
      Tracer.add_event("message.dead_letter", %{
        "retry.max" => max_retries,
        "error.reason" => inspect(reason),
        "handler" => inspect(handler)
      })

      Logger.error("Handler exhausted retries, sending to DLQ",
        handler: inspect(handler),
        max_retries: max_retries,
        reason: inspect(reason),
        orkestra: :rabbitmq
      )

      # Reject without requeue — DLX picks it up
      AMQP.Basic.reject(channel, meta.delivery_tag, requeue: false)
    end
  end

  # A nack with `requeue: true` would hand the message back unchanged (no
  # `x-death`, no counter): the handler would get it forever. So the message is
  # republished to this consumer's queue only — the default exchange routes by
  # queue name, so the other subscribers of the topic never see it again — with
  # the attempt in `x-retry-count`, after a short backoff; then the original is
  # acked. If the republish fails the original is requeued as is.
  defp retry(%{channel: channel, queue: queue}, body, meta, attempt) do
    Process.sleep(backoff(attempt))

    headers =
      meta
      |> headers()
      |> List.keydelete("x-retry-count", 0)
      |> List.insert_at(0, {"x-retry-count", :long, attempt})

    opts =
      [
        persistent: true,
        content_type: meta[:content_type],
        message_id: meta[:message_id],
        correlation_id: meta[:correlation_id],
        type: meta[:type],
        headers: headers
      ]
      |> Enum.reject(fn {_key, value} -> value in [nil, :undefined] end)

    case AMQP.Basic.publish(channel, "", queue, body, opts) do
      :ok -> AMQP.Basic.ack(channel, meta.delivery_tag)
      _error -> AMQP.Basic.nack(channel, meta.delivery_tag, requeue: true)
    end
  end

  # 200 ms, 400 ms, 800 ms… capped at 5 s.
  defp backoff(attempt), do: min(200 * Integer.pow(2, attempt - 1), 5_000)

  defp headers(meta) do
    case meta[:headers] do
      headers when is_list(headers) -> headers
      _ -> []
    end
  end

  # The attempt from the `x-retry-count` this module writes on a retry, or from
  # RabbitMQ's `x-death` when the message came back through a dead-letter cycle.
  defp get_retry_count(meta) do
    headers = headers(meta)

    case List.keyfind(headers, "x-retry-count", 0) do
      {_, _, count} when is_integer(count) ->
        count

      _ ->
        case List.keyfind(headers, "x-death", 0) do
          {_, _, deaths} when is_list(deaths) ->
            deaths
            |> Enum.map(fn death ->
              case death do
                {:table, fields} -> death_count(fields)
                fields when is_list(fields) -> death_count(fields)
                _ -> 0
              end
            end)
            |> Enum.sum()

          _ ->
            0
        end
    end
  end

  defp death_count(fields) do
    case List.keyfind(fields, "count", 0) do
      {_, _, count} when is_integer(count) -> count
      _ -> 0
    end
  end

  defp get_max_retries(meta) do
    case List.keyfind(headers(meta), "x-max-retries", 0) do
      {_, _, max} when is_integer(max) -> max
      _ -> @default_max_retries
    end
  end

  defp find_consumer(consumers, tag) do
    Enum.find(consumers, &(&1.tag == tag))
  end

  # ── Serialization ───────────────────────────────────────────────

  defp serialize(%CommandEnvelope{} = env) do
    Jason.encode!(%{
      __type__: "command_envelope",
      command_type: env.command.type,
      command_id: env.command.id,
      params: env.command.params,
      metadata: serialize_metadata(env.command.metadata),
      status: env.status,
      attempts: env.attempts,
      max_retries: env.max_retries
    })
  end

  defp serialize(%EventEnvelope{} = env) do
    Jason.encode!(%{
      __type__: "event_envelope",
      event_type: env.event.type,
      event_id: env.event.id,
      data: env.event.data,
      metadata: serialize_metadata(env.event.metadata),
      occurred_at: env.event.occurred_at && DateTime.to_iso8601(env.event.occurred_at)
    })
  end

  defp serialize_metadata(nil), do: nil

  defp serialize_metadata(meta) do
    %{
      correlation_id: meta.correlation_id,
      causation_id: meta.causation_id,
      actor_id: meta.actor_id,
      actor_type: meta.actor_type,
      source: meta.source,
      issued_at: meta.issued_at && DateTime.to_iso8601(meta.issued_at)
    }
  end

  defp deserialize(body) do
    case Jason.decode(body) do
      {:ok, %{"__type__" => "command_envelope"} = data} ->
        {:ok, deserialize_command_envelope(data)}

      {:ok, %{"__type__" => "event_envelope"} = data} ->
        {:ok, deserialize_event_envelope(data)}

      {:ok, data} ->
        # Raw message — wrap as-is
        {:ok, data}

      {:error, _} = err ->
        err
    end
  end

  defp deserialize_command_envelope(data) do
    metadata = deserialize_metadata(data["metadata"])

    %CommandEnvelope{
      command: %{
        __struct__: :deserialized_command,
        id: data["command_id"],
        type: data["command_type"],
        params: atomize_keys(data["params"] || %{}),
        metadata: metadata
      },
      status: String.to_existing_atom(data["status"] || "dispatched"),
      attempts: data["attempts"] || 1,
      max_retries: data["max_retries"] || 0
    }
  rescue
    _ -> %CommandEnvelope{command: data}
  end

  defp deserialize_event_envelope(data) do
    metadata = deserialize_metadata(data["metadata"])

    occurred_at =
      case data["occurred_at"] do
        nil -> nil
        str -> DateTime.from_iso8601(str) |> elem(1)
      end

    %EventEnvelope{
      event: %{
        __struct__: :deserialized_event,
        id: data["event_id"],
        type: data["event_type"],
        data: atomize_keys(data["data"] || %{}),
        metadata: metadata,
        occurred_at: occurred_at
      },
      status: :published
    }
  rescue
    _ -> %EventEnvelope{event: data}
  end

  defp deserialize_metadata(nil), do: nil

  defp deserialize_metadata(data) do
    issued_at =
      case data["issued_at"] do
        nil -> DateTime.utc_now()
        str -> DateTime.from_iso8601(str) |> elem(1)
      end

    %Orkestra.Metadata{
      correlation_id: data["correlation_id"] || "",
      causation_id: data["causation_id"],
      actor_id: data["actor_id"],
      actor_type: String.to_existing_atom(data["actor_type"] || "system"),
      source: data["source"],
      issued_at: issued_at
    }
  rescue
    _ ->
      Orkestra.Metadata.new()
  end

  defp envelope_id(%CommandEnvelope{command: cmd}), do: cmd.id
  defp envelope_id(%EventEnvelope{event: event}), do: event.id

  defp envelope_correlation_id(%CommandEnvelope{command: %{metadata: %{correlation_id: id}}}),
    do: id

  defp envelope_correlation_id(%EventEnvelope{event: %{metadata: %{correlation_id: id}}}), do: id
  defp envelope_correlation_id(_), do: ""

  defp envelope_type(%CommandEnvelope{}), do: "command"
  defp envelope_type(%EventEnvelope{}), do: "event"

  defp envelope_max_retries(%CommandEnvelope{max_retries: n}), do: n
  defp envelope_max_retries(%EventEnvelope{}), do: @default_max_retries

  defp atomize_keys(map) when is_map(map) do
    Map.new(map, fn
      {k, v} when is_binary(k) ->
        atom_key =
          try do
            String.to_existing_atom(k)
          rescue
            ArgumentError -> String.to_atom(k)
          end

        {atom_key, atomize_keys(v)}

      {k, v} ->
        {k, atomize_keys(v)}
    end)
  end

  defp atomize_keys(list) when is_list(list), do: Enum.map(list, &atomize_keys/1)
  defp atomize_keys(value), do: value
end
