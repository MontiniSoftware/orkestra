defmodule Orkestra.Event do
  @moduledoc """
  Behaviour and struct builder for domain events.

  An event represents something that happened in the system.
  Events are immutable facts — they are never rejected or retried.

  ## Defining an event

      defmodule MyApp.Tasks.Events.AssessmentCompleted do
        use Orkestra.Event

        field :task_id, :string, required: true
        field :expert_name, :string, required: true
        field :action_name, :string, required: true
        field :status, :string, required: true
        field :result, :map, default: %{}
        field :cost_usd, :float, default: 0.0
      end

  ## Emitting an event

      {:ok, event} = AssessmentCompleted.new(%{
        task_id: "task_123",
        expert_name: "architect",
        action_name: "perform-assessment",
        status: "success",
        result: %{...}
      })

      # From a command (preserves correlation, sets causation)
      {:ok, event} = AssessmentCompleted.from_command(command, %{
        task_id: "task_123",
        ...
      })
  """

  @type t :: %{
          __struct__: atom(),
          id: String.t(),
          type: String.t(),
          data: map(),
          metadata: Orkestra.Metadata.t(),
          occurred_at: DateTime.t()
        }

  @callback field_definitions() :: [field_definition()]

  @type field_definition :: {atom(), atom(), keyword()}

  defmacro __using__(_opts) do
    quote do
      @behaviour Orkestra.Event

      Module.register_attribute(__MODULE__, :field_defs, accumulate: true)

      import Orkestra.Event, only: [field: 2, field: 3]

      @before_compile Orkestra.Event
    end
  end

  @doc "Declares an event field."
  defmacro field(name, type, opts \\ []) do
    quote do
      @field_defs {unquote(name), unquote(type), unquote(opts)}
    end
  end

  defmacro __before_compile__(env) do
    field_defs = Module.get_attribute(env.module, :field_defs) |> Enum.reverse()

    field_keys =
      Enum.map(field_defs, fn {name, _type, opts} ->
        default = Keyword.get(opts, :default)
        {name, default}
      end)

    required =
      field_defs
      |> Enum.filter(fn {_name, _type, opts} -> Keyword.get(opts, :required, false) end)
      |> Enum.map(fn {name, _type, _opts} -> name end)

    type_name =
      env.module
      |> Module.split()
      |> Enum.map_join(".", & &1)

    quote do
      defstruct id: nil,
                type: unquote(type_name),
                data: %{},
                metadata: nil,
                occurred_at: nil

      @impl true
      def field_definitions, do: unquote(Macro.escape(field_defs))

      @doc "Creates a new event from a map of data."
      @spec new(map(), keyword()) :: {:ok, Orkestra.Event.t()} | {:error, term()}
      def new(data, opts \\ []) do
        alias Orkestra.Metadata

        data = normalize_data(data)

        with :ok <- check_required(data) do
          event = %__MODULE__{
            id: Orkestra.Event.generate_id(),
            data: build_data(data),
            metadata: Keyword.get(opts, :metadata) || Metadata.new(opts),
            occurred_at: DateTime.utc_now()
          }

          {:ok, event}
        end
      end

      @doc "Creates a new event, raising on failure."
      @spec new!(map(), keyword()) :: Orkestra.Event.t()
      def new!(data, opts \\ []) do
        case new(data, opts) do
          {:ok, event} -> event
          {:error, reason} -> raise "Event creation failed: #{inspect(reason)}"
        end
      end

      @doc """
      Creates an event derived from a command.
      Preserves correlation_id and sets causation_id to the command id.
      """
      @spec from_command(Orkestra.Command.t(), map()) ::
              {:ok, Orkestra.Event.t()} | {:error, term()}
      def from_command(command, data) do
        alias Orkestra.Metadata

        metadata = Metadata.derive(command.metadata, command.id)
        new(data, metadata: metadata)
      end

      @doc """
      Creates an event derived from another event.
      Preserves correlation_id and sets causation_id to the parent event id.
      """
      @spec from_event(Orkestra.Event.t(), map()) ::
              {:ok, Orkestra.Event.t()} | {:error, term()}
      def from_event(parent_event, data) do
        alias Orkestra.Metadata

        metadata = Metadata.derive(parent_event.metadata, parent_event.id)
        new(data, metadata: metadata)
      end

      defp normalize_data(data) when is_map(data) do
        Map.new(data, fn
          {k, v} when is_binary(k) -> {String.to_existing_atom(k), v}
          {k, v} when is_atom(k) -> {k, v}
        end)
      rescue
        ArgumentError -> data
      end

      defp check_required(data) do
        missing =
          unquote(required)
          |> Enum.reject(fn key ->
            case Map.get(data, key) do
              nil -> false
              "" -> false
              _ -> true
            end
          end)

        case missing do
          [] -> :ok
          keys -> {:error, {:missing_fields, keys}}
        end
      end

      defp build_data(data) do
        defaults = Map.new(unquote(Macro.escape(field_keys)))
        Map.merge(defaults, Map.take(data, Map.keys(defaults)))
      end
    end
  end

  def generate_id do
    Base.hex_encode32(:crypto.strong_rand_bytes(12), case: :lower, padding: false)
  end
end
