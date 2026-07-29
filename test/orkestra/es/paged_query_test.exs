defmodule Orkestra.ES.PagedQueryTest do
  @moduledoc false

  use ExUnit.Case, async: true

  alias Orkestra.ES.Facet
  alias Orkestra.ES.Page
  alias Orkestra.ES.PagedQuery

  # -- Fixture schemas --------------------------------------------------------

  defmodule Product do
    @moduledoc false
    use Orkestra.ES.Schema,
      index: "paged_products",
      cultures: [:it, :en],
      default_culture: :it

    schema do
      field(:product_id, :keyword, primary_key: true)
      field(:name, :text, searchable: true, keyword: true)
      field(:description, :text)
      field(:category, :keyword)
      field(:active, :boolean)
      field(:tags, {:array, :keyword})
      field(:price, :float)
      field(:stock, :integer)
      field(:released_at, :date, sortable: true)
      facets(:attributes)
    end
  end

  defmodule Bare do
    @moduledoc false
    use Orkestra.ES.Schema, index: "paged_bare"

    schema do
      field(:id, :keyword, primary_key: true)
      field(:title, :text)
    end
  end

  # Convenience accessors into a built body.
  defp build!(opts), do: elem({:ok, _} = PagedQuery.build(Product, opts), 1)
  defp bool(body), do: body["query"]["bool"]
  defp filters(body), do: bool(body)["filter"] || []
  defp musts(body), do: bool(body)["must"] || []

  # -- baseline ---------------------------------------------------------------

  describe "build/2 baseline" do
    test "defaults to page 1, size 20, match_all with a primary-key tiebreaker" do
      body = build!([])

      assert bool(body) == %{}
      assert body["size"] == 20
      assert body["from"] == 0
      assert body["track_total_hits"] == true
      assert body["sort"] == [%{"product_id" => %{"order" => "asc"}}]
      refute Map.has_key?(body, "aggs")
      refute Map.has_key?(body, "search_after")
    end
  end

  # -- filters ----------------------------------------------------------------

  describe "build/2 keyword/boolean filters" do
    test "scalar keyword becomes a term in filter context" do
      body = build!(filters: [category: "tools"])
      assert %{"term" => %{"category" => "tools"}} in filters(body)
    end

    test "list keyword becomes a terms" do
      body = build!(filters: [category: ["a", "b"]])
      assert %{"terms" => %{"category" => ["a", "b"]}} in filters(body)
    end

    test "boolean becomes a term" do
      body = build!(filters: [active: true])
      assert %{"term" => %{"active" => true}} in filters(body)
    end

    test "array-of-keyword scalar becomes a term, list becomes terms" do
      assert %{"term" => %{"tags" => "x"}} in filters(build!(filters: [tags: "x"]))
      assert %{"terms" => %{"tags" => ["x", "y"]}} in filters(build!(filters: [tags: ["x", "y"]]))
    end
  end

  describe "build/2 numeric/date filters" do
    test "scalar numeric becomes a term" do
      body = build!(filters: [stock: 5])
      assert %{"term" => %{"stock" => 5}} in filters(body)
    end

    test "op tuple becomes a one-sided range" do
      body = build!(filters: [price: {:gte, 100}])
      assert %{"range" => %{"price" => %{"gte" => 100}}} in filters(body)
    end

    test "{:range, from, to} becomes a gte/lte range" do
      body = build!(filters: [price: {:range, 10, 20}])
      assert %{"range" => %{"price" => %{"gte" => 10, "lte" => 20}}} in filters(body)
    end

    test "{:range, nil, to} omits the missing bound" do
      body = build!(filters: [price: {:range, nil, 20}])
      assert %{"range" => %{"price" => %{"lte" => 20}}} in filters(body)
    end

    test "a list of op tuples merges into a combined range" do
      body = build!(filters: [price: [gte: 10, lte: 20]])
      assert %{"range" => %{"price" => %{"gte" => 10, "lte" => 20}}} in filters(body)
    end

    test "date scalar becomes a term" do
      body = build!(filters: [released_at: "2024-01-01"])
      assert %{"term" => %{"released_at" => "2024-01-01"}} in filters(body)
    end
  end

  describe "build/2 text filters" do
    test "text field becomes a match in must context" do
      body = build!(filters: [description: "hammer"])
      assert %{"match" => %{"description" => "hammer"}} in musts(body)
      assert filters(body) == []
    end
  end

  describe "build/2 facet filters" do
    test "each attribute pair becomes a nested filter (AND of pairs)" do
      body = build!(filters: [attributes: [color: "red", size: ["l", "xl"]]])
      nested = filters(body)

      assert %{
               "nested" => %{
                 "path" => "attributes",
                 "query" => %{
                   "bool" => %{
                     "must" => [
                       %{"term" => %{"attributes.attr_code" => "color"}},
                       %{"term" => %{"attributes.value_code" => "red"}}
                     ]
                   }
                 }
               }
             } in nested

      assert %{
               "nested" => %{
                 "path" => "attributes",
                 "query" => %{
                   "bool" => %{
                     "must" => [
                       %{"term" => %{"attributes.attr_code" => "size"}},
                       %{"terms" => %{"attributes.value_code" => ["l", "xl"]}}
                     ]
                   }
                 }
               }
             } in nested

      assert length(nested) == 2
    end
  end

  describe "build/2 filters as a map" do
    test "accepts a map of filters" do
      body = build!(filters: %{category: "tools"})
      assert %{"term" => %{"category" => "tools"}} in filters(body)
    end

    test "unknown field returns an error" do
      assert {:error, {:unknown_filter_field, :nope}} =
               PagedQuery.build(Product, filters: [nope: 1])
    end
  end

  # -- search -----------------------------------------------------------------

  describe "build/2 search" do
    test "search becomes a multi_match over searchable fields in must context" do
      body = build!(search: "trapano")

      assert %{
               "multi_match" => %{
                 "query" => "trapano",
                 "fields" => ["name"],
                 "type" => "best_fields"
               }
             } in musts(body)
    end

    test "search on a schema without searchable fields errors" do
      assert {:error, :no_searchable_fields} = PagedQuery.build(Bare, search: "x")
    end

    test "blank search is ignored" do
      body = build!(search: "")
      assert musts(body) == []
    end
  end

  # -- sort -------------------------------------------------------------------

  describe "build/2 sort" do
    test "text field sorts on the keyword sub-field, with pk tiebreaker" do
      body = build!(sort: [name: :desc])

      assert body["sort"] == [
               %{"name.keyword" => %{"order" => "desc"}},
               %{"product_id" => %{"order" => "asc"}}
             ]
    end

    test "non-text field sorts on the field directly" do
      body = build!(sort: [released_at: :desc])

      assert body["sort"] == [
               %{"released_at" => %{"order" => "desc"}},
               %{"product_id" => %{"order" => "asc"}}
             ]
    end

    test "a plain text field without a keyword sub-field is not sortable" do
      assert {:error, {:not_sortable, :description}} =
               PagedQuery.build(Product, sort: [description: :asc])
    end

    test "an unknown sort field is not sortable" do
      assert {:error, {:not_sortable, :nope}} = PagedQuery.build(Product, sort: [nope: :asc])
    end

    test "sorting on the primary key does not duplicate the tiebreaker" do
      body = build!(sort: [product_id: :desc])
      assert body["sort"] == [%{"product_id" => %{"order" => "desc"}}]
    end
  end

  # -- aggregations -----------------------------------------------------------

  describe "build/2 facet aggregations" do
    test "facets: true builds the nested terms aggregation" do
      body = build!(facets: true)

      assert %{
               "facets" => %{
                 "nested" => %{"path" => "attributes"},
                 "aggs" => %{
                   "attr" => %{
                     "terms" => %{"field" => "attributes.attr_code", "size" => 100},
                     "aggs" => %{
                       "attr_name" => %{
                         "terms" => %{"field" => "attributes.attr_name", "size" => 1}
                       },
                       "value" => %{
                         "terms" => %{"field" => "attributes.value_code", "size" => 100},
                         "aggs" => %{
                           "value_name" => %{
                             "terms" => %{"field" => "attributes.value_name", "size" => 1}
                           }
                         }
                       }
                     }
                   }
                 }
               }
             } = body["aggs"]
    end

    test "facets: [codes] restricts the attr_code terms with include" do
      body = build!(facets: [:color, "brand"])
      assert body["aggs"]["facets"]["aggs"]["attr"]["terms"]["include"] == ["color", "brand"]
    end

    test "facets on a schema without a facets slot errors" do
      assert {:error, :no_facets_field} = PagedQuery.build(Bare, facets: true)
    end

    test "no facets requested leaves aggs out" do
      refute Map.has_key?(build!([]), "aggs")
    end
  end

  # -- pagination -------------------------------------------------------------

  describe "build/2 pagination" do
    test "page/page_size map to from/size" do
      body = build!(page: 3, page_size: 25)
      assert body["from"] == 50
      assert body["size"] == 25
      refute Map.has_key?(body, "search_after")
    end

    test "after cursor maps to search_after with no from" do
      cursor = Base.url_encode64(Jason.encode!(["Saw", "p-2"]), padding: false)
      body = build!(after: cursor, page_size: 10)

      assert body["search_after"] == ["Saw", "p-2"]
      assert body["size"] == 10
      refute Map.has_key?(body, "from")
    end

    test "after and page together conflict" do
      cursor = Base.url_encode64(Jason.encode!(["x"]), padding: false)
      assert {:error, :conflicting_pagination} = PagedQuery.build(Product, after: cursor, page: 2)
    end

    test "a malformed cursor is rejected" do
      assert {:error, :invalid_cursor} = PagedQuery.build(Product, after: "!!!not-base64!!!")
    end

    test "a well-formed but non-list cursor is rejected" do
      cursor = Base.url_encode64(Jason.encode!(%{"a" => 1}), padding: false)
      assert {:error, :invalid_cursor} = PagedQuery.build(Product, after: cursor)
    end
  end

  # -- parse_response ---------------------------------------------------------

  describe "parse_response/3" do
    defp full_body do
      %{
        "hits" => %{
          "total" => %{"value" => 42},
          "hits" => [
            %{
              "_source" => %{"product_id" => "p-1", "name" => "Drill", "category" => "tools"},
              "sort" => ["Drill", "p-1"]
            },
            %{
              "_source" => %{"product_id" => "p-2", "name" => "Saw"},
              "sort" => ["Saw", "p-2"]
            }
          ]
        },
        "aggregations" => %{
          "facets" => %{
            "attr" => %{
              "buckets" => [
                %{
                  "key" => "color",
                  "doc_count" => 10,
                  "attr_name" => %{"buckets" => [%{"key" => "Color"}]},
                  "value" => %{
                    "buckets" => [
                      %{
                        "key" => "red",
                        "doc_count" => 6,
                        "value_name" => %{"buckets" => [%{"key" => "Red"}]}
                      },
                      %{
                        "key" => "blue",
                        "doc_count" => 4,
                        "value_name" => %{"buckets" => [%{"key" => "Blue"}]}
                      }
                    ]
                  }
                }
              ]
            }
          }
        }
      }
    end

    test "extracts entries, total, facets and next_cursor" do
      page = PagedQuery.parse_response(Product, [facets: true, page_size: 2], full_body())

      assert %Page{} = page

      assert [%Product{product_id: "p-1", name: "Drill"}, %Product{product_id: "p-2"}] =
               page.entries

      assert page.total == 42

      assert [
               %Facet.Attribute{
                 code: "color",
                 name: "Color",
                 values: [
                   %Facet.Value{code: "red", name: "Red", count: 6},
                   %Facet.Value{code: "blue", name: "Blue", count: 4}
                 ]
               }
             ] = page.facets

      # offset page_info
      assert page.page_info.mode == :offset
      assert page.page_info.page == 1
      assert page.page_info.page_size == 2
      assert page.page_info.total_pages == 21

      # next_cursor round-trips to the last hit's sort values
      assert is_binary(page.page_info.next_cursor)
      {:ok, json} = Base.url_decode64(page.page_info.next_cursor, padding: false)
      assert Jason.decode!(json) == ["Saw", "p-2"]
    end

    test "facets: false yields nil facets" do
      page = PagedQuery.parse_response(Product, [page_size: 2], full_body())
      assert page.facets == nil
    end

    test "next_cursor is nil when fewer hits than page_size are returned" do
      page = PagedQuery.parse_response(Product, [page_size: 20], full_body())
      assert page.page_info.next_cursor == nil
    end

    test "cursor mode produces a cursor page_info" do
      cursor = Base.url_encode64(Jason.encode!(["x"]), padding: false)
      page = PagedQuery.parse_response(Product, [after: cursor, page_size: 2], full_body())

      assert page.page_info.mode == :cursor
      assert page.page_info.page_size == 2
      refute Map.has_key?(page.page_info, :total_pages)
    end

    test "an integer total is handled" do
      body = %{"hits" => %{"total" => 3, "hits" => []}}
      page = PagedQuery.parse_response(Product, [page_size: 20], body)
      assert page.total == 3
      assert page.entries == []
    end

    test "a cursor round-trips through build/2" do
      page = PagedQuery.parse_response(Product, [page_size: 2], full_body())
      cursor = page.page_info.next_cursor

      {:ok, body} = PagedQuery.build(Product, after: cursor, page_size: 2)
      assert body["search_after"] == ["Saw", "p-2"]
    end
  end
end
