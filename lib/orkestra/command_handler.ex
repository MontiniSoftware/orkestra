defmodule Orkestra.CommandHandler do
  @moduledoc """
  Macro for defining command handlers with automatic subscription and ack/nack.

  The handler auto-subscribes to the correct topic derived from the command module,
  unwraps the envelope, and passes the clean command + metadata to your callback.

  ## Usage

      defmodule MyApp.HandleStartAssessment do
        use Orkestra.CommandHandler,
          command: MyApp.Tasks.Commands.StartAssessment

        @impl true
        def execute(command, metadata) do
          # command.params contains the validated params
          # metadata contains correlation_id, actor_id, etc.
          {:ok, %{task_id: "123"}}
        end
      end

  Then add to your supervision tree:

      MyApp.HandleStartAssessment

  ## Callbacks

  - `execute(command, metadata)` — your business logic
    - Return `{:ok, result}` to ack
    - Return `:ok` to ack without result
    - Return `{:error, reason}` to nack (triggers retry/dead-letter)

  ## Options

  - `:command` (required) — the command module this handler processes
  - `:max_retries` — override max retries for this handler (default: from envelope)
  """

  @callback execute(command :: map(), metadata :: Orkestra.Metadata.t() | nil) ::
              :ok | {:ok, term()} | {:error, term()}

  defmacro __using__(opts) do
    command_module = Keyword.fetch!(opts, :command)

    quote do
      @behaviour Orkestra.CommandHandler
      @behaviour Orkestra.MessageBus.Handler

      use GenServer

      require Logger
      require OpenTelemetry.Tracer, as: Tracer

      alias Orkestra.{CommandEnvelope, MessageBus}
      alias Orkestra.Telemetry, as: OTel

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
        topic = MessageBus.topic_for(unquote(command_module))

        case bus.subscribe_command(topic, __MODULE__) do
          :ok ->
            Logger.info("Command handler #{inspect(__MODULE__)} subscribed",
              handler: inspect(__MODULE__),
              topic: topic,
              orkestra: :command_handler
            )

            {:noreply, %{state | subscribed: true}}

          {:error, reason} ->
            Logger.warning("Command handler #{inspect(__MODULE__)} subscribe failed, retrying",
              handler: inspect(__MODULE__),
              reason: inspect(reason),
              orkestra: :command_handler
            )

            Process.send_after(self(), :subscribe, 5_000)
            {:noreply, state}
        end
      end

      @impl Orkestra.MessageBus.Handler
      def handle(%CommandEnvelope{command: command} = envelope) do
        metadata = command.metadata

        OTel.set_logger_metadata(metadata)

        Tracer.with_span "orkestra.command.handle",
          attributes: %{
            "orkestra.command.type" => command.type,
            "orkestra.command.id" => command.id,
            "orkestra.handler" => inspect(__MODULE__),
            "orkestra.correlation_id" => metadata && metadata.correlation_id,
            "orkestra.causation_id" => metadata && metadata.causation_id,
            "orkestra.actor_id" => metadata && metadata.actor_id
          } do
          Logger.debug("Handling command",
            handler: inspect(__MODULE__),
            command_type: command.type,
            command_id: command.id,
            orkestra: :command_handler
          )

          case execute(command, metadata) do
            :ok ->
              :ok

            {:ok, _result} ->
              :ok

            {:error, reason} ->
              Tracer.set_status(:error, inspect(reason))

              Logger.warning("Command execution failed",
                handler: inspect(__MODULE__),
                command_id: command.id,
                reason: inspect(reason),
                orkestra: :command_handler
              )

              {:error, reason}
          end
        end
      rescue
        e ->
          OpenTelemetry.Span.record_exception(Tracer.current_span_ctx(), e)
          Tracer.set_status(:error, Exception.message(e))

          Logger.error("Command handler crashed",
            handler: inspect(__MODULE__),
            error: Exception.message(e),
            orkestra: :command_handler
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
          orkestra: :command_handler
        )

        {:error, :unexpected_envelope}
      end
    end
  end
end
