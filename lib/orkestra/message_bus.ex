defmodule Orkestra.MessageBus do
  @moduledoc """
  Behaviour for dispatching commands and publishing events.

  Two implementations are provided:
  - `MessageBus.PubSub` — in-process via Phoenix.PubSub (dev, test, single-node)
  - `MessageBus.RabbitMQ` — distributed via RabbitMQ (production, multi-node)

  ## Topic strategy

  Topics are derived automatically from the command/event module name:

      Ultimus.Tasks.Commands.StartAssessment → "tasks.commands.start_assessment"
      Ultimus.Tasks.Events.AssessmentCompleted → "tasks.events.assessment_completed"

  The convention is: drop the app prefix, downcase, underscore, dot-separated.

  ## Usage

      alias Orkestra.MessageBus

      # Get the configured implementation
      bus = MessageBus.impl()

      # Dispatch a command (point-to-point, one handler)
      :ok = bus.dispatch(command_envelope)

      # Publish an event (broadcast, many handlers)
      :ok = bus.publish(event_envelope)

  ## Handler behaviour

  Handlers implement `handle/1`:

      defmodule MyHandler do
        @behaviour Orkestra.MessageBus.Handler

        @impl true
        def handle(envelope) do
          # process...
          :ok
        end
      end

  Return `:ok` to ack, `{:error, reason}` to nack.
  """

  alias Orkestra.{CommandEnvelope, EventEnvelope}

  @type topic :: String.t()

  @callback dispatch(CommandEnvelope.t()) :: :ok | {:error, term()}
  @callback publish(EventEnvelope.t()) :: :ok | {:error, term()}
  @callback subscribe_command(topic(), module()) :: :ok | {:error, term()}
  @callback subscribe_event(topic(), module(), keyword()) :: :ok | {:error, term()}

  @doc "Returns the configured MessageBus implementation."
  @spec impl() :: module()
  def impl do
    Application.get_env(:orkestra, __MODULE__, [])
    |> Keyword.get(:adapter, Orkestra.MessageBus.PubSub)
  end

  @doc """
  Derives a topic from a command or event struct module.
  Strips the configured app prefix (default: none) from the module name.

      # config :orkestra, Orkestra.MessageBus, app_prefix: MyApp
      iex> MessageBus.topic_for(MyApp.Tasks.Commands.StartAssessment)
      "tasks.commands.start_assessment"
  """
  @spec topic_for(module()) :: topic()
  def topic_for(module) when is_atom(module) do
    module
    |> Module.split()
    |> drop_app_prefix()
    |> Enum.map(&Macro.underscore/1)
    |> Enum.join(".")
  end

  @doc """
  Derives a topic from an envelope (command or event).
  """
  @spec topic_for_envelope(CommandEnvelope.t() | EventEnvelope.t()) :: topic()
  def topic_for_envelope(%CommandEnvelope{command: cmd}), do: topic_for(cmd.__struct__)
  def topic_for_envelope(%EventEnvelope{event: event}), do: topic_for(event.__struct__)

  defp drop_app_prefix(parts) do
    prefix =
      Application.get_env(:orkestra, __MODULE__, [])
      |> Keyword.get(:app_prefix)

    case prefix do
      nil -> parts
      mod when is_atom(mod) -> drop_matching_prefix(parts, Module.split(mod))
      str when is_binary(str) -> drop_matching_prefix(parts, [str])
    end
  end

  defp drop_matching_prefix([h | rest_parts], [h | rest_prefix]),
    do: drop_matching_prefix(rest_parts, rest_prefix)

  defp drop_matching_prefix(parts, []), do: parts
  defp drop_matching_prefix(parts, _), do: parts
end
