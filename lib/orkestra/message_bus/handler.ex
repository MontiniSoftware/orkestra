defmodule Orkestra.MessageBus.Handler do
  @moduledoc """
  Behaviour for command and event handlers.

  Return `:ok` to acknowledge, `{:error, reason}` to reject/nack.

  ## Example

      defmodule MyApp.HandleStartAssessment do
        @behaviour Orkestra.MessageBus.Handler

        @impl true
        def handle(%CommandEnvelope{command: cmd}) do
          # do work...
          :ok
        end
      end
  """

  @callback handle(
              Orkestra.CommandEnvelope.t()
              | Orkestra.EventEnvelope.t()
            ) :: :ok | {:error, term()}
end
