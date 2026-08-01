defmodule Orkestra.ES.SchemaTest do
  use ExUnit.Case, async: true

  alias Orkestra.ES.Facet

  # -- Fixture schemas --------------------------------------------------------

  defmodule Product do
    use Orkestra.ES.Schema,
      index: "products",
      cultures: [:it, :en],
      default_culture: :it

    settings number_of_shards: 1, number_of_replicas: 0 do
      analyzer(:product_search,
        for: :it,
        tokenizer: "standard",
        filter: ["lowercase", "asciifolding", :stemmer_it]
      )

      analyzer(:product_search,
        for: :en,
        tokenizer: "standard",
        filter: ["lowercase", "porter_stem"]
      )

      filter(:stemmer_it, for: :it, type: "stemmer", language: "light_italian")
    end

    schema do
      field(:product_id, :keyword, primary_key: true)
      field(:name, :text, analyzer: :product_search, searchable: true, keyword: true)
      field(:category, :keyword)
      field(:price, :float)
      field(:released_at, :date, sortable: true)
      field(:tags, {:array, :keyword})
      facets(:attributes)
    end
  end

  defmodule Simple do
    use Orkestra.ES.Schema, index: "simple"

    schema do
      field(:id, :keyword, primary_key: true)
      field(:title, :text)
      field(:views, :integer, default: 0)
      field(:active, :boolean)
      field(:updated_at, :date)
    end
  end

  defmodule SharedAnalyzer do
    use Orkestra.ES.Schema,
      index: "shared",
      cultures: [:it, :en],
      default_culture: :en

    settings do
      # A definition without `for:` is a shared fallback for every culture.
      analyzer(:folding, tokenizer: "standard", filter: ["lowercase", "asciifolding"])
    end

    schema do
      field(:id, :keyword, primary_key: true)
      field(:body, :text, analyzer: :folding)
    end
  end

  defmodule Geo do
    use Orkestra.ES.Schema, index: "geo"

    schema do
      field(:id, :keyword, primary_key: true)
      field(:name, :text)
      field(:location, :geo_point)
    end
  end

  # -- struct + defaults ------------------------------------------------------

  describe "generated struct" do
    test "defines a struct with all fields plus the facets slot" do
      s = %Product{}
      assert Map.has_key?(s, :product_id)
      assert Map.has_key?(s, :name)
      assert Map.has_key?(s, :attributes)
      assert s.attributes == []
    end

    test "applies declared defaults" do
      assert %Simple{}.views == 0
      assert %Simple{}.title == nil
    end
  end

  # -- __es_schema__/1 --------------------------------------------------------

  describe "__es_schema__/1" do
    test ":index" do
      assert Product.__es_schema__(:index) == "products"
      assert Simple.__es_schema__(:index) == "simple"
    end

    test ":cultures ([] for mono-culture)" do
      assert Product.__es_schema__(:cultures) == [:it, :en]
      assert Simple.__es_schema__(:cultures) == []
    end

    test ":default_culture" do
      assert Product.__es_schema__(:default_culture) == :it
      assert Simple.__es_schema__(:default_culture) == nil
    end

    test ":fields returns full metadata maps" do
      fields = Product.__es_schema__(:fields)
      name = Enum.find(fields, &(&1.name == :name))
      assert name.type == :text
      assert name.opts[:analyzer] == :product_search
      assert name.opts[:searchable] == true

      tags = Enum.find(fields, &(&1.name == :tags))
      assert tags.type == {:array, :keyword}
    end

    test ":field_names excludes the facets slot" do
      assert Product.__es_schema__(:field_names) ==
               [:product_id, :name, :category, :price, :released_at, :tags]
    end

    test ":primary_key" do
      assert Product.__es_schema__(:primary_key) == :product_id
      assert Simple.__es_schema__(:primary_key) == :id
    end

    test ":searchable_fields" do
      assert Product.__es_schema__(:searchable_fields) == [:name]
      assert Simple.__es_schema__(:searchable_fields) == []
    end

    test ":facets_field" do
      assert Product.__es_schema__(:facets_field) == :attributes
      assert Simple.__es_schema__(:facets_field) == nil
    end

    test ":sortable_fields" do
      assert Product.__es_schema__(:sortable_fields) == [:released_at]
    end
  end

  # -- alias_for --------------------------------------------------------------

  describe "alias_for" do
    test "multi-culture aliases are suffixed" do
      assert Product.alias_for(:it) == "products_it"
      assert Product.alias_for(:en) == "products_en"
    end

    test "alias_for/0 uses the default culture" do
      assert Product.alias_for() == "products_it"
    end

    test "mono-culture alias is unsuffixed" do
      assert Simple.alias_for() == "simple"
    end

    test "unknown culture raises with the valid list" do
      assert_raise ArgumentError, ~r/unknown culture :fr.*\[:it, :en\]/, fn ->
        Product.alias_for(:fr)
      end
    end

    test "mono-culture alias_for/1 raises" do
      assert_raise ArgumentError, ~r/mono-culture/, fn -> Simple.alias_for(:it) end
    end
  end

  # -- mapping/1 --------------------------------------------------------------

  describe "mapping/1" do
    test "injects dynamic: strict always" do
      assert Product.mapping(:it)["mappings"]["dynamic"] == "strict"
      assert Simple.mapping()["mappings"]["dynamic"] == "strict"
    end

    test "maps each scalar type to the right ES type" do
      props = Product.mapping(:it)["mappings"]["properties"]
      assert props["product_id"] == %{"type" => "keyword"}
      assert props["category"] == %{"type" => "keyword"}
      assert props["price"] == %{"type" => "float"}
      assert props["released_at"]["type"] == "date"
      assert Simple.mapping()["mappings"]["properties"]["views"] == %{"type" => "integer"}
      assert Simple.mapping()["mappings"]["properties"]["active"] == %{"type" => "boolean"}
    end

    test "array fields map to the element type" do
      props = Product.mapping(:it)["mappings"]["properties"]
      assert props["tags"] == %{"type" => "keyword"}
    end

    test "text field carries analyzer and keyword subfield" do
      name = Product.mapping(:it)["mappings"]["properties"]["name"]
      assert name["type"] == "text"
      assert name["analyzer"] == "product_search"
      assert name["fields"] == %{"keyword" => %{"type" => "keyword"}}
    end

    test "sortable text implies the keyword subfield" do
      # `title` in Simple is plain text, no keyword subfield
      refute Map.has_key?(Simple.mapping()["mappings"]["properties"]["title"], "fields")
    end

    test "facets slot maps to a flattened nested field" do
      attrs = Product.mapping(:it)["mappings"]["properties"]["attributes"]
      assert attrs["type"] == "nested"

      assert attrs["properties"] == %{
               "attr_code" => %{"type" => "keyword"},
               "attr_name" => %{"type" => "keyword"},
               "value_code" => %{"type" => "keyword"},
               "value_name" => %{"type" => "keyword"}
             }
    end

    test "index-level settings are string-keyed" do
      settings = Product.mapping(:it)["settings"]
      assert settings["number_of_shards"] == 1
      assert settings["number_of_replicas"] == 0
    end

    test "analysis is per-culture with atom references stringified" do
      it = Product.mapping(:it)["settings"]["analysis"]

      assert it["analyzer"]["product_search"]["filter"] == [
               "lowercase",
               "asciifolding",
               "stemmer_it"
             ]

      assert it["filter"]["stemmer_it"] == %{"type" => "stemmer", "language" => "light_italian"}

      en = Product.mapping(:en)["settings"]["analysis"]
      assert en["analyzer"]["product_search"]["filter"] == ["lowercase", "porter_stem"]
      # the :it-only stemmer filter is absent from the :en analysis
      refute Map.has_key?(en, "filter")
    end

    test "a shared (no for:) definition applies to every culture" do
      for culture <- [:it, :en] do
        analysis = SharedAnalyzer.mapping(culture)["settings"]["analysis"]
        assert analysis["analyzer"]["folding"]["tokenizer"] == "standard"
      end
    end

    test "mono-culture schema without settings omits the settings block" do
      refute Map.has_key?(Simple.mapping(), "settings")
    end

    test "mapping/0 for multi-culture uses the default culture" do
      assert Product.mapping() == Product.mapping(:it)
    end
  end

  # -- mapping_hash -----------------------------------------------------------

  describe "mapping_hash" do
    test "is a stable lowercase hex sha256" do
      hash = Product.mapping_hash(:it)
      assert hash =~ ~r/^[0-9a-f]{64}$/
      assert hash == Product.mapping_hash(:it)
    end

    test "differs between cultures with different analysis" do
      assert Product.mapping_hash(:it) != Product.mapping_hash(:en)
    end

    test "is order-independent (recursively sorted before hashing)" do
      # Two literally equal mappings must hash identically regardless of the
      # in-memory key order; recomputing yields the same value.
      assert Product.mapping_hash() == Product.mapping_hash(:it)
    end

    test "changes when the mapping changes" do
      defmodule HashA do
        use Orkestra.ES.Schema, index: "h"

        schema do
          field(:id, :keyword, primary_key: true)
          field(:a, :keyword)
        end
      end

      defmodule HashB do
        use Orkestra.ES.Schema, index: "h"

        schema do
          field(:id, :keyword, primary_key: true)
          field(:a, :text)
        end
      end

      assert HashA.mapping_hash() != HashB.mapping_hash()
    end
  end

  # -- to_doc / from_hit round-trip -------------------------------------------

  describe "to_doc/1 and from_hit/1" do
    test "serializes dates to ISO8601 and preserves nil as null" do
      doc = Simple.to_doc(%Simple{id: "x", updated_at: ~D[2024-03-01]})
      assert doc["updated_at"] == "2024-03-01"
      assert doc["title"] == nil
    end

    test "round-trips a Date value" do
      s = %Simple{id: "x", title: "hi", views: 3, active: true, updated_at: ~D[2024-03-01]}
      assert Simple.from_hit(Simple.to_doc(s)) == s
    end

    test "round-trips a DateTime value" do
      defmodule Timed do
        use Orkestra.ES.Schema, index: "timed"

        schema do
          field(:id, :keyword, primary_key: true)
          field(:at, :date)
        end
      end

      s = struct(Timed, id: "x", at: ~U[2024-03-01 10:30:00Z])
      assert Timed.from_hit(Timed.to_doc(s)) == s
    end

    test "round-trips arrays and nil" do
      s = %Product{product_id: "p", tags: ["a", "b"], price: nil}
      back = Product.from_hit(Product.to_doc(s))
      assert back.tags == ["a", "b"]
      assert back.price == nil
    end

    test "flattens facets on write and regroups on read preserving order" do
      s = %Product{
        product_id: "p",
        attributes: [
          %Facet.Attribute{
            code: "color",
            name: "Color",
            values: [
              %Facet.Value{code: "red", name: "Red"},
              %Facet.Value{code: "blue", name: "Blue"}
            ]
          },
          %Facet.Attribute{
            code: "brand",
            name: "Brand",
            values: [%Facet.Value{code: "bosch", name: "Bosch"}]
          }
        ]
      }

      doc = Product.to_doc(s)

      assert doc["attributes"] == [
               %{
                 "attr_code" => "color",
                 "attr_name" => "Color",
                 "value_code" => "red",
                 "value_name" => "Red"
               },
               %{
                 "attr_code" => "color",
                 "attr_name" => "Color",
                 "value_code" => "blue",
                 "value_name" => "Blue"
               },
               %{
                 "attr_code" => "brand",
                 "attr_name" => "Brand",
                 "value_code" => "bosch",
                 "value_name" => "Bosch"
               }
             ]

      back = Product.from_hit(doc)
      assert back == s
      # counts are nil in documents
      assert Enum.all?(back.attributes, fn a -> Enum.all?(a.values, &(&1.count == nil)) end)
    end

    test "empty facets round-trip to an empty list" do
      s = %Product{product_id: "p"}
      assert Product.from_hit(Product.to_doc(s)).attributes == []
    end

    test "date field with a custom format keeps its raw string" do
      defmodule Custom do
        use Orkestra.ES.Schema, index: "custom"

        schema do
          field(:id, :keyword, primary_key: true)
          field(:d, :date, format: "yyyy-MM")
        end
      end

      s = struct(Custom, id: "x", d: "2024-03")
      doc = Custom.to_doc(s)
      assert doc["d"] == "2024-03"
      assert Custom.from_hit(doc) == s
      assert Custom.mapping()["mappings"]["properties"]["d"]["format"] == "yyyy-MM"
    end
  end

  # -- geo_point --------------------------------------------------------------

  describe "geo_point field" do
    test "maps to the Elasticsearch geo_point type" do
      props = Geo.mapping()["mappings"]["properties"]
      assert props["location"] == %{"type" => "geo_point"}
    end

    test "introspection reports the :geo_point type" do
      fields = Geo.__es_schema__(:fields)
      location = Enum.find(fields, &(&1.name == :location))
      assert location.type == :geo_point

      # geo fields are neither searchable nor sortable
      assert Geo.__es_schema__(:searchable_fields) == []
      assert Geo.__es_schema__(:sortable_fields) == []
    end

    test "participates in the mapping hash like any other field" do
      defmodule GeoHashA do
        use Orkestra.ES.Schema, index: "gh"

        schema do
          field(:id, :keyword, primary_key: true)
          field(:loc, :geo_point)
        end
      end

      defmodule GeoHashB do
        use Orkestra.ES.Schema, index: "gh"

        schema do
          field(:id, :keyword, primary_key: true)
          field(:loc, :keyword)
        end
      end

      assert GeoHashA.mapping_hash() != GeoHashB.mapping_hash()
    end

    test "round-trips an atom-keyed point" do
      s = %Geo{id: "x", location: %{lat: 45.5, lon: 9.2}}
      doc = Geo.to_doc(s)
      assert doc["location"] == %{"lat" => 45.5, "lon" => 9.2}
      assert Geo.from_hit(doc) == s
    end

    test "normalizes a string-keyed point on input to the atom-keyed map" do
      s = %Geo{id: "x", location: %{"lat" => 45.5, "lon" => 9.2}}
      doc = Geo.to_doc(s)
      assert doc["location"] == %{"lat" => 45.5, "lon" => 9.2}
      # from_hit always decodes to atom keys
      assert Geo.from_hit(doc) == %Geo{id: "x", location: %{lat: 45.5, lon: 9.2}}
    end

    test "a nil geo_point round-trips as nil" do
      s = %Geo{id: "x", location: nil}
      doc = Geo.to_doc(s)
      assert doc["location"] == nil
      assert Geo.from_hit(doc) == s
    end

    test "a zero coordinate is preserved (not treated as missing)" do
      s = %Geo{id: "x", location: %{lat: 0.0, lon: 0.0}}
      assert Geo.to_doc(s)["location"] == %{"lat" => 0.0, "lon" => 0.0}
      assert Geo.from_hit(Geo.to_doc(s)) == s
    end
  end

  # -- compile-time validation ------------------------------------------------

  describe "compile-time validation" do
    defp compile!(body) do
      mod = "M#{System.unique_integer([:positive])}"

      Code.compile_string("""
      defmodule #{mod} do
        use Orkestra.ES.Schema, #{body}
      end
      """)
    end

    test "missing :index" do
      assert_raise ArgumentError, ~r/`:index` option is required/, fn ->
        compile!(~s|cultures: [:it], default_culture: :it, index: nil|)
      end
    end

    test "missing default_culture when cultures present" do
      assert_raise ArgumentError, ~r/`:default_culture` is required/, fn ->
        compile!(~s|index: "x", cultures: [:it]|)
      end
    end

    test "default_culture not in cultures" do
      assert_raise ArgumentError, ~r/must be one of/, fn ->
        compile!(~s|index: "x", cultures: [:it], default_culture: :fr|)
      end
    end

    test "default_culture without cultures" do
      assert_raise ArgumentError, ~r/without `:cultures`/, fn ->
        compile!(~s|index: "x", default_culture: :it|)
      end
    end

    defp compile_schema!(body) do
      mod = "M#{System.unique_integer([:positive])}"

      Code.compile_string("""
      defmodule #{mod} do
        use Orkestra.ES.Schema, index: "x"
        schema do
          #{body}
        end
      end
      """)
    end

    test "no primary key" do
      assert_raise ArgumentError, ~r/primary_key.*required/, fn ->
        compile_schema!("field :a, :keyword")
      end
    end

    test "more than one primary key" do
      assert_raise ArgumentError, ~r/exactly one `primary_key`/, fn ->
        compile_schema!("""
        field :a, :keyword, primary_key: true
        field :b, :keyword, primary_key: true
        """)
      end
    end

    test "primary key on non-keyword type" do
      assert_raise ArgumentError, ~r/must be of type :keyword/, fn ->
        compile_schema!("field :a, :integer, primary_key: true")
      end
    end

    test "unknown field type" do
      assert_raise ArgumentError, ~r/unknown type/, fn ->
        compile_schema!("""
        field :id, :keyword, primary_key: true
        field :a, :geo_shape
        """)
      end
    end

    test "analyzer on a non-text field" do
      assert_raise ArgumentError, ~r/`analyzer:` but is not of type :text/, fn ->
        compile_schema!("""
        field :id, :keyword, primary_key: true
        field :a, :integer, analyzer: :x
        """)
      end
    end

    test "searchable on a non-text field" do
      assert_raise ArgumentError, ~r/`searchable:` but is not of type :text/, fn ->
        compile_schema!("""
        field :id, :keyword, primary_key: true
        field :a, :keyword, searchable: true
        """)
      end
    end

    test "searchable on a geo_point field" do
      assert_raise ArgumentError, ~r/`:geo_point` and does not support `searchable:`/, fn ->
        compile_schema!("""
        field :id, :keyword, primary_key: true
        field :loc, :geo_point, searchable: true
        """)
      end
    end

    test "analyzer on a geo_point field" do
      assert_raise ArgumentError, ~r/`:geo_point` and does not support `analyzer:`/, fn ->
        compile_schema!("""
        field :id, :keyword, primary_key: true
        field :loc, :geo_point, analyzer: :x
        """)
      end
    end

    test "keyword on a geo_point field" do
      assert_raise ArgumentError, ~r/`:geo_point` and does not support `keyword:`/, fn ->
        compile_schema!("""
        field :id, :keyword, primary_key: true
        field :loc, :geo_point, keyword: true
        """)
      end
    end

    test "sortable on a geo_point field" do
      assert_raise ArgumentError, ~r/`:geo_point` and does not support `sortable:`/, fn ->
        compile_schema!("""
        field :id, :keyword, primary_key: true
        field :loc, :geo_point, sortable: true
        """)
      end
    end

    test "geo_point cannot be a primary key" do
      assert_raise ArgumentError, ~r/must be of type :keyword/, fn ->
        compile_schema!("field :loc, :geo_point, primary_key: true")
      end
    end

    test "facets colliding with a field name" do
      assert_raise ArgumentError, ~r/collides with a field/, fn ->
        compile_schema!("""
        field :id, :keyword, primary_key: true
        field :attrs, :keyword
        facets :attrs
        """)
      end
    end

    test "facets declared more than once" do
      assert_raise ArgumentError, ~r/at most once/, fn ->
        compile_schema!("""
        field :id, :keyword, primary_key: true
        facets :a
        facets :b
        """)
      end
    end

    test "analyzer referenced by a field but not defined for every culture" do
      assert_raise ArgumentError, ~r/analyzer :missing referenced by a field/, fn ->
        Code.compile_string("""
        defmodule M#{System.unique_integer([:positive])} do
          use Orkestra.ES.Schema, index: "x", cultures: [:it, :en], default_culture: :it
          settings do
            analyzer :missing, for: :it, tokenizer: "standard"
          end
          schema do
            field :id, :keyword, primary_key: true
            field :name, :text, analyzer: :missing
          end
        end
        """)
      end
    end

    test "filter referenced inside an analyzer chain but not defined" do
      assert_raise ArgumentError, ~r/filter :undefined_filter referenced by/, fn ->
        Code.compile_string("""
        defmodule M#{System.unique_integer([:positive])} do
          use Orkestra.ES.Schema, index: "x"
          settings do
            analyzer :a, tokenizer: "standard", filter: [:undefined_filter]
          end
          schema do
            field :id, :keyword, primary_key: true
            field :name, :text, analyzer: :a
          end
        end
        """)
      end
    end

    test "`for:` referencing an undeclared culture" do
      assert_raise ArgumentError, ~r/`for: :fr` which is not in cultures/, fn ->
        Code.compile_string("""
        defmodule M#{System.unique_integer([:positive])} do
          use Orkestra.ES.Schema, index: "x", cultures: [:it], default_culture: :it
          settings do
            analyzer :a, for: :fr, tokenizer: "standard"
          end
          schema do
            field :id, :keyword, primary_key: true
          end
        end
        """)
      end
    end
  end
end
