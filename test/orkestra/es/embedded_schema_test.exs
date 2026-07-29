defmodule Orkestra.ES.EmbeddedSchemaTest do
  @moduledoc false

  use ExUnit.Case, async: true

  # -- Fixture schemas --------------------------------------------------------

  defmodule SubItem do
    @moduledoc false
    use Orkestra.ES.Schema, embedded: true

    schema do
      field(:code, :keyword)
      field(:label, :text, searchable: true, analyzer: :sub_search)
    end
  end

  defmodule Item do
    @moduledoc false
    use Orkestra.ES.Schema, embedded: true

    schema do
      field(:sku, :keyword)
      field(:name, :text, searchable: true, analyzer: :item_search)
      field(:quantity, :integer)
      embeds_many(:subs, SubItem, mode: :nested)
    end
  end

  defmodule Address do
    @moduledoc false
    use Orkestra.ES.Schema, embedded: true

    schema do
      field(:city, :keyword)
      field(:street, :text)
      field(:since, :date)
    end
  end

  defmodule Order do
    @moduledoc false
    use Orkestra.ES.Schema, index: "emb_orders"

    settings do
      analyzer(:item_search, tokenizer: "standard", filter: ["lowercase"])
      analyzer(:sub_search, tokenizer: "standard", filter: ["lowercase"])
    end

    schema do
      field(:order_id, :keyword, primary_key: true)
      field(:status, :keyword)
      embeds_one(:shipping, Address)
      embeds_many(:items, Item, mode: :nested)
      facets(:attributes)
    end
  end

  # -- struct + defaults ------------------------------------------------------

  describe "generated structs" do
    test "embeds_one defaults to nil and embeds_many to []" do
      order = %Order{}
      assert order.shipping == nil
      assert order.items == []
    end

    test "an embedded schema generates its own struct with plain defaults" do
      item = %Item{}
      assert item.sku == nil
      assert item.quantity == nil
      assert item.subs == []
    end
  end

  # -- introspection ----------------------------------------------------------

  describe "__es_schema__/1" do
    test ":embedded? is true for embedded and false for root schemas" do
      assert Item.__es_schema__(:embedded?) == true
      assert SubItem.__es_schema__(:embedded?) == true
      assert Order.__es_schema__(:embedded?) == false
    end

    test ":embeds returns normalized metadata in declaration order" do
      assert Order.__es_schema__(:embeds) == [
               %{name: :shipping, schema: Address, cardinality: :one, mode: :object},
               %{name: :items, schema: Item, cardinality: :many, mode: :nested}
             ]

      assert Item.__es_schema__(:embeds) == [
               %{name: :subs, schema: SubItem, cardinality: :many, mode: :nested}
             ]

      assert Address.__es_schema__(:embeds) == []
    end

    test ":field_names does not include embeds" do
      assert Order.__es_schema__(:field_names) == [:order_id, :status]
      assert Item.__es_schema__(:field_names) == [:sku, :name, :quantity]
    end

    test ":analyzer_refs collects references recursively through the embed tree" do
      assert SubItem.__es_schema__(:analyzer_refs) == [:sub_search]
      assert Item.__es_schema__(:analyzer_refs) == [:item_search, :sub_search]
      assert Order.__es_schema__(:analyzer_refs) == [:item_search, :sub_search]
    end

    test "an embedded schema has no index / cultures / primary_key" do
      assert Item.__es_schema__(:index) == nil
      assert Item.__es_schema__(:cultures) == []
      assert Item.__es_schema__(:default_culture) == nil
      assert Item.__es_schema__(:primary_key) == nil
      assert Item.__es_schema__(:facets_field) == nil
    end

    test "an embedded schema does not expose the root-only index API" do
      refute function_exported?(Item, :alias_for, 0)
      refute function_exported?(Item, :mapping, 0)
      refute function_exported?(Item, :mapping_hash, 0)
    end
  end

  # -- mapping ----------------------------------------------------------------

  describe "mapping with embeds" do
    test "an object embed maps to an object property with the embedded properties" do
      shipping = Order.mapping()["mappings"]["properties"]["shipping"]

      assert shipping == %{
               "type" => "object",
               "properties" => %{
                 "city" => %{"type" => "keyword"},
                 "street" => %{"type" => "text"},
                 "since" => %{"type" => "date"}
               }
             }
    end

    test "a nested embed maps to a nested property, recursively (two levels)" do
      items = Order.mapping()["mappings"]["properties"]["items"]

      assert items["type"] == "nested"
      assert items["properties"]["sku"] == %{"type" => "keyword"}

      assert items["properties"]["name"] == %{
               "type" => "text",
               "analyzer" => "item_search"
             }

      subs = items["properties"]["subs"]
      assert subs["type"] == "nested"
      assert subs["properties"]["code"] == %{"type" => "keyword"}
      assert subs["properties"]["label"] == %{"type" => "text", "analyzer" => "sub_search"}
    end

    test "dynamic: strict is set only at the top level of the mapping" do
      mappings = Order.mapping()["mappings"]
      assert mappings["dynamic"] == "strict"
      refute Map.has_key?(mappings["properties"]["shipping"], "dynamic")
      refute Map.has_key?(mappings["properties"]["items"], "dynamic")
    end

    test "the mapping hash changes when an embed changes mode" do
      defmodule HashNested do
        @moduledoc false
        use Orkestra.ES.Schema, index: "hash_mode"

        settings do
          analyzer(:item_search, tokenizer: "standard")
          analyzer(:sub_search, tokenizer: "standard")
        end

        schema do
          field(:id, :keyword, primary_key: true)
          embeds_many(:items, Orkestra.ES.EmbeddedSchemaTest.Item, mode: :nested)
        end
      end

      defmodule HashObject do
        @moduledoc false
        use Orkestra.ES.Schema, index: "hash_mode"

        settings do
          analyzer(:item_search, tokenizer: "standard")
          analyzer(:sub_search, tokenizer: "standard")
        end

        schema do
          field(:id, :keyword, primary_key: true)
          embeds_many(:items, Orkestra.ES.EmbeddedSchemaTest.Item, mode: :object)
        end
      end

      assert HashNested.mapping_hash() != HashObject.mapping_hash()
    end
  end

  # -- to_doc / from_hit ------------------------------------------------------

  describe "to_doc/1 and from_hit/1 with embeds" do
    test "an embedded schema works standalone" do
      item = %Item{sku: "s-1", name: "Drill", quantity: 2}
      doc = Item.to_doc(item)

      assert doc == %{"sku" => "s-1", "name" => "Drill", "quantity" => 2, "subs" => []}
      assert Item.from_hit(doc) == item
    end

    test "embeds_one nil round-trips as null" do
      order = %Order{order_id: "o-1", status: "placed"}
      doc = Order.to_doc(order)

      assert doc["shipping"] == nil
      assert doc["items"] == []
      assert Order.from_hit(doc) == order
    end

    test "full recursive round-trip with embeds_one and multiple embeds_many" do
      order = %Order{
        order_id: "o-2",
        status: "placed",
        shipping: %Address{city: "Rome", street: "Via Roma 1", since: ~D[2024-05-01]},
        items: [
          %Item{
            sku: "a",
            name: "Drill",
            quantity: 1,
            subs: [%SubItem{code: "x", label: "Bit"}, %SubItem{code: "y", label: "Case"}]
          },
          %Item{sku: "b", name: "Saw", quantity: 5}
        ]
      }

      doc = Order.to_doc(order)

      assert doc["shipping"] == %{
               "city" => "Rome",
               "street" => "Via Roma 1",
               "since" => "2024-05-01"
             }

      assert [
               %{
                 "sku" => "a",
                 "subs" => [%{"code" => "x", "label" => "Bit"}, %{"code" => "y"} | _] = _subs
               },
               %{"sku" => "b", "subs" => []}
             ] = doc["items"]

      assert Order.from_hit(doc) == order
    end

    test "a missing embeds_many key in _source reads back as []" do
      order = Order.from_hit(%{"order_id" => "o-3"})
      assert order.items == []
      assert order.shipping == nil
    end
  end

  # -- compile-time validation ------------------------------------------------

  describe "compile-time validation" do
    defp compile!(code) do
      Code.compile_string("""
      defmodule M#{System.unique_integer([:positive])} do
        #{code}
      end
      """)
    end

    test "embedded: true forbids :index" do
      assert_raise ArgumentError, ~r/must not declare `:index`/, fn ->
        compile!(~s|use Orkestra.ES.Schema, embedded: true, index: "x"|)
      end
    end

    test "embedded: true forbids :cultures" do
      assert_raise ArgumentError, ~r/must not declare `:cultures`/, fn ->
        compile!(~s|use Orkestra.ES.Schema, embedded: true, cultures: [:it]|)
      end
    end

    test "embedded: true forbids :default_culture" do
      assert_raise ArgumentError, ~r/must not declare `:default_culture`/, fn ->
        compile!(~s|use Orkestra.ES.Schema, embedded: true, default_culture: :it|)
      end
    end

    test "embedded: true forbids a settings block" do
      assert_raise ArgumentError, ~r/must not declare a `settings` block/, fn ->
        compile!("""
        use Orkestra.ES.Schema, embedded: true
        settings do
        end
        schema do
          field :a, :keyword
        end
        """)
      end
    end

    test "embedded: true forbids primary_key fields" do
      assert_raise ArgumentError, ~r/must not declare a `primary_key`/, fn ->
        compile!("""
        use Orkestra.ES.Schema, embedded: true
        schema do
          field :id, :keyword, primary_key: true
        end
        """)
      end
    end

    test "embedded: true forbids the facets slot" do
      assert_raise ArgumentError, ~r/must not declare a `facets` slot/, fn ->
        compile!("""
        use Orkestra.ES.Schema, embedded: true
        schema do
          field :a, :keyword
          facets :attrs
        end
        """)
      end
    end

    test "embedding a non-embedded schema module raises" do
      assert_raise ArgumentError, ~r/not an embedded schema/, fn ->
        compile!("""
        use Orkestra.ES.Schema, index: "x"
        schema do
          field :id, :keyword, primary_key: true
          embeds_one :other, Orkestra.ES.EmbeddedSchemaTest.Order
        end
        """)
      end
    end

    test "embedding a plain (non-schema) module raises" do
      assert_raise ArgumentError, ~r/not an embedded schema/, fn ->
        compile!("""
        use Orkestra.ES.Schema, index: "x"
        schema do
          field :id, :keyword, primary_key: true
          embeds_one :other, String
        end
        """)
      end
    end

    test "embedding an unknown module raises" do
      assert_raise ArgumentError, ~r/could not be compiled/, fn ->
        compile!("""
        use Orkestra.ES.Schema, index: "x"
        schema do
          field :id, :keyword, primary_key: true
          embeds_one :other, Totally.Missing.Module
        end
        """)
      end
    end

    test "an embed colliding with a field raises" do
      assert_raise ArgumentError, ~r/embed :items collides with a field/, fn ->
        compile!("""
        use Orkestra.ES.Schema, index: "x"
        schema do
          field :id, :keyword, primary_key: true
          field :items, :keyword
          embeds_many :items, Orkestra.ES.EmbeddedSchemaTest.Address
        end
        """)
      end
    end

    test "an embed colliding with the facets slot raises" do
      assert_raise ArgumentError, ~r/embed :attrs collides with the facets slot/, fn ->
        compile!("""
        use Orkestra.ES.Schema, index: "x"
        schema do
          field :id, :keyword, primary_key: true
          facets :attrs
          embeds_one :attrs, Orkestra.ES.EmbeddedSchemaTest.Address
        end
        """)
      end
    end

    test "a duplicate embed raises" do
      assert_raise ArgumentError, ~r/duplicate embed\(s\) \[:a\]/, fn ->
        compile!("""
        use Orkestra.ES.Schema, index: "x"
        schema do
          field :id, :keyword, primary_key: true
          embeds_one :a, Orkestra.ES.EmbeddedSchemaTest.Address
          embeds_many :a, Orkestra.ES.EmbeddedSchemaTest.Address
        end
        """)
      end
    end

    test "an invalid embed mode raises" do
      assert_raise ArgumentError, ~r/invalid `mode: :flat`/, fn ->
        compile!("""
        use Orkestra.ES.Schema, index: "x"
        schema do
          field :id, :keyword, primary_key: true
          embeds_many :a, Orkestra.ES.EmbeddedSchemaTest.Address, mode: :flat
        end
        """)
      end
    end

    test "analyzer coverage is validated per culture over the whole embed tree" do
      # :item_search (referenced inside Item) is defined for :it only, so the
      # :en culture must fail even though the root fields reference nothing.
      assert_raise ArgumentError,
                   ~r/analyzer :item_search referenced by a field is not defined for culture :en/,
                   fn ->
                     compile!("""
                     use Orkestra.ES.Schema, index: "x", cultures: [:it, :en], default_culture: :it
                     settings do
                       analyzer :item_search, for: :it, tokenizer: "standard"
                       analyzer :sub_search, tokenizer: "standard"
                     end
                     schema do
                       field :id, :keyword, primary_key: true
                       embeds_many :items, Orkestra.ES.EmbeddedSchemaTest.Item, mode: :nested
                     end
                     """)
                   end
    end

    test "a mono-culture root embedding analyzers without definitions raises" do
      assert_raise ArgumentError,
                   ~r/analyzer :item_search referenced by a field is not defined/,
                   fn ->
                     compile!("""
                     use Orkestra.ES.Schema, index: "x"
                     schema do
                       field :id, :keyword, primary_key: true
                       embeds_one :item, Orkestra.ES.EmbeddedSchemaTest.Item
                     end
                     """)
                   end
    end

    test "recursive embedding (embedded inside embedded) is allowed" do
      # Item embeds SubItem and compiles fine — asserted by the fixtures above.
      assert Item.__es_schema__(:embeds) != []
    end
  end
end
