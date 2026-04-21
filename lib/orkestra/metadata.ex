defmodule Orkestra.Metadata do
  @moduledoc """
  Metadata carried by every command and event envelope.

  Contains correlation, causation, identity, and timing information
  that flows through the entire command/event pipeline.
  """

  @type t :: %__MODULE__{
          correlation_id: String.t(),
          causation_id: String.t() | nil,
          actor_id: String.t() | nil,
          actor_type: atom(),
          issued_at: DateTime.t(),
          source: String.t() | nil
        }

  @enforce_keys [:correlation_id, :issued_at]
  defstruct [
    :correlation_id,
    :causation_id,
    :actor_id,
    :source,
    actor_type: :system,
    issued_at: nil
  ]

  @doc """
  Creates new metadata with a fresh correlation_id.

  ## Options
  - `:actor_id` — who is issuing this (user id, system name, etc.)
  - `:actor_type` — `:user`, `:system`, `:expert`, `:scheduler`
  - `:source` — where this originated (e.g. "web", "api", "cli", "rabbitmq")
  - `:causation_id` — id of the command/event that caused this one
  """
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    %__MODULE__{
      correlation_id: Keyword.get(opts, :correlation_id, generate_id()),
      causation_id: Keyword.get(opts, :causation_id),
      actor_id: Keyword.get(opts, :actor_id),
      actor_type: Keyword.get(opts, :actor_type, :system),
      source: Keyword.get(opts, :source),
      issued_at: DateTime.utc_now()
    }
  end

  @doc """
  Derives child metadata from a parent, preserving correlation and setting causation.
  """
  @spec derive(t(), String.t()) :: t()
  def derive(%__MODULE__{} = parent, causation_id) do
    %__MODULE__{
      correlation_id: parent.correlation_id,
      causation_id: causation_id,
      actor_id: parent.actor_id,
      actor_type: parent.actor_type,
      source: parent.source,
      issued_at: DateTime.utc_now()
    }
  end

  defp generate_id do
    Base.hex_encode32(:crypto.strong_rand_bytes(16), case: :lower, padding: false)
  end
end
