defmodule Orkestra.ES.Schema.Casting do
  @moduledoc """
  Converts between an `Orkestra.ES.Schema` struct and its Elasticsearch
  document representation.

  `to_doc/4` turns a struct into a string-keyed map ready for indexing;
  `from_hit/5` rebuilds the struct from an `_source` map. The two are inverse
  for valid values, so `from_hit(to_doc(struct)) == struct`.

  Casting rules:

    * `Date` / `DateTime` values serialize to ISO8601 and are parsed back based
      on the runtime value (a string containing `"T"` is read as a `DateTime`,
      otherwise as a `Date`). A field declared with a custom `format:` keeps its
      raw string on the way back, since the library cannot interpret arbitrary
      ES date patterns.
    * `nil` values are preserved as `null`, keeping the round-trip faithful.
    * The facets slot is **flattened** on write (one entry per value) and
      **regrouped** on read (by `attr_code`, preserving the first-seen order and
      `attr_name`); read values always get `count: nil`.
    * Embeds recurse through the embedded schema's own `to_doc/1` /
      `from_hit/1` (multi-level embeds included): an `embeds_one` value of
      `nil` stays `null`; an `embeds_many` list maps element-wise, and a
      missing/`null` array reads back as `[]`.

  The module is pure and has no dependency on Snap.
  """

  alias Orkestra.ES.Facet
  alias Orkestra.ES.Schema.Compiler

  @doc """
  Converts a schema struct into a string-keyed Elasticsearch document.
  """
  @spec to_doc(struct(), [Compiler.field_meta()], atom() | nil, [Compiler.embed_meta()]) :: map()
  def to_doc(struct, field_meta, facets_field, embeds_meta \\ []) do
    base =
      Enum.reduce(field_meta, %{}, fn %{name: name, type: type, opts: opts}, acc ->
        Map.put(acc, Atom.to_string(name), encode_value(Map.get(struct, name), type, opts))
      end)

    base =
      Enum.reduce(embeds_meta, base, fn embed, acc ->
        Map.put(acc, Atom.to_string(embed.name), encode_embed(Map.get(struct, embed.name), embed))
      end)

    if facets_field do
      flat = flatten_facets(Map.get(struct, facets_field) || [])
      Map.put(base, Atom.to_string(facets_field), flat)
    else
      base
    end
  end

  @doc """
  Rebuilds a schema struct of `module` from an Elasticsearch `_source` map.
  """
  @spec from_hit(map(), module(), [Compiler.field_meta()], atom() | nil, [Compiler.embed_meta()]) ::
          struct()
  def from_hit(source, module, field_meta, facets_field, embeds_meta \\ []) do
    base =
      Enum.map(field_meta, fn %{name: name, type: type, opts: opts} ->
        {name, decode_value(Map.get(source, Atom.to_string(name)), type, opts)}
      end)

    embed_kv =
      Enum.map(embeds_meta, fn embed ->
        {embed.name, decode_embed(Map.get(source, Atom.to_string(embed.name)), embed)}
      end)

    facet_kv =
      if facets_field do
        grouped = group_facets(Map.get(source, Atom.to_string(facets_field)) || [])
        [{facets_field, grouped}]
      else
        []
      end

    struct(module, base ++ embed_kv ++ facet_kv)
  end

  # -- embeds -----------------------------------------------------------------

  # Encoding recurses through the embedded schema's generated `to_doc/1`, so
  # multi-level embeds serialize naturally.
  defp encode_embed(nil, _embed), do: nil

  defp encode_embed(list, %{cardinality: :many, schema: schema}) when is_list(list),
    do: Enum.map(list, &schema.to_doc/1)

  defp encode_embed(value, %{cardinality: :one, schema: schema}), do: schema.to_doc(value)

  # Decoding mirrors encoding via the embedded schema's `from_hit/1`. A
  # missing/null `embeds_many` reads back as `[]` (the struct default).
  defp decode_embed(nil, %{cardinality: :many}), do: []
  defp decode_embed(nil, %{cardinality: :one}), do: nil

  defp decode_embed(list, %{cardinality: :many, schema: schema}) when is_list(list),
    do: Enum.map(list, &schema.from_hit/1)

  defp decode_embed(value, %{cardinality: :one, schema: schema}) when is_map(value),
    do: schema.from_hit(value)

  # -- encoding ---------------------------------------------------------------

  defp encode_value(nil, _type, _opts), do: nil

  defp encode_value(list, {:array, inner}, opts) when is_list(list),
    do: Enum.map(list, &encode_scalar(&1, inner, opts))

  defp encode_value(value, type, opts), do: encode_scalar(value, type, opts)

  defp encode_scalar(%Date{} = date, :date, _opts), do: Date.to_iso8601(date)
  defp encode_scalar(%DateTime{} = datetime, :date, _opts), do: DateTime.to_iso8601(datetime)
  defp encode_scalar(value, _type, _opts), do: value

  # -- decoding ---------------------------------------------------------------

  defp decode_value(nil, _type, _opts), do: nil

  defp decode_value(list, {:array, inner}, opts) when is_list(list),
    do: Enum.map(list, &decode_scalar(&1, inner, opts))

  defp decode_value(value, type, opts), do: decode_scalar(value, type, opts)

  defp decode_scalar(value, :date, opts) when is_binary(value) do
    if Keyword.has_key?(opts, :format) do
      value
    else
      parse_date(value)
    end
  end

  defp decode_scalar(value, _type, _opts), do: value

  defp parse_date(value) do
    if String.contains?(value, "T") do
      case DateTime.from_iso8601(value) do
        {:ok, datetime, _offset} -> datetime
        _ -> value
      end
    else
      case Date.from_iso8601(value) do
        {:ok, date} -> date
        _ -> value
      end
    end
  end

  # -- facets -----------------------------------------------------------------

  defp flatten_facets(attributes) do
    Enum.flat_map(attributes, fn %Facet.Attribute{code: code, name: name, values: values} ->
      Enum.map(values, fn %Facet.Value{code: value_code, name: value_name} ->
        %{
          "attr_code" => code,
          "attr_name" => name,
          "value_code" => value_code,
          "value_name" => value_name
        }
      end)
    end)
  end

  defp group_facets(entries) do
    {order, by_code} =
      Enum.reduce(entries, {[], %{}}, fn entry, {order, acc} ->
        code = entry["attr_code"]
        value = %Facet.Value{code: entry["value_code"], name: entry["value_name"], count: nil}

        case Map.get(acc, code) do
          nil ->
            attribute = %Facet.Attribute{code: code, name: entry["attr_name"], values: [value]}
            {order ++ [code], Map.put(acc, code, attribute)}

          %Facet.Attribute{values: values} = attribute ->
            {order, Map.put(acc, code, %{attribute | values: values ++ [value]})}
        end
      end)

    Enum.map(order, &Map.get(by_code, &1))
  end
end
