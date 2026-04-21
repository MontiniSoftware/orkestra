defmodule Orkestra.CommandEnvelope do
  @moduledoc """
  Wraps a command with dispatch context: routing, retries, and lifecycle tracking.

  The envelope is what the dispatcher and middleware operate on.
  The command itself is immutable once created; the envelope
  accumulates context as it flows through the pipeline.

  ## Structure

      %CommandEnvelope{
        command: %StartAssessment{...},
        status: :pending,
        dispatched_at: nil,
        completed_at: nil,
        result: nil,
        error: nil,
        attempts: 0,
        max_retries: 0,
        middleware_context: %{}
      }
  """

  alias Orkestra.Command

  @type status :: :pending | :dispatched | :succeeded | :failed | :rejected

  @type t :: %__MODULE__{
          command: Command.t(),
          status: status(),
          dispatched_at: DateTime.t() | nil,
          completed_at: DateTime.t() | nil,
          result: term(),
          error: term(),
          attempts: non_neg_integer(),
          max_retries: non_neg_integer(),
          middleware_context: map()
        }

  @enforce_keys [:command]
  defstruct [
    :command,
    :dispatched_at,
    :completed_at,
    :result,
    :error,
    status: :pending,
    attempts: 0,
    max_retries: 0,
    middleware_context: %{}
  ]

  @doc """
  Wraps a command in an envelope.

  ## Options
  - `:max_retries` — number of retry attempts on failure (default: 0)
  """
  @spec wrap(Command.t(), keyword()) :: t()
  def wrap(%{__struct__: _} = command, opts \\ []) do
    %__MODULE__{
      command: command,
      max_retries: Keyword.get(opts, :max_retries, 0)
    }
  end

  @doc "Marks the envelope as dispatched."
  @spec mark_dispatched(t()) :: t()
  def mark_dispatched(%__MODULE__{} = env) do
    %{env | status: :dispatched, dispatched_at: DateTime.utc_now(), attempts: env.attempts + 1}
  end

  @doc "Marks the envelope as succeeded with a result."
  @spec mark_succeeded(t(), term()) :: t()
  def mark_succeeded(%__MODULE__{} = env, result) do
    %{env | status: :succeeded, result: result, completed_at: DateTime.utc_now()}
  end

  @doc "Marks the envelope as failed with an error."
  @spec mark_failed(t(), term()) :: t()
  def mark_failed(%__MODULE__{} = env, error) do
    %{env | status: :failed, error: error, completed_at: DateTime.utc_now()}
  end

  @doc "Marks the envelope as rejected (e.g. validation or authorization failure)."
  @spec mark_rejected(t(), term()) :: t()
  def mark_rejected(%__MODULE__{} = env, reason) do
    %{env | status: :rejected, error: reason, completed_at: DateTime.utc_now()}
  end

  @doc "Whether the envelope can be retried."
  @spec retryable?(t()) :: boolean()
  def retryable?(%__MODULE__{status: :failed, attempts: attempts, max_retries: max}) do
    attempts <= max
  end

  def retryable?(_), do: false

  @doc "Returns the command id."
  @spec command_id(t()) :: String.t()
  def command_id(%__MODULE__{command: cmd}), do: cmd.id

  @doc "Returns the command type."
  @spec command_type(t()) :: String.t()
  def command_type(%__MODULE__{command: cmd}), do: cmd.type

  @doc "Returns the command metadata."
  @spec metadata(t()) :: Orkestra.Metadata.t() | nil
  def metadata(%__MODULE__{command: cmd}), do: cmd.metadata

  @doc "Stores a value in the middleware context."
  @spec put_context(t(), atom(), term()) :: t()
  def put_context(%__MODULE__{} = env, key, value) do
    %{env | middleware_context: Map.put(env.middleware_context, key, value)}
  end

  @doc "Gets a value from the middleware context."
  @spec get_context(t(), atom(), term()) :: term()
  def get_context(%__MODULE__{} = env, key, default \\ nil) do
    Map.get(env.middleware_context, key, default)
  end
end
