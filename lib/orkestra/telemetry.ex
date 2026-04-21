defmodule Orkestra.Telemetry do
  @moduledoc """
  OpenTelemetry tracing and structured logging helpers for Orkestra.

  Provides span creation, attribute extraction, and trace context
  propagation for the CQRS pipeline.
  """

  require OpenTelemetry.Tracer, as: Tracer

  alias Orkestra.{CommandEnvelope, EventEnvelope, Metadata}

  # ── Span helpers ────────────────────────────────────────────────

  @doc """
  Wraps a function in a named span with Orkestra attributes.
  Automatically sets span status to error on `{:error, _}` returns.
  """
  def with_span(name, attrs, fun) when is_function(fun, 0) do
    Tracer.with_span name, %{attributes: attrs} do
      case fun.() do
        {:error, reason} = err ->
          Tracer.set_status(:error, inspect(reason))
          Tracer.add_event("error", %{"error.reason" => inspect(reason)})
          err

        result ->
          result
      end
    end
  end

  @doc "Creates span attributes from a command envelope."
  def command_attrs(%CommandEnvelope{command: cmd}) do
    base = %{
      "orkestra.command.type" => cmd.type,
      "orkestra.command.id" => cmd.id
    }

    Map.merge(base, metadata_attrs(cmd.metadata))
  end

  @doc "Creates span attributes from an event envelope."
  def event_attrs(%EventEnvelope{event: event}) do
    base = %{
      "orkestra.event.type" => event.type,
      "orkestra.event.id" => event.id
    }

    Map.merge(base, metadata_attrs(event.metadata))
  end

  @doc "Creates span attributes from Orkestra metadata."
  def metadata_attrs(nil), do: %{}

  def metadata_attrs(%Metadata{} = meta) do
    %{
      "orkestra.correlation_id" => meta.correlation_id,
      "orkestra.causation_id" => meta.causation_id || "",
      "orkestra.actor_id" => meta.actor_id || "",
      "orkestra.actor_type" => to_string(meta.actor_type),
      "orkestra.source" => meta.source || ""
    }
  end

  # ── Logger metadata ─────────────────────────────────────────────

  @doc """
  Sets Logger metadata from Orkestra metadata for the current process.
  Also injects `trace_id` and `span_id` from the current OTel context
  so that logs can be correlated with traces in SigNoz.
  Call this at the start of handler execution.
  """
  def set_logger_metadata(%Metadata{} = meta) do
    otel_meta = extract_otel_context()
    Logger.metadata(metadata_to_logger(meta) ++ otel_meta)
  end

  def set_logger_metadata(nil) do
    Logger.metadata(extract_otel_context())
  end

  @doc "Clears Orkestra-specific Logger metadata."
  def clear_logger_metadata do
    Logger.metadata(
      correlation_id: nil,
      causation_id: nil,
      actor_id: nil,
      actor_type: nil,
      orkestra_source: nil
    )
  end

  @doc "Converts Metadata to a Logger-compatible keyword list."
  def metadata_to_logger(%Metadata{} = meta) do
    [
      correlation_id: meta.correlation_id,
      causation_id: meta.causation_id,
      actor_id: meta.actor_id,
      actor_type: meta.actor_type,
      orkestra_source: meta.source
    ]
    |> Enum.reject(fn {_, v} -> is_nil(v) end)
  end

  def metadata_to_logger(nil), do: []

  # ── OTel context extraction ────────────────────────────────────

  defp extract_otel_context do
    span_ctx = OpenTelemetry.Tracer.current_span_ctx()

    case span_ctx do
      :undefined ->
        []

      _ ->
        trace_id = span_ctx |> elem(1) |> format_trace_id()
        span_id = span_ctx |> elem(3) |> format_span_id()
        [trace_id: trace_id, span_id: span_id]
    end
  rescue
    _ -> []
  end

  defp format_trace_id(id) when is_integer(id) and id > 0 do
    id |> Integer.to_string(16) |> String.downcase() |> String.pad_leading(32, "0")
  end

  defp format_trace_id(_), do: nil

  defp format_span_id(id) when is_integer(id) and id > 0 do
    id |> Integer.to_string(16) |> String.downcase() |> String.pad_leading(16, "0")
  end

  defp format_span_id(_), do: nil

  # ── AMQP trace context propagation ──────────────────────────────

  @doc """
  Injects the current OTel trace context into AMQP-compatible headers.
  Returns a list of `{key, :longstr, value}` tuples.
  """
  def inject_context_to_headers do
    setter = fn key, value, carrier -> Map.put(carrier, key, value) end
    carrier = :otel_propagator_text_map.inject(%{}, setter, [])

    Enum.map(carrier, fn {k, v} ->
      {to_string(k), :longstr, to_string(v)}
    end)
  rescue
    _ -> []
  end

  @doc """
  Extracts OTel trace context from AMQP headers into the current process.
  """
  def extract_context_from_headers(nil), do: :ok
  def extract_context_from_headers([]), do: :ok

  def extract_context_from_headers(headers) when is_list(headers) do
    carrier =
      headers
      |> Enum.reduce(%{}, fn
        {key, _, value}, acc when is_binary(key) and is_binary(value) ->
          Map.put(acc, key, value)

        _, acc ->
          acc
      end)

    if map_size(carrier) > 0 do
      getter = fn key, carrier, _default -> Map.get(carrier, key, "") end
      :otel_propagator_text_map.extract(carrier, Map.keys(carrier), getter, [])
    end

    :ok
  rescue
    _ -> :ok
  end
end
