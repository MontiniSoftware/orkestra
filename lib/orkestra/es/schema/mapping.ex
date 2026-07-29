defmodule Orkestra.ES.Schema.Mapping do
  @moduledoc """
  Builds the full Elasticsearch index mapping for an `Orkestra.ES.Schema`.

  Produces a string-keyed map ready to hand to `Snap.Indexes.create/3`, made of
  a `"settings"` block (index-level options plus the per-culture `"analysis"`
  definitions) and a `"mappings"` block with `"dynamic" => "strict"` always
  injected and one property per declared field.

  The module is pure — it only manipulates maps, lists, atoms and strings; it
  never performs I/O and has no dependency on Snap. It also exposes
  `mapping_hash/1`, a deterministic SHA-256 fingerprint used by the index
  lifecycle to detect mapping drift.
  """

  alias Orkestra.ES.Schema.Compiler

  @doc """
  Builds the complete mapping for `culture`.

  `culture` is `nil` for mono-culture schemas; otherwise it selects the
  matching per-culture analysis definitions. A definition without `for:` acts
  as a shared fallback and is always included.

  `embeds_meta` (see `Orkestra.ES.Schema.Compiler.embed_meta/0`) contributes
  one `"object"`/`"nested"` property per embed, whose `"properties"` are built
  recursively from the embedded schema (multi-level embeds included).
  `"dynamic" => "strict"` is set only at the mapping top level — Elasticsearch
  inherits it down into object and nested properties.
  """
  @spec build(
          [Compiler.field_meta()],
          atom() | nil,
          [Compiler.embed_meta()],
          keyword(),
          [tuple()],
          atom() | nil
        ) :: map()
  def build(field_meta, facets_field, embeds_meta, settings_opts, analysis, culture) do
    mappings = %{
      "dynamic" => "strict",
      "properties" => properties(field_meta, facets_field, embeds_meta)
    }

    case build_settings(settings_opts, analysis, culture) do
      nil -> %{"mappings" => mappings}
      settings -> %{"settings" => settings, "mappings" => mappings}
    end
  end

  @doc """
  Builds the `"properties"` map for a set of fields, an optional facets slot,
  and a list of embeds.

  Each embed becomes `%{"type" => "object" | "nested", "properties" => ...}`
  where the inner properties come from the embedded schema's own fields and
  embeds, recursively. Public because it is the recursion step used for every
  level of an embed tree.
  """
  @spec properties([Compiler.field_meta()], atom() | nil, [Compiler.embed_meta()]) :: map()
  def properties(field_meta, facets_field, embeds_meta) do
    field_meta
    |> build_properties(facets_field)
    |> Map.merge(embed_properties(embeds_meta))
  end

  defp embed_properties(embeds_meta) do
    Map.new(embeds_meta, fn %{name: name, schema: schema, mode: mode} ->
      inner =
        properties(
          schema.__es_schema__(:fields),
          schema.__es_schema__(:facets_field),
          schema.__es_schema__(:embeds)
        )

      {Atom.to_string(name), %{"type" => embed_type(mode), "properties" => inner}}
    end)
  end

  defp embed_type(:nested), do: "nested"
  defp embed_type(:object), do: "object"

  @doc """
  Returns the lowercase hexadecimal SHA-256 of a deterministic serialization
  of `mapping`.

  Map keys are sorted recursively before hashing, so the result never depends
  on map insertion order: identical mappings always hash to the same value and
  different mappings (e.g. two cultures with different analysis) hash
  differently.
  """
  @spec mapping_hash(map()) :: String.t()
  def mapping_hash(mapping) do
    :sha256
    |> :crypto.hash(canonical(mapping))
    |> Base.encode16(case: :lower)
  end

  @doc """
  Filters `analysis` definitions applicable to `culture`.

  A definition applies when its `for:` equals `culture` or when it has no
  `for:` (shared fallback). For a mono-culture schema (`culture == nil`) only
  the shared fallbacks apply.
  """
  @spec applicable_defs([tuple()], atom() | nil) :: [tuple()]
  def applicable_defs(analysis, culture) do
    Enum.filter(analysis, fn {_cat, _name, opts} ->
      case Keyword.get(opts, :for) do
        nil -> true
        ^culture -> true
        _ -> false
      end
    end)
  end

  # -- properties -------------------------------------------------------------

  defp build_properties(field_meta, facets_field) do
    props = Map.new(field_meta, fn meta -> {Atom.to_string(meta.name), property_for(meta)} end)

    if facets_field do
      Map.put(props, Atom.to_string(facets_field), facets_property())
    else
      props
    end
  end

  defp property_for(%{type: {:array, inner}, opts: opts}), do: scalar_property(inner, opts)
  defp property_for(%{type: type, opts: opts}), do: scalar_property(type, opts)

  defp scalar_property(:text, opts) do
    base = %{"type" => "text"}

    base =
      case Keyword.get(opts, :analyzer) do
        nil -> base
        analyzer -> Map.put(base, "analyzer", to_string(analyzer))
      end

    # `sortable:` on a :text field implies the keyword subfield used for sorting.
    if Keyword.get(opts, :keyword) || Keyword.get(opts, :sortable) do
      Map.put(base, "fields", %{"keyword" => %{"type" => "keyword"}})
    else
      base
    end
  end

  defp scalar_property(:date, opts) do
    base = %{"type" => "date"}

    case Keyword.get(opts, :format) do
      nil -> base
      format -> Map.put(base, "format", to_string(format))
    end
  end

  defp scalar_property(type, _opts)
       when type in [:keyword, :integer, :long, :float, :double, :boolean] do
    %{"type" => Atom.to_string(type)}
  end

  defp facets_property do
    %{
      "type" => "nested",
      "properties" => %{
        "attr_code" => %{"type" => "keyword"},
        "attr_name" => %{"type" => "keyword"},
        "value_code" => %{"type" => "keyword"},
        "value_name" => %{"type" => "keyword"}
      }
    }
  end

  # -- settings / analysis ----------------------------------------------------

  defp build_settings(settings_opts, analysis, culture) do
    opts_map = Map.new(settings_opts, fn {k, v} -> {to_string(k), jsonify(v)} end)
    analysis_map = build_analysis(analysis, culture)

    merged =
      if map_size(analysis_map) > 0 do
        Map.put(opts_map, "analysis", analysis_map)
      else
        opts_map
      end

    if map_size(merged) == 0, do: nil, else: merged
  end

  defp build_analysis(analysis, culture) do
    analysis
    |> applicable_defs(culture)
    |> Enum.group_by(fn {category, _name, _opts} -> category end)
    |> Map.new(fn {category, defs} ->
      entries =
        defs
        # A `for:`-specific definition overrides a shared fallback of the same name.
        |> Enum.sort_by(fn {_cat, _name, opts} -> if Keyword.get(opts, :for), do: 1, else: 0 end)
        |> Map.new(fn {_cat, name, opts} ->
          {to_string(name), opts |> Keyword.delete(:for) |> jsonify()}
        end)

      {Atom.to_string(category), entries}
    end)
  end

  # -- JSON coercion / canonicalization ---------------------------------------

  # Coerces DSL values into JSON-compatible forms: atoms become strings (so a
  # `:stemmer_it` filter reference serializes to `"stemmer_it"`), keyword lists
  # and maps become string-keyed objects, lists map recursively.
  defp jsonify(value)
       when is_boolean(value) or is_nil(value) or is_binary(value) or is_number(value),
       do: value

  defp jsonify(value) when is_atom(value), do: Atom.to_string(value)

  defp jsonify(value) when is_list(value) do
    if keyword?(value) do
      Map.new(value, fn {k, v} -> {to_string(k), jsonify(v)} end)
    else
      Enum.map(value, &jsonify/1)
    end
  end

  defp jsonify(value) when is_map(value) do
    Map.new(value, fn {k, v} -> {to_string(k), jsonify(v)} end)
  end

  defp keyword?([]), do: false
  defp keyword?(list), do: Enum.all?(list, fn el -> match?({k, _} when is_atom(k), el) end)

  defp canonical(term) when is_map(term) do
    inner =
      term
      |> Enum.sort_by(fn {k, _v} -> to_string(k) end)
      |> Enum.map(fn {k, v} -> [?", to_string(k), ?", ?:, canonical(v)] end)
      |> Enum.intersperse(?,)

    [?{, inner, ?}]
  end

  defp canonical(term) when is_list(term) do
    inner = term |> Enum.map(&canonical/1) |> Enum.intersperse(?,)
    [?[, inner, ?]]
  end

  defp canonical(term) when is_binary(term), do: [?", term, ?"]
  defp canonical(term), do: to_string(term)
end
