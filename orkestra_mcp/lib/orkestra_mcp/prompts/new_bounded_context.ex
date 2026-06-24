defmodule OrkestraMcp.Prompts.NewBoundedContext do
  @moduledoc "Guided workflow for adding a new bounded context to an Orkestra project"

  use Hermes.Server.Component, type: :prompt

  alias Hermes.Server.Response

  schema do
    field(:context_name, :string,
      required: true,
      description: "Name of the bounded context, e.g. Orders, Inventory, Billing"
    )

    field(:app_module, :string,
      required: true,
      description: "Top-level app module, e.g. MyApp"
    )
  end

  @impl true
  def get_messages(%{context_name: context, app_module: app}, _frame) do
    response =
      Response.prompt()
      |> Response.user_message(workflow_text(app, context))

    {:reply, response}
  end

  defp workflow_text(app, context) do
    """
    # New Bounded Context: #{context}

    Follow these steps to add the #{context} bounded context to your #{app} project.

    ## Step 1: Create the directory structure

    ```
    lib/#{Macro.underscore(app)}/#{Macro.underscore(context)}/
      commands/
      events/
      handlers/
    ```

    ## Step 2: Define your Commands

    For each action in the #{context} domain, create a command:

    ```elixir
    defmodule #{app}.#{context}.Commands.YourCommand do
      use Orkestra.Command

      param :id, :string, required: true
      # Add more params as needed
    end
    ```

    Use the `orkestra.gen.command` tool to scaffold commands automatically.

    ## Step 3: Define your Events

    For each state change, create an event:

    ```elixir
    defmodule #{app}.#{context}.Events.YourEvent do
      use Orkestra.Event

      field :id, :string, required: true
      # Add more fields as needed
    end
    ```

    Use the `orkestra.gen.event` tool to scaffold events automatically.

    ## Step 4: Create Command Handlers

    Wire each command to its handler:

    ```elixir
    defmodule #{app}.#{context}.Handlers.YourCommandHandler do
      use Orkestra.CommandHandler, command: #{app}.#{context}.Commands.YourCommand

      @impl true
      def execute(command, metadata) do
        # Validate, execute business logic, emit events
        :ok
      end
    end
    ```

    ## Step 5: Create Event Handlers (side effects)

    React to events for notifications, projections, etc.:

    ```elixir
    defmodule #{app}.#{context}.Handlers.YourEventHandler do
      use Orkestra.EventHandler, event: #{app}.#{context}.Events.YourEvent

      @impl true
      def handle_event(event, metadata) do
        # Send email, update read model, etc.
        :ok
      end
    end
    ```

    ## Step 6: (Optional) Create an Aggregate

    If #{context} has a lifecycle with invariants:

    ```elixir
    defmodule #{app}.#{context}.#{context}Aggregate do
      @behaviour Orkestra.Aggregate

      defstruct []

      @impl true
      def init_state, do: %__MODULE__{}

      @impl true
      def stream_id(command), do: command.params.id

      @impl true
      def decide(state, command), do: {:ok, []}

      @impl true
      def evolve(state, event), do: state
    end
    ```

    ## Step 7: Add to Supervision Tree

    In your `application.ex`, add the handlers:

    ```elixir
    children = [
      # ... existing children
      #{app}.#{context}.Handlers.YourCommandHandler,
      #{app}.#{context}.Handlers.YourEventHandler,
    ]
    ```

    ## Step 8: Verify

    1. Run `mix compile` to check for errors
    2. Check the domain map via `orkestra://domain-map` resource
    3. Write tests for your handlers
    """
  end
end
