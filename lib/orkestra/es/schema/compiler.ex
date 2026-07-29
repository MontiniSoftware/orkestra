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

  @scalar_types [:keyword, :text, :integer, :long, :float, :double, :boolean, :date]

  @typedoc "Normalized per-field metadata: `%{name:, type:, opts:}`."
  @type field_meta :: %{name: atom(), type: term(), opts: keyword()}

  @doc """
  Validates the base options passed to `use Orkestra.ES.Schema`.

  Enforces that `:index` is a non-empty string and that `:cultures` /
  `:default_culture` are mutually consistent (a default culture is required
  when cultures are declared and must belong to the list; a default culture
  must not be given without cultures).
  """
  @spec validate_base!(module(), term(), term(), term()) :: :ok
  def validate_base!(mod, index, cultures, default_culture) do
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

  @doc """
  Validates fields, facets and analysis definitions accumulated in the schema.

  Returns `{field_meta, facets_field}` where `field_meta` is the normalized
  list of `%{name:, type:, opts:}` maps and `facets_field` is the atom of the
  declared facets slot (or `nil`). Raises `ArgumentError` on any violation.
  """
  @spec compile!(module(), [tuple()], [atom()], [tuple()], [atom()]) ::
          {[field_meta()], atom() | nil}
  def compile!(mod, fields, facets, analysis, cultures) do
    field_meta =
      Enum.map(fields, fn {name, type, opts} -> %{name: name, type: type, opts: opts} end)

    validate_fields!(mod, field_meta)
    facets_field = validate_facets!(mod, facets, field_meta)
    validate_analysis!(mod, field_meta, analysis, cultures)

    {field_meta, facets_field}
  end

  defp validate_fields!(mod, field_meta) do
    names = Enum.map(field_meta, & &1.name)
    duplicates = names -- Enum.uniq(names)

    unless duplicates == [] do
      raise ArgumentError,
            "#{inspect(mod)}: duplicate field(s) #{inspect(Enum.uniq(duplicates))}"
    end

    Enum.each(field_meta, &validate_field!(mod, &1))

    primary_keys = for %{name: n, opts: o} <- field_meta, o[:primary_key], do: n

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

    validate_text_only!(mod, name, type, opts, :analyzer)
    validate_text_only!(mod, name, type, opts, :searchable)
    validate_text_only!(mod, name, type, opts, :keyword)

    if Keyword.has_key?(opts, :analyzer) and not is_atom(opts[:analyzer]) do
      raise ArgumentError,
            "#{inspect(mod)}: field #{inspect(name)} `analyzer:` must be an atom (a logical name)"
    end

    :ok
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

  defp validate_facets!(mod, facets, field_meta) do
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

  defp validate_analysis!(mod, field_meta, analysis, cultures) do
    validate_for_cultures!(mod, analysis, cultures)

    referenced_analyzers =
      for %{opts: o} <- field_meta, not is_nil(o[:analyzer]), do: o[:analyzer]

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
