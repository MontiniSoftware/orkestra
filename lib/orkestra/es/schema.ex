defmodule Orkestra.ES.Schema do
  @moduledoc """
  Declarative, Ecto-like schema DSL for Elasticsearch/OpenSearch read models.

  A schema declares its index, optional cultures, index settings with
  per-culture analyzers, and a set of typed fields. From that declaration the
  macro generates a struct, introspection, the full ES index mapping (analyzers
  included), a deterministic mapping hash, and document casting — all as a
  **pure** module (it produces only maps and structs, never calls Snap), so it
  can be tested without any storage dependency.

  ## Defining a schema

      defmodule MyApp.Search.Product do
        use Orkestra.ES.Schema,
          index: "products",
          cultures: [:it, :en],
          default_culture: :it

        settings number_of_shards: 1 do
          analyzer :product_search, for: :it,
            tokenizer: "standard", filter: ["lowercase", "asciifolding", :stemmer_it]
          analyzer :product_search, for: :en,
            tokenizer: "standard", filter: ["lowercase", "porter_stem"]
          filter :stemmer_it, for: :it, type: "stemmer", language: "light_italian"
        end

        schema do
          field :product_id,  :keyword, primary_key: true
          field :name,        :text,    analyzer: :product_search, searchable: true, keyword: true
          field :category,    :keyword
          field :price,       :float
          field :released_at, :date,    sortable: true
          field :tags,        {:array, :keyword}
          facets :attributes
        end
      end

  ## Options for `use`

    * `:index` (required) — the base index name.
    * `:cultures` (optional) — a list of atoms; when present the schema is
      multi-culture and gets one alias per culture (`products_it`). Omitting it
      yields a mono-culture schema with a single unsuffixed alias.
    * `:default_culture` (required with `:cultures`) — must belong to `:cultures`.

  ## Field types

  `:keyword`, `:text`, `:integer`, `:long`, `:float`, `:double`, `:boolean`,
  `:date`, and `{:array, scalar}`.

  ### Field options

    * `primary_key: true` — exactly one field, must be `:keyword`. Its value is
      used as the document `_id`.
    * `analyzer: :name` — `:text` only; references a logical analyzer defined
      per culture in `settings`.
    * `searchable: true` — `:text` only; marks the field for full-text search.
    * `keyword: true` — `:text` only; adds a `"keyword"` sub-field of type
      keyword.
    * `sortable: true` — for `:text` implies the keyword sub-field (which is the
      one to sort on); for other types it is metadata only.
    * `format:` — `:date` only; a custom ES date format. Fields with a custom
      format keep their raw string when decoded.
    * `default:` — the struct default for the field.

  ## Generated API

    * `t()` struct with all fields (plus the facets slot, defaulting to `[]`).
    * `__es_schema__/1` — introspection (see below).
    * `alias_for/0`, `alias_for/1` — the index alias, per culture.
    * `mapping/0`, `mapping/1` — the full string-keyed index mapping.
    * `mapping_hash/0`, `mapping_hash/1` — deterministic SHA-256 of the mapping.
    * `to_doc/1` — struct to indexable document.
    * `from_hit/1` — `_source` map to struct.

  `__es_schema__/1` accepts `:index`, `:cultures` (`[]` for mono-culture),
  `:default_culture`, `:fields` (a list of `%{name:, type:, opts:}`),
  `:field_names`, `:primary_key`, `:searchable_fields`, `:facets_field`, and
  `:sortable_fields`.

  ## Facets

  A schema may declare a single `facets :field_name` slot with the fixed
  structure defined by `Orkestra.ES.Facet` (attribute `code`/`name` owning
  values `code`/`name`/`count`). It maps to a flattened `nested` field
  (`attr_code`/`attr_name`/`value_code`/`value_name`).
  """

  alias Orkestra.ES.Schema.Compiler

  @doc false
  defmacro __using__(opts) do
    index = Keyword.get(opts, :index)
    cultures = Keyword.get(opts, :cultures, [])
    default_culture = Keyword.get(opts, :default_culture)

    Compiler.validate_base!(__CALLER__.module, index, cultures, default_culture)

    quote do
      import Orkestra.ES.Schema,
        only: [
          settings: 1,
          settings: 2,
          schema: 1,
          field: 2,
          field: 3,
          facets: 1,
          analyzer: 1,
          analyzer: 2,
          filter: 1,
          filter: 2,
          tokenizer: 1,
          tokenizer: 2,
          char_filter: 1,
          char_filter: 2,
          normalizer: 1,
          normalizer: 2
        ]

      Module.register_attribute(__MODULE__, :es_fields, accumulate: true)
      Module.register_attribute(__MODULE__, :es_facets, accumulate: true)
      Module.register_attribute(__MODULE__, :es_analysis, accumulate: true)

      @es_index unquote(index)
      @es_cultures unquote(cultures)
      @es_default_culture unquote(default_culture)
      @es_settings_opts []

      @before_compile Orkestra.ES.Schema
    end
  end

  # -- DSL macros -------------------------------------------------------------

  @doc """
  Declares index-level settings and, in its block, the analysis definitions
  (`analyzer/2`, `filter/2`, `tokenizer/2`, `char_filter/2`, `normalizer/2`).
  """
  defmacro settings(opts \\ [], do_block) do
    block = Keyword.fetch!(do_block, :do)

    quote do
      @es_settings_opts unquote(opts)
      unquote(block)
    end
  end

  @doc "Wraps the field/facets declarations of the schema."
  defmacro schema(do: block) do
    quote do
      unquote(block)
    end
  end

  @doc "Declares a typed field. See the module doc for types and options."
  defmacro field(name, type, opts \\ []) do
    quote do
      @es_fields {unquote(name), unquote(Macro.escape(type)), unquote(opts)}
    end
  end

  @doc "Declares the (single) facets slot for the schema."
  defmacro facets(name) do
    quote do
      @es_facets unquote(name)
    end
  end

  @doc "Declares a per-culture analyzer. Use `for:` to scope it to a culture."
  defmacro analyzer(name, opts \\ []) do
    quote do: @es_analysis({:analyzer, unquote(name), unquote(opts)})
  end

  @doc "Declares a per-culture token filter."
  defmacro filter(name, opts \\ []) do
    quote do: @es_analysis({:filter, unquote(name), unquote(opts)})
  end

  @doc "Declares a per-culture tokenizer."
  defmacro tokenizer(name, opts \\ []) do
    quote do: @es_analysis({:tokenizer, unquote(name), unquote(opts)})
  end

  @doc "Declares a per-culture character filter."
  defmacro char_filter(name, opts \\ []) do
    quote do: @es_analysis({:char_filter, unquote(name), unquote(opts)})
  end

  @doc "Declares a per-culture normalizer."
  defmacro normalizer(name, opts \\ []) do
    quote do: @es_analysis({:normalizer, unquote(name), unquote(opts)})
  end

  # -- code generation --------------------------------------------------------

  @doc false
  defmacro __before_compile__(env) do
    mod = env.module
    index = Module.get_attribute(mod, :es_index)
    cultures = Module.get_attribute(mod, :es_cultures) || []
    default_culture = Module.get_attribute(mod, :es_default_culture)
    settings_opts = Module.get_attribute(mod, :es_settings_opts) || []
    fields = mod |> Module.get_attribute(:es_fields) |> Enum.reverse()
    facets = mod |> Module.get_attribute(:es_facets) |> Enum.reverse()
    analysis = mod |> Module.get_attribute(:es_analysis) |> Enum.reverse()

    {field_meta, facets_field} = Compiler.compile!(mod, fields, facets, analysis, cultures)

    struct_fields =
      Enum.map(field_meta, fn %{name: name, opts: opts} -> {name, Keyword.get(opts, :default)} end) ++
        if facets_field, do: [{facets_field, []}], else: []

    primary_key =
      Enum.find_value(field_meta, fn %{name: n, opts: o} -> if o[:primary_key], do: n end)

    field_names = Enum.map(field_meta, & &1.name)
    searchable_fields = for %{name: n, opts: o} <- field_meta, o[:searchable], do: n
    sortable_fields = for %{name: n, opts: o} <- field_meta, o[:sortable], do: n

    escaped_field_meta = Macro.escape(field_meta)
    escaped_settings_opts = Macro.escape(settings_opts)
    escaped_analysis = Macro.escape(analysis)

    mono? = cultures == []
    mapping_zero_culture = if mono?, do: nil, else: default_culture

    culture_guard =
      if mono? do
        quote do
          defp __validate_culture__(culture) do
            raise ArgumentError,
                  "#{inspect(__MODULE__)}: schema is mono-culture and does not accept a " <>
                    "culture argument (got #{inspect(culture)})"
          end
        end
      else
        quote do
          defp __validate_culture__(culture) do
            if culture in unquote(cultures) do
              culture
            else
              raise ArgumentError,
                    "#{inspect(__MODULE__)}: unknown culture #{inspect(culture)}, " <>
                      "valid cultures: #{inspect(unquote(cultures))}"
            end
          end
        end
      end

    # The culture-argument variants differ for mono- vs multi-culture schemas.
    # For a mono-culture schema they simply reject the argument via
    # `__validate_culture__/1` (which always raises); their result is never fed
    # into another call, which keeps the type-checker happy.
    culture_fns =
      if mono? do
        quote do
          @doc "Returns the index alias (mono-culture schema)."
          def alias_for, do: unquote(index)

          @doc "Raises: a mono-culture schema does not accept a culture argument."
          @spec alias_for(atom()) :: no_return()
          def alias_for(culture), do: __validate_culture__(culture)

          @doc "Raises: a mono-culture schema does not accept a culture argument."
          @spec mapping(atom()) :: no_return()
          def mapping(culture), do: __validate_culture__(culture)

          @doc "Raises: a mono-culture schema does not accept a culture argument."
          @spec mapping_hash(atom()) :: no_return()
          def mapping_hash(culture), do: __validate_culture__(culture)
        end
      else
        quote do
          @doc "Returns the alias for the default culture."
          def alias_for, do: alias_for(unquote(default_culture))

          @doc "Returns the alias for the given culture (e.g. `\"products_it\"`)."
          @spec alias_for(atom()) :: String.t()
          def alias_for(culture) do
            unquote(index) <> "_" <> Atom.to_string(__validate_culture__(culture))
          end

          @doc "Returns the full index mapping for the given culture."
          @spec mapping(atom()) :: map()
          def mapping(culture), do: __build_mapping__(__validate_culture__(culture))

          @doc "Returns the deterministic SHA-256 hash of the given culture's mapping."
          @spec mapping_hash(atom()) :: String.t()
          def mapping_hash(culture) do
            Orkestra.ES.Schema.Mapping.mapping_hash(mapping(culture))
          end
        end
      end

    quote do
      defstruct unquote(Macro.escape(struct_fields))

      @typedoc "The read-model struct generated for this schema."
      @type t :: %__MODULE__{}

      @doc """
      Introspects the compiled schema.

      Accepts `:index`, `:cultures`, `:default_culture`, `:fields`,
      `:field_names`, `:primary_key`, `:searchable_fields`, `:facets_field`,
      and `:sortable_fields`.
      """
      @spec __es_schema__(atom()) :: term()
      def __es_schema__(:index), do: unquote(index)
      def __es_schema__(:cultures), do: unquote(cultures)
      def __es_schema__(:default_culture), do: unquote(default_culture)
      def __es_schema__(:fields), do: unquote(escaped_field_meta)
      def __es_schema__(:field_names), do: unquote(field_names)
      def __es_schema__(:primary_key), do: unquote(primary_key)
      def __es_schema__(:searchable_fields), do: unquote(searchable_fields)
      def __es_schema__(:facets_field), do: unquote(facets_field)
      def __es_schema__(:sortable_fields), do: unquote(sortable_fields)

      unquote(culture_guard)
      unquote(culture_fns)

      @doc "Returns the full index mapping for the default culture."
      @spec mapping() :: map()
      def mapping, do: __build_mapping__(unquote(mapping_zero_culture))

      defp __build_mapping__(culture) do
        Orkestra.ES.Schema.Mapping.build(
          unquote(escaped_field_meta),
          unquote(facets_field),
          unquote(escaped_settings_opts),
          unquote(escaped_analysis),
          culture
        )
      end

      @doc "Returns the deterministic SHA-256 hash of the default-culture mapping."
      @spec mapping_hash() :: String.t()
      def mapping_hash, do: Orkestra.ES.Schema.Mapping.mapping_hash(mapping())

      @doc "Converts the struct into a string-keyed indexable document."
      @spec to_doc(t()) :: map()
      def to_doc(%__MODULE__{} = struct) do
        Orkestra.ES.Schema.Casting.to_doc(
          struct,
          unquote(escaped_field_meta),
          unquote(facets_field)
        )
      end

      @doc "Rebuilds the struct from an Elasticsearch `_source` map."
      @spec from_hit(map()) :: t()
      def from_hit(source) when is_map(source) do
        Orkestra.ES.Schema.Casting.from_hit(
          source,
          __MODULE__,
          unquote(escaped_field_meta),
          unquote(facets_field)
        )
      end
    end
  end
end
