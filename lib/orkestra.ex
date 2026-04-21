defmodule Orkestra do
  @moduledoc """
  CQRS/ES toolkit for Elixir.

  ## Configuration

      config :orkestra, Orkestra.MessageBus,
        adapter: Orkestra.MessageBus.PubSub,
        app_prefix: MyApp

      config :orkestra, Orkestra.MessageBus.PubSub,
        pubsub: MyApp.PubSub

      config :orkestra, Orkestra.MessageBus.RabbitMQ,
        channel_provider: fn -> MyApp.RabbitMQ.Connection.channel() end

  ## Quick start

      # Define a command
      defmodule MyApp.Commands.DoThing do
        use Orkestra.Command
        param :name, :string, required: true
      end

      # Define an event
      defmodule MyApp.Events.ThingDone do
        use Orkestra.Event
        field :name, :string, required: true
      end

      # Handle a command
      defmodule MyApp.HandleDoThing do
        use Orkestra.CommandHandler, command: MyApp.Commands.DoThing

        @impl true
        def execute(command, _metadata) do
          {:ok, %{done: true}}
        end
      end

      # Handle an event
      defmodule MyApp.OnThingDone do
        use Orkestra.EventHandler, event: MyApp.Events.ThingDone

        @impl true
        def handle_event(event, _metadata) do
          :ok
        end
      end
  """
end
