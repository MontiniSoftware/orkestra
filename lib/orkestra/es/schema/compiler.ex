defmodule Orkestra.ES.Schema.Compiler do
  @moduledoc """
  Compile-time validation for `Orkestra.ES.Schema`.

  This module is invoked from the `use Orkestra.ES.Schema` macro expansion
  (both at `__using__` time for the base options and at `__before_compile__`
  time for fields, facets and analysis definitions). Every failure raises an
  `ArgumentError` whose message cites the schema module and the offending
  field or definition, so mistakes surface with a clear, actionable message.

  It is pure — it never performs I/O and never touches Snap.
  """

  alias Orkestra.ES.Schema.Mapping

  @scalar_types [:keyword, :text, :integer, :long, :float, :double, :boolean, :date, :geo_point]

  # Options that make no sense on a `:geo_point` field and are rejected at
  # compile time. `searchable:`/`analyzer:`/`keyword:` are already text-only,
  # but geo-specific messages make the mistake clearer. `sortable:` is rejected
  # because geo sort is intentionally out of scope (see the module doc).
  @geo_point_forbidden_opts [:searchable, :analyzer, :keyword, :sortable]

  @typedoc "Normalized per-field metadata: `%{name:, type:, opts:}`."
  @type field_meta :: %{name: atom(), type: term(), opts: keyword()}

  @doc """
  Validates the base options passed to `use Orkestra.ES.Schema`.

  For an embedded schema (`embedded?` is `true`) the root-only options
  `:index`, `:cultures` and `:default_culture` are forbidden and raise with a
  clear message. Otherwise it enforces that `:index` is a non-empty string and
  that `:cultures` / `:default_culture` are mutually consistent (a default
  culture is required when cultures are declared and must belong to the list; a
  default culture must not be given without cultures).
  """
  @spec validate_base!(module(), term(), term(), term(), boolean()) :: :ok
  def validate_base!(mod, index, cultures, default_culture, embedded? \\ false)

  def validate_base!(mod, index, cultures, default_culture, true) do
    cond do
      not is_nil(index) ->
        raise ArgumentError,
              "#{inspect(mod)}: an embedded schema (`embedded: true`) must not declare `:index`"

      cultures != [] ->
        raise ArgumentError,
              "#{inspect(mod)}: an embedded schema (`embedded: true`) must not declare `:cultures`"

      not is_nil(default_culture) ->
        raise ArgumentError,
              "#{inspect(mod)}: an embedded schema (`embedded: true`) must not declare " <>
                "`:default_culture`"

      true ->
        :ok
    end
  end

  def validate_base!(mod, index, cultures, default_culture, false) do
    unless is_binary(index) and index != "" do
      raise ArgumentError,
            "#{inspect(mod)}: the `:index` option is required and must be a non-empty string"
    end

    unless is_list(cultures) and Enum.all?(cultures, &is_atom/1) do
      raise ArgumentError, "#{inspect(mod)}: `:cultures` must be a list of atoms"
    end

    cond do
      cultures == [] and not is_nil(default_culture) ->
        raise ArgumentError,
              "#{inspect(mod)}: `:default_culture` was given without `:cultures`"

      cultures != [] and is_nil(default_culture) ->
        raise ArgumentError,
              "#{inspect(mod)}: `:default_culture` is required when `:cultures` is set"

      cultures != [] and default_culture not in cultures ->
        raise ArgumentError,
              "#{inspect(mod)}: `:default_culture` #{inspect(default_culture)} " <>
                "must be one of #{inspect(cultures)}"

      true ->
        :ok
    end
  end

  @typedoc "Normalized embed metadata (see `compile!/8`)."
  @type embed_meta :: %{
          name: atom(),
          schema: module(),
          cardinality: :one | :many,
          mode: :object | :nested
        }

  @doc """
  Validates fields, facets, embeds and analysis definitions accumulated in the
  schema.

  Returns `{field_meta, facets_field, embeds_meta, analyzer_refs}` where
  `field_meta` is the normalized list of `%{name:, type:, opts:}` maps,
  `facets_field` is the atom of the declared facets slot (or `nil`),
  `embeds_meta` is the normalized list of embed maps (see `embed_meta/0`), and
  `analyzer_refs` is the deduplicated list of analyzer atoms referenced by the
  whole embed tree (used by the root for per-culture coverage validation).

  For an embedded schema (`embedded?` is `true`) `:index`/`:cultures`-only
  constructs are forbidden: a `settings` block, a `facets` slot, and any
  `primary_key: true` field all raise. Recursive embedding (an embedded schema
  that itself embeds another) is allowed. Raises `ArgumentError` on any
  violation.
  """
  @spec compile!(
          module(),
          [tuple()],
          [atom()],
          [tuple()],
          keyword(),
          [atom()],
          [tuple()],
          boolean()
        ) ::
          {[field_meta()], atom() | nil, [embed_meta()], [atom()]}
  def compile!(mod, fields, facets, analysis, settings_opts, cultures, embeds, embedded?) do
    field_meta =
      Enum.map(fields, fn {name, type, opts} -> %{name: name, type: type, opts: opts} end)

    validate_fields!(mod, field_meta, embedded?)
    facets_field = validate_facets!(mod, facets, field_meta, embedded?)
    embeds_meta = validate_embeds!(mod, embeds, field_meta, facets_field)

    if embedded?, do: validate_embedded_settings!(mod, analysis, settings_opts)

    analyzer_refs = collect_analyzer_refs(field_meta, embeds_meta)

    unless embedded?, do: validate_analysis!(mod, analyzer_refs, analysis, cultures)

    {field_meta, facets_field, embeds_meta, analyzer_refs}
  end

  defp validate_fields!(mod, field_meta, embedded?) do
    names = Enum.map(field_meta, & &1.name)
    duplicates = names -- Enum.uniq(names)

    unless duplicates == [] do
      raise ArgumentError,
            "#{inspect(mod)}: duplicate field(s) #{inspect(Enum.uniq(duplicates))}"
    end

    primary_keys = for %{name: n, opts: o} <- field_meta, o[:primary_key], do: n

    if embedded? and primary_keys != [] do
      raise ArgumentError,
            "#{inspect(mod)}: an embedded schema must not declare a `primary_key` field " <>
              "(found #{inspect(primary_keys)}); the `_id` is owned by the root document"
    end

    Enum.each(field_meta, &validate_field!(mod, &1))

    unless embedded?, do: validate_primary_key!(mod, primary_keys)
  end

  defp validate_primary_key!(mod, primary_keys) do
    case primary_keys do
      [_one] ->
        :ok

      [] ->
        raise ArgumentError,
              "#{inspect(mod)}: a `primary_key: true` field of type :keyword is required"

      many ->
        raise ArgumentError,
              "#{inspect(mod)}: exactly one `primary_key` is allowed, found #{inspect(many)}"
    end
  end

  # An embedded schema may not carry its own index-level analysis/settings —
  # analyzers are defined once at the root and inherited by the whole index.
  defp validate_embedded_settings!(mod, analysis, settings_opts) do
    unless analysis == [] and settings_opts == [] do
      raise ArgumentError,
            "#{inspect(mod)}: an embedded schema must not declare a `settings` block " <>
              "(index settings and analyzers are root-only; reference analyzers by name)"
    end
  end

  defp validate_field!(mod, %{name: name, type: type, opts: opts}) do
    base = base_type(type)

    unless base in @scalar_types do
      raise ArgumentError,
            "#{inspect(mod)}: field #{inspect(name)} has unknown type #{inspect(type)} " <>
              "(supported: #{inspect(@scalar_types)} or {:array, scalar})"
    end

    if opts[:primary_key] && type != :keyword do
      raise ArgumentError,
            "#{inspect(mod)}: field #{inspect(name)} is a `primary_key` and must be of type :keyword"
    end

    validate_type_opts!(mod, name, type, opts)

    :ok
  end

  # A `:geo_point` field only carries `default:` (and `primary_key:`, already
  # rejected above by the keyword-type check). Every analysis/sort option is
  # forbidden with a clear, geo-specific message.
  defp validate_type_opts!(mod, name, :geo_point, opts) do
    Enum.each(@geo_point_forbidden_opts, fn key ->
      if Keyword.has_key?(opts, key) and opts[key] not in [nil, false] do
        raise ArgumentError,
              "#{inspect(mod)}: field #{inspect(name)} is a `:geo_point` and does not support " <>
                "`#{key}:` (geo fields are not full-text searchable or sortable)"
      end
    end)
  end

  defp validate_type_opts!(mod, name, type, opts) do
    validate_text_only!(mod, name, type, opts, :analyzer)
    validate_text_only!(mod, name, type, opts, :searchable)
    validate_text_only!(mod, name, type, opts, :keyword)

    if Keyword.has_key?(opts, :analyzer) and not is_atom(opts[:analyzer]) do
      raise ArgumentError,
            "#{inspect(mod)}: field #{inspect(name)} `analyzer:` must be an atom (a logical name)"
    end
  end

  # `analyzer:`/`searchable:`/`keyword:` only make sense on :text fields.
  defp validate_text_only!(mod, name, type, opts, key) do
    if Keyword.has_key?(opts, key) and opts[key] not in [nil, false] and type != :text do
      raise ArgumentError,
            "#{inspect(mod)}: field #{inspect(name)} has `#{key}:` but is not of type :text"
    end
  end

  defp base_type({:array, inner}), do: inner
  defp base_type(type), do: type

  defp validate_facets!(mod, facets, field_meta, embedded?) do
    if embedded? and facets != [] do
      raise ArgumentError,
            "#{inspect(mod)}: an embedded schema must not declare a `facets` slot " <>
              "(facets are root-only)"
    end

    field_names = Enum.map(field_meta, & &1.name)

    case facets do
      [] ->
        nil

      [one] ->
        if one in field_names do
          raise ArgumentError,
                "#{inspect(mod)}: facets slot #{inspect(one)} collides with a field of the same name"
        end

        one

      many ->
        raise ArgumentError,
              "#{inspect(mod)}: `facets` can be declared at most once, found #{inspect(many)}"
    end
  end

  # Validates embeds_one/embeds_many declarations: valid mode, unique names, no
  # collision with fields or the facets slot, and each target module must be a
  # compiled `Orkestra.ES.Schema` declared with `embedded: true`.
  defp validate_embeds!(mod, embeds, field_meta, facets_field) do
    embeds_meta =
      Enum.map(embeds, fn {name, schema, cardinality, opts} ->
        mode = Keyword.get(opts, :mode, :object)

        unless mode in [:object, :nested] do
          raise ArgumentError,
                "#{inspect(mod)}: embed #{inspect(name)} has invalid `mode: #{inspect(mode)}` " <>
                  "(expected :object or :nested)"
        end

        %{name: name, schema: schema, cardinality: cardinality, mode: mode}
      end)

    names = Enum.map(embeds_meta, & &1.name)
    duplicates = names -- Enum.uniq(names)

    unless duplicates == [] do
      raise ArgumentError,
            "#{inspect(mod)}: duplicate embed(s) #{inspect(Enum.uniq(duplicates))}"
    end

    field_names = Enum.map(field_meta, & &1.name)

    Enum.each(embeds_meta, fn %{name: name, schema: schema} ->
      if name in field_names do
        raise ArgumentError,
              "#{inspect(mod)}: embed #{inspect(name)} collides with a field of the same name"
      end

      if name == facets_field do
        raise ArgumentError,
              "#{inspect(mod)}: embed #{inspect(name)} collides with the facets slot of the " <>
                "same name"
      end

      validate_embedded_module!(mod, name, schema)
    end)

    embeds_meta
  end

  defp validate_embedded_module!(mod, name, schema) do
    case Code.ensure_compiled(schema) do
      {:module, ^schema} ->
        :ok

      {:error, reason} ->
        raise ArgumentError,
              "#{inspect(mod)}: embed #{inspect(name)} references #{inspect(schema)}, which " <>
                "could not be compiled (#{inspect(reason)})"
    end

    embedded? =
      function_exported?(schema, :__es_schema__, 1) and schema.__es_schema__(:embedded?)

    unless embedded? do
      raise ArgumentError,
            "#{inspect(mod)}: embed #{inspect(name)} references #{inspect(schema)}, which is " <>
              "not an embedded schema (define it with `use Orkestra.ES.Schema, embedded: true`)"
    end
  end

  # Collects every analyzer atom referenced by the schema's own fields plus,
  # recursively, by all embedded schemas (each embedded schema exposes the refs
  # of its own subtree via `__es_schema__(:analyzer_refs)`).
  defp collect_analyzer_refs(field_meta, embeds_meta) do
    own = for %{opts: o} <- field_meta, not is_nil(o[:analyzer]), do: o[:analyzer]

    from_embeds =
      Enum.flat_map(embeds_meta, fn %{schema: schema} ->
        schema.__es_schema__(:analyzer_refs)
      end)

    Enum.uniq(own ++ from_embeds)
  end

  defp validate_analysis!(mod, referenced_analyzers, analysis, cultures) do
    validate_for_cultures!(mod, analysis, cultures)

    cultures_to_check = if cultures == [], do: [nil], else: cultures

    Enum.each(cultures_to_check, fn culture ->
      defs = Mapping.applicable_defs(analysis, culture)
      defined = defs_by_category(defs)

      Enum.each(referenced_analyzers, fn a ->
        unless MapSet.member?(Map.get(defined, :analyzer, MapSet.new()), to_string(a)) do
          raise ArgumentError,
                "#{inspect(mod)}: analyzer #{inspect(a)} referenced by a field is not " <>
                  "defined for culture #{inspect(culture)}"
        end
      end)

      Enum.each(defs, fn
        {cat, name, opts} when cat in [:analyzer, :normalizer] ->
          check_chain_refs!(mod, name, opts, defined, culture)

        _ ->
          :ok
      end)
    end)
  end

  defp validate_for_cultures!(mod, analysis, cultures) do
    Enum.each(analysis, fn {_cat, name, opts} ->
      case Keyword.get(opts, :for) do
        nil ->
          :ok

        culture ->
          unless culture in cultures do
            raise ArgumentError,
                  "#{inspect(mod)}: analysis definition #{inspect(name)} declares " <>
                    "`for: #{inspect(culture)}` which is not in cultures #{inspect(cultures)}"
          end
      end
    end)
  end

  # Custom (atom) references inside an analyzer/normalizer chain must be defined
  # for the culture. String references are treated as built-in ES components and
  # are not checked.
  defp check_chain_refs!(mod, owner, opts, defined, culture) do
    [
      {:tokenizer, List.wrap(opts[:tokenizer])},
      {:filter, List.wrap(opts[:filter])},
      {:char_filter, List.wrap(opts[:char_filter])}
    ]
    |> Enum.each(fn {category, values} ->
      values
      |> Enum.filter(&is_atom/1)
      |> Enum.reject(&(&1 in [nil, true, false]))
      |> Enum.each(fn ref ->
        unless MapSet.member?(Map.get(defined, category, MapSet.new()), to_string(ref)) do
          raise ArgumentError,
                "#{inspect(mod)}: #{category} #{inspect(ref)} referenced by " <>
                  "#{inspect(owner)} is not defined for culture #{inspect(culture)}"
        end
      end)
    end)
  end

  defp defs_by_category(defs) do
    Enum.reduce(defs, %{}, fn {cat, name, _opts}, acc ->
      Map.update(acc, cat, MapSet.new([to_string(name)]), &MapSet.put(&1, to_string(name)))
    end)
  end
end
