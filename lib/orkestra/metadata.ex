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

  @doc """
  The known first-level keys of `%Orkestra.Metadata{}`.

  These are the only keys `normalize_map/1` is allowed to atomize.
  """
  @spec field_keys() :: [atom()]
  def field_keys do
    __struct__() |> Map.from_struct() |> Map.keys()
  end

  @doc """
  Normalizes a stored/decoded metadata **map** to the first-level key contract
  of `%Orkestra.Metadata{}`.

  Atomizes only the known metadata keys (the fields of `%Orkestra.Metadata{}`,
  see `field_keys/0`); custom keys (kept as strings) and all values are left
  untouched. Returns a plain map
  — **not** a `%Orkestra.Metadata{}` struct — so custom metadata keys the host
  attached (e.g. request/tenant tags) survive the round-trip. Shallow only, and
  never raises.

  Used by the EventStoreDB adapter so metadata decoded from JSON (string keys)
  matches the shape a caller would read via atom keys, at parity with the
  InMemory adapter's atom-keyed known fields.
  """
  @spec normalize_map(map()) :: map()
  def normalize_map(map) when is_map(map) do
    Orkestra.Event.atomize_known_keys(map, field_keys())
  end

  def normalize_map(other), do: other

  defp generate_id do
    Base.hex_encode32(:crypto.strong_rand_bytes(16), case: :lower, padding: false)
  end
end
