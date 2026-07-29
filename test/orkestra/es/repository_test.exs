if Code.ensure_loaded?(Snap.Cluster) do
  defmodule Orkestra.ES.RepositoryTest do
    @moduledoc false

    use ExUnit.Case, async: false

    @moduletag :elasticsearch

    import Mox

    alias Orkestra.ES.Query
    alias Snap.HTTPClient.Response

    setup :verify_on_exit!

    # -- Fixture schemas + repositories ---------------------------------------

    defmodule Product do
      @moduledoc false
      use Orkestra.ES.Schema,
        index: "repo_products",
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

    defmodule Article do
      @moduledoc false
      use Orkestra.ES.Schema, index: "repo_articles"

      schema do
        field(:id, :keyword, primary_key: true)
        field(:title, :text)
      end
    end

    defmodule ProductsRepo do
      @moduledoc false
      use Orkestra.ES.Repository, schema: Product, cluster: Orkestra.Test.ESCluster
    end

    defmodule ArticlesRepo do
      @moduledoc false
      use Orkestra.ES.Repository, schema: Article, cluster: Orkestra.Test.ESCluster
    end

    defmodule OverrideRepo do
      @moduledoc false
      use Orkestra.ES.Repository, schema: Article, cluster: Orkestra.Test.ESCluster

      # Overrides the generated get/2 without touching the cluster.
      def get(_id, _opts), do: {:ok, :overridden}
    end

    defp ok_response(map),
      do: {:ok, %Response{status: 200, headers: [], body: Jason.encode!(map)}}

    defp response(status, map),
      do: {:ok, %Response{status: status, headers: [], body: Jason.encode!(map)}}

    # -- compile-time validation ----------------------------------------------

    describe "use validation" do
      test "raises when :schema is missing" do
        assert_raise ArgumentError, ~r/requires a :schema option/, fn ->
          defmodule NoSchemaRepo do
            use Orkestra.ES.Repository, cluster: Orkestra.Test.ESCluster
          end
        end
      end

      test "raises when :cluster is missing" do
        assert_raise ArgumentError, ~r/requires a :cluster option/, fn ->
          defmodule NoClusterRepo do
            use Orkestra.ES.Repository, schema: Product
          end
        end
      end
    end

    # -- introspection --------------------------------------------------------

    describe "__es_repository__/1" do
      test "returns the bound schema and cluster" do
        assert ProductsRepo.__es_repository__(:schema) == Product
        assert ProductsRepo.__es_repository__(:cluster) == Orkestra.Test.ESCluster
      end
    end

    # -- get/2 ----------------------------------------------------------------

    describe "get/2" do
      test "returns {:ok, struct} on a found document" do
        expect(Snap.MockHTTPClient, :request, fn _c,
                                                 :get,
                                                 "http://localhost:9200/repo_products_it/_doc/p-1",
                                                 _h,
                                                 _b,
                                                 _o ->
          ok_response(%{
            "found" => true,
            "_source" => %{"product_id" => "p-1", "name" => "Drill", "category" => "tools"}
          })
        end)

        assert {:ok, %Product{} = product} = ProductsRepo.get("p-1")
        assert product.product_id == "p-1"
        assert product.name == "Drill"
      end

      test "returns {:error, :not_found} on a 404" do
        expect(Snap.MockHTTPClient, :request, fn _c, :get, _url, _h, _b, _o ->
          response(404, %{"_index" => "repo_products_it", "_id" => "missing", "found" => false})
        end)

        assert {:error, :not_found} = ProductsRepo.get("missing")
      end

      test "returns {:error, reason} on transport failure" do
        expect(Snap.MockHTTPClient, :request, fn _c, :get, _url, _h, _b, _o ->
          {:error, %Snap.HTTPClient.Error{reason: :econnrefused, origin: nil}}
        end)

        assert {:error, %Snap.HTTPClient.Error{reason: :econnrefused}} = ProductsRepo.get("x")
      end
    end

    # -- save/2 ---------------------------------------------------------------

    describe "save/2" do
      test "upserts with _id from the primary key" do
        product = %Product{product_id: "p-1", name: "Drill"}

        expect(Snap.MockHTTPClient, :request, fn _c,
                                                 :put,
                                                 "http://localhost:9200/repo_products_it/_doc/p-1",
                                                 _h,
                                                 _b,
                                                 _o ->
          response(201, %{"result" => "created"})
        end)

        assert {:ok, ^product} = ProductsRepo.save(product)
      end

      test "returns missing_primary_key without any HTTP call when pk is nil" do
        # No Mox expectation: this must short-circuit before any request.
        assert {:error, {:missing_primary_key, :product_id}} =
                 ProductsRepo.save(%Product{name: "no id"})
      end
    end

    # -- save_all/2 -----------------------------------------------------------

    describe "save_all/2" do
      test "bulk-indexes documents and returns :ok" do
        products = [
          %Product{product_id: "p-1", name: "a"},
          %Product{product_id: "p-2", name: "b"}
        ]

        expect(Snap.MockHTTPClient, :request, fn _c,
                                                 :post,
                                                 "http://localhost:9200/repo_products_it/_bulk",
                                                 _h,
                                                 body,
                                                 _o ->
          # ndjson body (an iolist): an action line and a document line per struct.
          flat = IO.iodata_to_binary(body)
          assert flat =~ ~s("_id":"p-1")
          assert flat =~ ~s("_id":"p-2")
          ok_response(%{"errors" => false, "items" => []})
        end)

        assert :ok = ProductsRepo.save_all(products)
      end

      test "returns missing_primary_key before any HTTP call" do
        # No Mox expectation: validation happens before the bulk request.
        assert {:error, {:missing_primary_key, :product_id}} =
                 ProductsRepo.save_all([
                   %Product{product_id: "p-1", name: "a"},
                   %Product{name: "no id"}
                 ])
      end

      test "returns {:error, %Snap.BulkError{}} when items fail" do
        items = [
          %{
            "index" => %{
              "error" => %{"type" => "mapper_parsing_exception", "reason" => "bad"},
              "status" => 400
            }
          }
        ]

        expect(Snap.MockHTTPClient, :request, fn _c, :post, _url, _h, _b, _o ->
          ok_response(%{"errors" => true, "items" => items})
        end)

        assert {:error, %Snap.BulkError{errors: [%Snap.ResponseError{}]}} =
                 ProductsRepo.save_all([%Product{product_id: "p-1", name: "a"}])
      end
    end

    # -- delete/2 -------------------------------------------------------------

    describe "delete/2" do
      test "returns :ok on deletion" do
        expect(Snap.MockHTTPClient, :request, fn _c,
                                                 :delete,
                                                 "http://localhost:9200/repo_products_it/_doc/p-1",
                                                 _h,
                                                 _b,
                                                 _o ->
          ok_response(%{"result" => "deleted"})
        end)

        assert :ok = ProductsRepo.delete("p-1")
      end

      test "returns {:error, :not_found} when the document is missing" do
        expect(Snap.MockHTTPClient, :request, fn _c, :delete, _url, _h, _b, _o ->
          response(404, %{"_index" => "repo_products_it", "result" => "not_found"})
        end)

        assert {:error, :not_found} = ProductsRepo.delete("missing")
      end
    end

    # -- count/2 --------------------------------------------------------------

    describe "count/2" do
      test "counts all documents with no query" do
        expect(Snap.MockHTTPClient, :request, fn _c,
                                                 :post,
                                                 "http://localhost:9200/repo_products_it/_count",
                                                 _h,
                                                 _b,
                                                 _o ->
          ok_response(%{"count" => 42})
        end)

        assert {:ok, 42} = ProductsRepo.count()
      end

      test "wraps a raw query map under \"query\"" do
        expect(Snap.MockHTTPClient, :request, fn _c, :post, _url, _h, body, _o ->
          decoded = Jason.decode!(body)
          assert decoded["query"]["term"]["category"] == "tools"
          ok_response(%{"count" => 3})
        end)

        assert {:ok, 3} = ProductsRepo.count(query: %{"term" => %{"category" => "tools"}})
      end

      test "extracts the query clause from an %Orkestra.ES.Query{}" do
        query = Query.new() |> Query.filter(term: %{"category" => "tools"})

        expect(Snap.MockHTTPClient, :request, fn _c, :post, _url, _h, body, _o ->
          decoded = Jason.decode!(body)
          assert decoded["query"]["bool"]["filter"] == [%{"term" => %{"category" => "tools"}}]
          ok_response(%{"count" => 1})
        end)

        assert {:ok, 1} = ProductsRepo.count(query: query)
      end
    end

    # -- search/2 -------------------------------------------------------------

    describe "search/2" do
      test "runs an %Orkestra.ES.Query{} and returns the SearchResponse" do
        query = Query.new() |> Query.must(match: %{"name" => "drill"})

        expect(Snap.MockHTTPClient, :request, fn _c,
                                                 :post,
                                                 "http://localhost:9200/repo_products_it/_search",
                                                 _h,
                                                 body,
                                                 _o ->
          decoded = Jason.decode!(body)
          assert decoded["query"]["bool"]["must"] == [%{"match" => %{"name" => "drill"}}]

          ok_response(%{
            "took" => 1,
            "hits" => %{
              "total" => %{"value" => 1},
              "hits" => [%{"_id" => "p-1", "_source" => %{"product_id" => "p-1"}}]
            }
          })
        end)

        assert {:ok, %Snap.SearchResponse{} = resp} = ProductsRepo.search(query)
        assert resp.hits.total == %{"value" => 1}
        # Hits are not decoded — the caller may use Product.from_hit/1.
        [hit] = resp.hits.hits
        assert Product.from_hit(hit.source).product_id == "p-1"
      end

      test "runs a raw request map" do
        raw = %{"query" => %{"match_all" => %{}}, "size" => 5}

        expect(Snap.MockHTTPClient, :request, fn _c, :post, _url, _h, body, _o ->
          decoded = Jason.decode!(body)
          assert decoded["size"] == 5
          ok_response(%{"took" => 1, "hits" => %{"total" => %{"value" => 0}, "hits" => []}})
        end)

        assert {:ok, %Snap.SearchResponse{} = resp} = ProductsRepo.search(raw)
        assert Enum.count(resp) == 0
      end
    end

    # -- refresh/1 ------------------------------------------------------------

    describe "refresh/1" do
      test "returns :ok" do
        expect(Snap.MockHTTPClient, :request, fn _c,
                                                 :post,
                                                 "http://localhost:9200/repo_products_it/_refresh",
                                                 _h,
                                                 _b,
                                                 _o ->
          ok_response(%{"_shards" => %{"total" => 1}})
        end)

        assert :ok = ProductsRepo.refresh()
      end
    end

    # -- stream/1 -------------------------------------------------------------

    describe "stream/1" do
      test "lazily streams decoded structs via the scroll API" do
        # 1. initial search opens the scroll and returns one batch
        expect(Snap.MockHTTPClient, :request, fn _c, :post, url, _h, _b, _o ->
          assert String.contains?(url, "/repo_products_it/_search")

          ok_response(%{
            "took" => 1,
            "_scroll_id" => "scroll-1",
            "hits" => %{
              "total" => %{"value" => 1},
              "hits" => [
                %{"_id" => "p-1", "_source" => %{"product_id" => "p-1", "name" => "Drill"}}
              ]
            }
          })
        end)

        # 2. continuation returns no more hits, terminating the stream
        expect(Snap.MockHTTPClient, :request, fn _c, :post, url, _h, _b, _o ->
          assert String.contains?(url, "/_search/scroll")

          ok_response(%{
            "_scroll_id" => "scroll-1",
            "hits" => %{"total" => %{"value" => 1}, "hits" => []}
          })
        end)

        # 3. cursor cleanup on stream exhaustion
        expect(Snap.MockHTTPClient, :request, fn _c, :delete, url, _h, _b, _o ->
          assert String.contains?(url, "/_search/scroll")
          ok_response(%{"succeeded" => true})
        end)

        results = ProductsRepo.stream() |> Enum.to_list()

        assert [%Product{product_id: "p-1", name: "Drill"}] = results
      end
    end

    # -- culture resolution ---------------------------------------------------

    describe "culture resolution" do
      test "defaults to the schema default culture alias" do
        expect(Snap.MockHTTPClient, :request, fn _c,
                                                 :get,
                                                 "http://localhost:9200/repo_products_it/_doc/p-1",
                                                 _h,
                                                 _b,
                                                 _o ->
          ok_response(%{"found" => true, "_source" => %{"product_id" => "p-1"}})
        end)

        assert {:ok, _} = ProductsRepo.get("p-1")
      end

      test "uses the per-culture alias for an explicit culture" do
        expect(Snap.MockHTTPClient, :request, fn _c,
                                                 :get,
                                                 "http://localhost:9200/repo_products_en/_doc/p-1",
                                                 _h,
                                                 _b,
                                                 _o ->
          ok_response(%{"found" => true, "_source" => %{"product_id" => "p-1"}})
        end)

        assert {:ok, _} = ProductsRepo.get("p-1", culture: :en)
      end

      test "returns a structured error for an unknown culture (no HTTP)" do
        assert {:error, {:unknown_culture, :fr, [:it, :en]}} =
                 ProductsRepo.get("p-1", culture: :fr)
      end

      test "mono-culture schema rejects an explicit culture (no HTTP)" do
        assert {:error, {:unknown_culture, :it, []}} = ArticlesRepo.get("a-1", culture: :it)
      end

      test "mono-culture schema uses the unsuffixed alias by default" do
        expect(Snap.MockHTTPClient, :request, fn _c,
                                                 :get,
                                                 "http://localhost:9200/repo_articles/_doc/a-1",
                                                 _h,
                                                 _b,
                                                 _o ->
          ok_response(%{"found" => true, "_source" => %{"id" => "a-1", "title" => "T"}})
        end)

        assert {:ok, %Article{id: "a-1"}} = ArticlesRepo.get("a-1")
      end

      test "stream/1 raises on an unknown culture" do
        assert_raise ArgumentError, ~r/unknown culture :fr/, fn ->
          ProductsRepo.stream(culture: :fr)
        end
      end
    end

    # -- telemetry ------------------------------------------------------------

    describe "telemetry" do
      test "emits [:orkestra, :es, :request] with op/index/culture/result" do
        handler_id = "test-es-req-#{System.unique_integer([:positive])}"
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

        expect(Snap.MockHTTPClient, :request, fn _c,
                                                 :get,
                                                 "http://localhost:9200/repo_products_it/_doc/p-9",
                                                 _h,
                                                 _b,
                                                 _o ->
          ok_response(%{"found" => true, "_source" => %{"product_id" => "p-9"}})
        end)

        assert {:ok, _} = ProductsRepo.get("p-9")

        assert_receive {:telemetry, [:orkestra, :es, :request], %{duration_ms: duration},
                        metadata}

        assert is_integer(duration)
        assert metadata.op == :get
        assert metadata.index == "repo_products_it"
        assert metadata.culture == :it
        assert metadata.schema == Product
        assert metadata.result == :ok
      end

      test "reports result: :error for an unknown culture" do
        handler_id = "test-es-req-err-#{System.unique_integer([:positive])}"
        test_pid = self()

        :telemetry.attach(
          handler_id,
          [:orkestra, :es, :request],
          fn _name, _measurements, metadata, _ -> send(test_pid, {:telemetry_meta, metadata}) end,
          nil
        )

        on_exit(fn -> :telemetry.detach(handler_id) end)

        assert {:error, {:unknown_culture, :fr, _}} = ProductsRepo.get("p-1", culture: :fr)

        assert_receive {:telemetry_meta, metadata}
        assert metadata.op == :get
        assert metadata.result == :error
        assert metadata.culture == :fr
      end
    end

    # -- overridability -------------------------------------------------------

    describe "defoverridable" do
      test "generated functions can be overridden" do
        # No Mox expectation: the override never touches the cluster.
        assert OverrideRepo.get("anything", []) == {:ok, :overridden}
      end
    end
  end
end
