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

  # ── Shared hydration / normalization helpers ────────────────────
  #
  # These are used both by `Orkestra.Aggregate.Root` (reconstructing event
  # structs on replay) and by the `Orkestra.EventStore.EventStoreDB` adapter
  # (normalizing the string-keyed maps Spear produces after a JSON round-trip
  # back to the atom-keyed contract the InMemory adapter delivers). Keeping the
  # logic here — rather than duplicated in each caller — guarantees a single
  # definition of "what is a known event field" and "which keys may be atomized".

  @doc """
  Resolves the event module named by a stored `type` string
  (e.g. `"MyApp.Events.Created"`).

  Safe by construction:

    * uses `String.to_existing_atom/1` (never creates a new atom) and
      `Code.ensure_loaded?/1`;
    * returns `{:ok, module}` only when the module is loaded **and** implements
      the `Orkestra.Event` behaviour (exports `field_definitions/0`);
    * returns `:error` for anything else — an unknown type, a `snapshot-*`
      event, a foreign event, or a module that is not an Orkestra event.

  Never raises.
  """
  @spec resolve_module(String.t()) :: {:ok, module()} | :error
  def resolve_module(type) when is_binary(type) do
    module = String.to_existing_atom("Elixir." <> type)

    if Code.ensure_loaded?(module) and function_exported?(module, :field_definitions, 0) do
      {:ok, module}
    else
      :error
    end
  rescue
    ArgumentError -> :error
  end

  def resolve_module(_type), do: :error

  @doc """
  Normalizes the **first-level** keys of a stored event `data` map back to the
  atom-keyed contract produced by `new/2`.

  Given the event `type` string and a `data` map (possibly string-keyed — e.g.
  as decoded from JSON by the EventStoreDB adapter), atomizes **only** the
  top-level keys whose string form matches a declared field of the resolved
  event module. Every other key, and **all values (including nested maps)**, are
  left untouched.

  Contract (deliberately narrow, to stay safe and predictable):

    * If the module cannot be resolved (unknown type, snapshot, non-event), the
      map is returned **unchanged** (string keys preserved). Never raises.
    * No dynamic atom creation: the target atoms are the already-existing field
      atoms declared at compile time.
    * Shallow only: nested values are NOT recursed into. Converting nested
      enums / datetimes / value objects is the **domain's** responsibility, not
      the transport layer's.
  """
  @spec atomize_data(String.t(), map()) :: map()
  def atomize_data(type, data) when is_map(data) do
    case resolve_module(type) do
      {:ok, module} ->
        known = Enum.map(module.field_definitions(), fn {name, _type, _opts} -> name end)
        atomize_known_keys(data, known)

      :error ->
        data
    end
  end

  def atomize_data(_type, data), do: data

  @doc """
  Atomizes only the first-level keys of `map` whose string form is one of
  `known_atoms`. Keys already atoms are kept as-is; any other key (a string not
  in `known_atoms`, or any non-string key) and every value are left unchanged.

  Creates no new atoms — the atomized keys come exclusively from `known_atoms`.
  Idempotent: applying it to an already-normalized map is a no-op.
  """
  @spec atomize_known_keys(map(), [atom()]) :: map()
  def atomize_known_keys(map, known_atoms) when is_map(map) do
    lookup = Map.new(known_atoms, fn atom -> {Atom.to_string(atom), atom} end)

    Map.new(map, fn {key, value} ->
      case key do
        key when is_binary(key) ->
          {Map.get(lookup, key, key), value}

        key ->
          {key, value}
      end
    end)
  end
end
