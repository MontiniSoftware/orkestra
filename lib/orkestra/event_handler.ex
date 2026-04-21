defmodule Orkestra.EventHandler do
  @moduledoc """
  Macro for defining event handlers with automatic subscription and ack/nack.

  The handler auto-subscribes to the correct topic derived from the event module,
  unwraps the envelope, and passes the clean event + metadata to your callback.

  Supports subscribing to multiple events and wildcard topics.

  ## Usage — single event

      defmodule MyApp.OnAssessmentCompleted do
        use Orkestra.EventHandler,
          event: MyApp.Tasks.Events.AssessmentCompleted

        @impl true
        def handle_event(event, metadata) do
          # event.data contains the event fields
          :ok
        end
      end

  ## Usage — multiple events

      defmodule MyApp.AuditLogger do
        use Orkestra.EventHandler,
          events: [
            MyApp.Tasks.Events.AssessmentCompleted,
            MyApp.Tasks.Events.AssessmentFailed
          ]

        @impl true
        def handle_event(event, metadata) do
          Logger.info("Audit: \#{event.type}")
          :ok
        end
      end

  ## Usage — wildcard topic

      defmodule MyApp.TaskActivityLogger do
        use Orkestra.EventHandler,
          topic: "tasks.events.#"

        @impl true
        def handle_event(event, metadata) do
          :ok
        end
      end

  ## Callbacks

  - `handle_event(event, metadata)` — your reaction logic
    - Return `:ok` to ack
    - Return `{:error, reason}` to nack (triggers retry/dead-letter)

  ## Options

  - `:event` — single event module
  - `:events` — list of event modules
  - `:topic` — explicit topic pattern (supports `*` and `#` wildcards)
  - `:max_retries` — retry attempts before dead-letter (default: 3)

  Exactly one of `:event`, `:events`, or `:topic` must be provided.
  """

  @callback handle_event(
              event :: map(),
              metadata :: Orkestra.Metadata.t() | nil
            ) :: :ok | {:error, term()}

  defmacro __using__(opts) do
    event = Keyword.get(opts, :event)
    events = Keyword.get(opts, :events, [])
    topic = Keyword.get(opts, :topic)
    max_retries = Keyword.get(opts, :max_retries, 3)

    topics =
      cond do
        topic -> [topic]
        event -> [quote(do: Orkestra.MessageBus.topic_for(unquote(event)))]
        events != [] -> Enum.map(events, fn e -> quote(do: Orkestra.MessageBus.topic_for(unquote(e))) end)
        true -> raise ArgumentError, "EventHandler requires :event, :events, or :topic option"
      end

    quote do
      @behaviour Orkestra.EventHandler
      @behaviour Orkestra.MessageBus.Handler

      use GenServer

      require Logger
      require OpenTelemetry.Tracer, as: Tracer

      alias Orkestra.{EventEnvelope, MessageBus}
      alias Orkestra.Telemetry, as: OTel

      @topics unquote(topics)
      @handler_max_retries unquote(max_retries)

      def start_link(opts \\ []) do
        GenServer.start_link(__MODULE__, opts, name: __MODULE__)
      end

      @impl GenServer
      def init(_opts) do
        send(self(), :subscribe)
        {:ok, %{subscribed: false}}
      end

      @impl GenServer
      def handle_info(:subscribe, state) do
        bus = MessageBus.impl()

        results =
          Enum.map(@topics, fn topic ->
            bus.subscribe_event(topic, __MODULE__, max_retries: @handler_max_retries)
          end)

        if Enum.all?(results, &(&1 == :ok)) do
          Logger.info("Event handler #{inspect(__MODULE__)} subscribed",
            handler: inspect(__MODULE__),
            topics: inspect(@topics),
            orkestra: :event_handler
          )

          {:noreply, %{state | subscribed: true}}
        else
          Logger.warning("Event handler #{inspect(__MODULE__)} subscribe failed, retrying",
            handler: inspect(__MODULE__),
            orkestra: :event_handler
          )

          Process.send_after(self(), :subscribe, 5_000)
          {:noreply, state}
        end
      end

      @impl Orkestra.MessageBus.Handler
      def handle(%EventEnvelope{event: event} = _envelope) do
        metadata = event.metadata

        OTel.set_logger_metadata(metadata)

        Tracer.with_span "orkestra.event.handle",
          attributes: %{
            "orkestra.event.type" => event.type,
            "orkestra.event.id" => event.id,
            "orkestra.handler" => inspect(__MODULE__),
            "orkestra.correlation_id" => metadata && metadata.correlation_id,
            "orkestra.causation_id" => metadata && metadata.causation_id,
            "orkestra.actor_id" => metadata && metadata.actor_id
          } do
          Logger.debug("Handling event",
            handler: inspect(__MODULE__),
            event_type: event.type,
            event_id: event.id,
            orkestra: :event_handler
          )

          case handle_event(event, metadata) do
            :ok ->
              :ok

            {:error, reason} ->
              Tracer.set_status(:error, inspect(reason))

              Logger.warning("Event handling failed",
                handler: inspect(__MODULE__),
                event_id: event.id,
                reason: inspect(reason),
                orkestra: :event_handler
              )

              {:error, reason}
          end
        end
      rescue
        e ->
          OpenTelemetry.Span.record_exception(Tracer.current_span_ctx(), e)
          Tracer.set_status(:error, Exception.message(e))

          Logger.error("Event handler crashed",
            handler: inspect(__MODULE__),
            error: Exception.message(e),
            orkestra: :event_handler
          )

          {:error, {:handler_crash, Exception.message(e)}}
      after
        OTel.clear_logger_metadata()
      end

      # Handle raw deserialized maps from RabbitMQ
      def handle(envelope) do
        Logger.warning("Received unexpected envelope",
          handler: inspect(__MODULE__),
          envelope: inspect(envelope, limit: 200),
          orkestra: :event_handler
        )

        {:error, :unexpected_envelope}
      end
    end
  end
end
