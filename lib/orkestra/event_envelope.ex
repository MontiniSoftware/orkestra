defmodule Orkestra.EventEnvelope do
  @moduledoc """
  Wraps a domain event with dispatch and delivery context.

  Unlike command envelopes, event envelopes track delivery to
  multiple handlers. An event is a broadcast — it can be handled
  by many subscribers, each tracked independently.

  ## Structure

      %EventEnvelope{
        event: %AssessmentCompleted{...},
        status: :pending,
        published_at: nil,
        handlers: %{
          "GenerateReport" => :succeeded,
          "NotifyUser" => :pending
        }
      }
  """

  alias Orkestra.Event

  @type handler_status :: :pending | :processing | :succeeded | :failed | :skipped
  @type status :: :pending | :published | :partially_handled | :handled | :failed

  @type t :: %__MODULE__{
          event: Event.t(),
          status: status(),
          published_at: DateTime.t() | nil,
          handlers: %{String.t() => handler_status()}
        }

  @enforce_keys [:event]
  defstruct [
    :event,
    :published_at,
    status: :pending,
    handlers: %{}
  ]

  @doc "Wraps an event in an envelope."
  @spec wrap(Event.t()) :: t()
  def wrap(%{__struct__: _} = event) do
    %__MODULE__{event: event}
  end

  @doc "Marks the envelope as published."
  @spec mark_published(t()) :: t()
  def mark_published(%__MODULE__{} = env) do
    %{env | status: :published, published_at: DateTime.utc_now()}
  end

  @doc "Registers a handler for tracking."
  @spec register_handler(t(), String.t()) :: t()
  def register_handler(%__MODULE__{} = env, handler_name) do
    %{env | handlers: Map.put(env.handlers, handler_name, :pending)}
  end

  @doc "Marks a specific handler as processing."
  @spec mark_handler_processing(t(), String.t()) :: t()
  def mark_handler_processing(%__MODULE__{} = env, handler_name) do
    update_handler(env, handler_name, :processing)
  end

  @doc "Marks a specific handler as succeeded."
  @spec mark_handler_succeeded(t(), String.t()) :: t()
  def mark_handler_succeeded(%__MODULE__{} = env, handler_name) do
    env
    |> update_handler(handler_name, :succeeded)
    |> recalculate_status()
  end

  @doc "Marks a specific handler as failed."
  @spec mark_handler_failed(t(), String.t()) :: t()
  def mark_handler_failed(%__MODULE__{} = env, handler_name) do
    env
    |> update_handler(handler_name, :failed)
    |> recalculate_status()
  end

  @doc "Marks a specific handler as skipped."
  @spec mark_handler_skipped(t(), String.t()) :: t()
  def mark_handler_skipped(%__MODULE__{} = env, handler_name) do
    env
    |> update_handler(handler_name, :skipped)
    |> recalculate_status()
  end

  @doc "Returns the event id."
  @spec event_id(t()) :: String.t()
  def event_id(%__MODULE__{event: event}), do: event.id

  @doc "Returns the event type."
  @spec event_type(t()) :: String.t()
  def event_type(%__MODULE__{event: event}), do: event.type

  @doc "Returns the event metadata."
  @spec metadata(t()) :: Orkestra.Metadata.t() | nil
  def metadata(%__MODULE__{event: event}), do: event.metadata

  @doc "Whether all handlers have completed (succeeded, failed, or skipped)."
  @spec all_handled?(t()) :: boolean()
  def all_handled?(%__MODULE__{handlers: handlers}) when map_size(handlers) == 0, do: true

  def all_handled?(%__MODULE__{handlers: handlers}) do
    Enum.all?(handlers, fn {_name, status} -> status in [:succeeded, :failed, :skipped] end)
  end

  # ── Private ─────────────────────────────────────────────────────

  defp update_handler(%__MODULE__{} = env, handler_name, status) do
    %{env | handlers: Map.put(env.handlers, handler_name, status)}
  end

  defp recalculate_status(%__MODULE__{handlers: handlers} = env) when map_size(handlers) == 0 do
    env
  end

  defp recalculate_status(%__MODULE__{handlers: handlers} = env) do
    statuses = Map.values(handlers)
    terminal = [:succeeded, :failed, :skipped]

    cond do
      Enum.all?(statuses, &(&1 in terminal)) and Enum.all?(statuses, &(&1 != :failed)) ->
        %{env | status: :handled}

      Enum.all?(statuses, &(&1 in terminal)) ->
        all_failed = Enum.all?(statuses, &(&1 == :failed))
        %{env | status: if(all_failed, do: :failed, else: :partially_handled)}

      true ->
        env
    end
  end
end
