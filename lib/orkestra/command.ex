defmodule Orkestra.Command do
  @moduledoc """
  Behaviour and struct builder for CQRS commands.

  A command represents an intent to change the system state.
  Commands are validated, authorized, and dispatched to a handler.

  ## Defining a command

      defmodule MyApp.Tasks.Commands.StartAssessment do
        use Orkestra.Command

        param :repo, :string, required: true
        param :branch, :string, default: "main"
        param :expert_name, :string, required: true
        param :action_name, :string, required: true
        param :montini_software_folder_url, :string, required: true
        param :action_params, :map, default: %{}
      end

  ## Building a command

      {:ok, cmd} = StartAssessment.new(%{
        repo: "owner/repo",
        expert_name: "architect",
        action_name: "perform-assessment",
        montini_software_folder_url: "tasks/task_123"
      })

      cmd.id           # auto-generated
      cmd.params.repo  # "owner/repo"
  """

  @type t :: %{
          __struct__: atom(),
          id: String.t(),
          type: String.t(),
          params: map(),
          metadata: Orkestra.Metadata.t() | nil
        }

  @callback param_definitions() :: [param_definition()]
  @callback validate(map()) :: :ok | {:error, term()}

  @type param_definition :: {atom(), atom(), keyword()}

  defmacro __using__(_opts) do
    quote do
      @behaviour Orkestra.Command

      Module.register_attribute(__MODULE__, :param_defs, accumulate: true)

      import Orkestra.Command, only: [param: 2, param: 3]

      @before_compile Orkestra.Command

      @impl true
      def validate(_params), do: :ok

      defoverridable validate: 1
    end
  end

  @doc "Declares a command parameter."
  defmacro param(name, type, opts \\ []) do
    quote do
      @param_defs {unquote(name), unquote(type), unquote(opts)}
    end
  end

  defmacro __before_compile__(env) do
    param_defs = Module.get_attribute(env.module, :param_defs) |> Enum.reverse()

    param_keys =
      Enum.map(param_defs, fn {name, _type, opts} ->
        default = Keyword.get(opts, :default)
        {name, default}
      end)

    required =
      param_defs
      |> Enum.filter(fn {_name, _type, opts} -> Keyword.get(opts, :required, false) end)
      |> Enum.map(fn {name, _type, _opts} -> name end)

    type_name =
      env.module
      |> Module.split()
      |> Enum.map_join(".", & &1)

    quote do
      defstruct id: nil,
                type: unquote(type_name),
                params: %{},
                metadata: nil

      @impl true
      def param_definitions, do: unquote(Macro.escape(param_defs))

      @doc "Creates a new command from a map of params."
      @spec new(map(), keyword()) ::
              {:ok, Orkestra.Command.t()} | {:error, term()}
      def new(params, opts \\ []) do
        alias Orkestra.Metadata

        params = normalize_params(params)

        with :ok <- check_required(params),
             :ok <- validate(params) do
          cmd = %__MODULE__{
            id: Orkestra.Command.generate_id(),
            params: build_params(params),
            metadata: Keyword.get(opts, :metadata) || Metadata.new(opts)
          }

          {:ok, cmd}
        end
      end

      @doc "Creates a new command, raising on failure."
      @spec new!(map(), keyword()) :: Orkestra.Command.t()
      def new!(params, opts \\ []) do
        case new(params, opts) do
          {:ok, cmd} -> cmd
          {:error, reason} -> raise "Command validation failed: #{inspect(reason)}"
        end
      end

      defp normalize_params(params) when is_map(params) do
        Map.new(params, fn
          {k, v} when is_binary(k) -> {String.to_existing_atom(k), v}
          {k, v} when is_atom(k) -> {k, v}
        end)
      rescue
        ArgumentError -> params
      end

      defp check_required(params) do
        missing =
          unquote(required)
          |> Enum.reject(fn key ->
            case Map.get(params, key) do
              nil -> false
              "" -> false
              _ -> true
            end
          end)

        case missing do
          [] -> :ok
          keys -> {:error, {:missing_params, keys}}
        end
      end

      defp build_params(params) do
        defaults = Map.new(unquote(Macro.escape(param_keys)))
        Map.merge(defaults, Map.take(params, Map.keys(defaults)))
      end
    end
  end

  def generate_id do
    Base.hex_encode32(:crypto.strong_rand_bytes(12), case: :lower, padding: false)
  end
end
