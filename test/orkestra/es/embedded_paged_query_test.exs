defmodule Orkestra.ES.EmbeddedPagedQueryTest do
  @moduledoc false

  use ExUnit.Case, async: true

  alias Orkestra.ES.PagedQuery

  # -- Fixture schemas --------------------------------------------------------

  defmodule Sub do
    @moduledoc false
    use Orkestra.ES.Schema, embedded: true

    schema do
      field(:tag, :keyword)
      field(:note, :text, searchable: true)
    end
  end

  defmodule Item do
    @moduledoc false
    use Orkestra.ES.Schema, embedded: true

    schema do
      field(:sku, :keyword)
      field(:name, :text, searchable: true)
      field(:quantity, :integer)
      field(:comment, :text)
      embeds_many(:subs, Sub, mode: :nested)
    end
  end

  defmodule Address do
    @moduledoc false
    use Orkestra.ES.Schema, embedded: true

    schema do
      field(:city, :keyword)
      field(:label, :text, searchable: true)
    end
  end

  defmodule PlainPart do
    @moduledoc false
    use Orkestra.ES.Schema, embedded: true

    schema do
      field(:code, :keyword)
    end
  end

  # Root with an object embeds_one plus a nested embeds_many (with a further
  # nested level inside), covering the mixed search/filter shapes.
  defmodule NestedOrder do
    @moduledoc false
    use Orkestra.ES.Schema, index: "pq_nested_orders"

    schema do
      field(:order_id, :keyword, primary_key: true)
      field(:title, :text, searchable: true)
      embeds_one(:shipping, Address)
      embeds_many(:items, Item, mode: :nested)
    end
  end

  # Root whose only searchable field lives inside an object embed.
  defmodule ObjectOrder do
    @moduledoc false
    use Orkestra.ES.Schema, index: "pq_object_orders"

    schema do
      field(:order_id, :keyword, primary_key: true)
      embeds_one(:shipping, Address)
      embeds_many(:items, Item, mode: :object)
    end
  end

  # Root with searchable root fields and a nested embed with nothing
  # searchable inside (the nested scope must be pruned).
  defmodule PrunedOrder do
    @moduledoc false
    use Orkestra.ES.Schema, index: "pq_pruned_orders"

    schema do
      field(:order_id, :keyword, primary_key: true)
      field(:title, :text, searchable: true)
      embeds_many(:parts, PlainPart, mode: :nested)
    end
  end

  # Root with no searchable field anywhere in the tree.
  defmodule NoSearchOrder do
    @moduledoc false
    use Orkestra.ES.Schema, index: "pq_nosearch_orders"

    schema do
      field(:order_id, :keyword, primary_key: true)
      embeds_many(:parts, PlainPart, mode: :nested)
    end
  end

  defp build!(schema, opts), do: elem({:ok, _} = PagedQuery.build(schema, opts), 1)
  defp bool(body), do: body["query"]["bool"]
  defp filters(body), do: bool(body)["filter"] || []
  defp musts(body), do: bool(body)["must"] || []

  defp multi_match(text, fields),
    do: %{"multi_match" => %{"query" => text, "fields" => fields, "type" => "best_fields"}}

  # -- search -----------------------------------------------------------------

  describe "build/2 search through embeds" do
    test "object-embed searchable fields join the multi_match with dotted paths" do
      body = build!(ObjectOrder, search: "drill")

      # items is object mode, so items.name and the deeper nested items.subs
      # contribute: the flat multi_match carries the object paths and the
      # nested sub-embed becomes a nested should branch.
      assert [
               %{
                 "bool" => %{
                   "should" => [
                     flat,
                     %{"nested" => %{"path" => "items.subs", "query" => sub_query}}
                   ],
                   "minimum_should_match" => 1
                 }
               }
             ] = musts(body)

      assert flat == multi_match("drill", ["shipping.label", "items.name"])
      assert sub_query == multi_match("drill", ["items.subs.note"])
    end

    test "a nested embed with searchable fields produces a bool should with a nested query" do
      body = build!(NestedOrder, search: "drill")

      assert [
               %{
                 "bool" => %{
                   "should" => [
                     flat,
                     %{"nested" => %{"path" => "items", "query" => items_query}}
                   ],
                   "minimum_should_match" => 1
                 }
               }
             ] = musts(body)

      # Root + object-embed fields stay in the flat multi_match.
      assert flat == multi_match("drill", ["title", "shipping.label"])

      # The nested branch combines its own multi_match with the deeper nested
      # scope (composed path), again as a should with minimum_should_match: 1.
      assert %{
               "bool" => %{
                 "should" => [
                   items_flat,
                   %{"nested" => %{"path" => "items.subs", "query" => subs_query}}
                 ],
                 "minimum_should_match" => 1
               }
             } = items_query

      assert items_flat == multi_match("drill", ["items.name"])
      assert subs_query == multi_match("drill", ["items.subs.note"])
    end

    test "a nested embed with nothing searchable is pruned (plain multi_match)" do
      body = build!(PrunedOrder, search: "x")
      assert musts(body) == [multi_match("x", ["title"])]
    end

    test "no searchable field anywhere in the tree errors" do
      assert {:error, :no_searchable_fields} = PagedQuery.build(NoSearchOrder, search: "x")
    end
  end

  # -- filters ----------------------------------------------------------------

  describe "build/2 filters through object embeds" do
    test "sub-filters become independent dotted-path clauses" do
      body = build!(ObjectOrder, filters: [items: [sku: "A", quantity: {:gte, 2}]])

      assert %{"term" => %{"items.sku" => "A"}} in filters(body)
      assert %{"range" => %{"items.quantity" => %{"gte" => 2}}} in filters(body)
      assert length(filters(body)) == 2
    end

    test "a text sub-filter becomes a dotted match in must context" do
      body = build!(ObjectOrder, filters: [items: [comment: "gift"]])

      assert musts(body) == [%{"match" => %{"items.comment" => "gift"}}]
      assert filters(body) == []
    end

    test "embeds_one object filters use the dotted path too" do
      body = build!(NestedOrder, filters: [shipping: [city: "Rome"]])
      assert filters(body) == [%{"term" => %{"shipping.city" => "Rome"}}]
    end
  end

  describe "build/2 filters through nested embeds" do
    test "all sub-filters combine into ONE nested query (correlated semantics)" do
      body = build!(NestedOrder, filters: [items: [sku: "A", quantity: {:gte, 5}]])

      assert filters(body) == [
               %{
                 "nested" => %{
                   "path" => "items",
                   "query" => %{
                     "bool" => %{
                       "filter" => [
                         %{"term" => %{"items.sku" => "A"}},
                         %{"range" => %{"items.quantity" => %{"gte" => 5}}}
                       ]
                     }
                   }
                 }
               }
             ]
    end

    test "a text sub-filter goes to the inner bool must" do
      body = build!(NestedOrder, filters: [items: [sku: "A", comment: "gift"]])

      assert filters(body) == [
               %{
                 "nested" => %{
                   "path" => "items",
                   "query" => %{
                     "bool" => %{
                       "must" => [%{"match" => %{"items.comment" => "gift"}}],
                       "filter" => [%{"term" => %{"items.sku" => "A"}}]
                     }
                   }
                 }
               }
             ]
    end

    test "nested-inside-nested recurses with the composed path" do
      body = build!(NestedOrder, filters: [items: [sku: "A", subs: [tag: "t"]]])

      assert filters(body) == [
               %{
                 "nested" => %{
                   "path" => "items",
                   "query" => %{
                     "bool" => %{
                       "filter" => [
                         %{"term" => %{"items.sku" => "A"}},
                         %{
                           "nested" => %{
                             "path" => "items.subs",
                             "query" => %{
                               "bool" => %{
                                 "filter" => [%{"term" => %{"items.subs.tag" => "t"}}]
                               }
                             }
                           }
                         }
                       ]
                     }
                   }
                 }
               }
             ]
    end

    test "sub-filter specs accept a map" do
      body = build!(NestedOrder, filters: [items: %{sku: "A"}])

      assert [%{"nested" => %{"path" => "items"}}] =
               filters(body)
    end
  end

  describe "build/2 embedded filter errors" do
    test "an unknown field inside a nested embed errors with the dotted path" do
      assert {:error, {:unknown_filter_field, "items.sku_typo"}} =
               PagedQuery.build(NestedOrder, filters: [items: [sku_typo: "x"]])
    end

    test "an unknown field inside an object embed errors with the dotted path" do
      assert {:error, {:unknown_filter_field, "shipping.nope"}} =
               PagedQuery.build(NestedOrder, filters: [shipping: [nope: 1]])
    end

    test "an unknown field two levels deep errors with the composed path" do
      assert {:error, {:unknown_filter_field, "items.subs.nope"}} =
               PagedQuery.build(NestedOrder, filters: [items: [subs: [nope: 1]]])
    end
  end

  # -- sort -------------------------------------------------------------------

  describe "build/2 sort on embedded fields" do
    test "sorting on an embed name is not sortable" do
      assert {:error, {:not_sortable, :items}} =
               PagedQuery.build(NestedOrder, sort: [items: :asc])
    end

    test "sorting on a dotted embedded field is not sortable (current limitation)" do
      assert {:error, {:not_sortable, :"items.quantity"}} =
               PagedQuery.build(NestedOrder, sort: [{:"items.quantity", :asc}])
    end
  end
end
