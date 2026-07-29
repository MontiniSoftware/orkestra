if Code.ensure_loaded?(Snap.Cluster) do
  defmodule Orkestra.ES.GetPagedTest do
    @moduledoc false

    use ExUnit.Case, async: false

    @moduletag :elasticsearch

    import Mox

    alias Orkestra.ES.Facet
    alias Orkestra.ES.Page
    alias Snap.HTTPClient.Response

    setup :verify_on_exit!

    # -- Fixture schema + repository ------------------------------------------

    defmodule Product do
      @moduledoc false
      use Orkestra.ES.Schema,
        index: "paged_repo_products",
        cultures: [:it, :en],
        default_culture: :it

      schema do
        field(:product_id, :keyword, primary_key: true)
        field(:name, :text, searchable: true, keyword: true)
        field(:category, :keyword)
        field(:price, :float)
        facets(:attributes)
      end
    end

    defmodule ProductsRepo do
      @moduledoc false
      use Orkestra.ES.Repository, schema: Product, cluster: Orkestra.Test.ESCluster
    end

    defmodule OverrideRepo do
      @moduledoc false
      use Orkestra.ES.Repository, schema: Product, cluster: Orkestra.Test.ESCluster

      def get_paged(_opts), do: {:ok, :overridden}
    end

    defp ok_response(map),
      do: {:ok, %Response{status: 200, headers: [], body: Jason.encode!(map)}}

    # A search response body with two hits and a facet aggregation.
    defp search_body do
      %{
        "took" => 3,
        "hits" => %{
          "total" => %{"value" => 42},
          "hits" => [
            %{
              "_id" => "p-1",
              "_source" => %{"product_id" => "p-1", "name" => "Drill", "category" => "tools"},
              "sort" => ["Drill", "p-1"]
            },
            %{
              "_id" => "p-2",
              "_source" => %{"product_id" => "p-2", "name" => "Saw", "category" => "tools"},
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

    # -- get_paged/1 happy path -----------------------------------------------

    describe "get_paged/1" do
      test "runs the search and returns a decoded, faceted Page" do
        expect(Snap.MockHTTPClient, :request, fn _c,
                                                 :post,
                                                 "http://localhost:9200/paged_repo_products_it/_search",
                                                 _h,
                                                 body,
                                                 _o ->
          decoded = Jason.decode!(body)
          # filter + facets aggregation reached the wire
          assert decoded["query"]["bool"]["filter"] == [%{"term" => %{"category" => "tools"}}]
          assert decoded["aggs"]["facets"]["nested"]["path"] == "attributes"
          assert decoded["size"] == 2
          assert decoded["track_total_hits"] == true

          ok_response(search_body())
        end)

        assert {:ok, %Page{} = page} =
                 ProductsRepo.get_paged(filters: [category: "tools"], facets: true, page_size: 2)

        assert [%Product{product_id: "p-1", name: "Drill"}, %Product{product_id: "p-2"}] =
                 page.entries

        assert page.total == 42

        assert [
                 %Facet.Attribute{
                   code: "color",
                   name: "Color",
                   values: [%Facet.Value{code: "red", name: "Red", count: 6}]
                 }
               ] = page.facets

        assert page.page_info.mode == :offset
        assert page.page_info.total_pages == 21
        assert is_binary(page.page_info.next_cursor)
      end

      test "next_cursor is nil on the last page" do
        expect(Snap.MockHTTPClient, :request, fn _c, :post, _url, _h, _b, _o ->
          ok_response(search_body())
        end)

        # page_size 20 > 2 hits, so this is the last page
        assert {:ok, %Page{page_info: %{next_cursor: nil}}} =
                 ProductsRepo.get_paged(page_size: 20)
      end

      test "uses the per-culture alias" do
        expect(Snap.MockHTTPClient, :request, fn _c,
                                                 :post,
                                                 "http://localhost:9200/paged_repo_products_en/_search",
                                                 _h,
                                                 _b,
                                                 _o ->
          ok_response(search_body())
        end)

        assert {:ok, %Page{}} = ProductsRepo.get_paged(culture: :en)
      end

      test "propagates a build error without any HTTP call" do
        # No Mox expectation: build fails before the request.
        assert {:error, :conflicting_pagination} =
                 ProductsRepo.get_paged(after: "x", page: 2)
      end

      test "returns a transport error" do
        expect(Snap.MockHTTPClient, :request, fn _c, :post, _url, _h, _b, _o ->
          {:error, %Snap.HTTPClient.Error{reason: :econnrefused, origin: nil}}
        end)

        assert {:error, %Snap.HTTPClient.Error{reason: :econnrefused}} = ProductsRepo.get_paged()
      end

      test "returns a structured error for an unknown culture (no HTTP)" do
        assert {:error, {:unknown_culture, :fr, [:it, :en]}} =
                 ProductsRepo.get_paged(culture: :fr)
      end
    end

    # -- telemetry ------------------------------------------------------------

    describe "telemetry" do
      test "emits [:orkestra, :es, :request] with op :get_paged" do
        handler_id = "test-es-paged-#{System.unique_integer([:positive])}"
        test_pid = self()

        :telemetry.attach(
          handler_id,
          [:orkestra, :es, :request],
          fn name, measurements, metadata, _ ->
            send(test_pid, {:telemetry, name, measurements, metadata})
          end,
          nil
        )

        on_exit(fn -> :telemetry.detach(handler_id) end)

        expect(Snap.MockHTTPClient, :request, fn _c, :post, _url, _h, _b, _o ->
          ok_response(search_body())
        end)

        assert {:ok, _} = ProductsRepo.get_paged()

        assert_receive {:telemetry, [:orkestra, :es, :request], %{duration_ms: duration},
                        metadata}

        assert is_integer(duration)
        assert metadata.op == :get_paged
        assert metadata.index == "paged_repo_products_it"
        assert metadata.culture == :it
        assert metadata.schema == Product
        assert metadata.result == :ok
      end
    end

    # -- overridability -------------------------------------------------------

    describe "defoverridable" do
      test "get_paged can be overridden" do
        # No Mox expectation: the override never touches the cluster.
        assert OverrideRepo.get_paged([]) == {:ok, :overridden}
      end
    end
  end
end
