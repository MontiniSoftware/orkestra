if Code.ensure_loaded?(Snap.Cluster) do
  defmodule Orkestra.Projection.Storage.ElasticsearchTest do
    @moduledoc false

    use ExUnit.Case, async: false

    @moduletag :elasticsearch

    import Mox

    alias Orkestra.Projection.Storage.Elasticsearch
    alias Orkestra.Projection.Storage

    setup :verify_on_exit!

    # Stub projector module with index_mapping/0 for init tests
    defmodule TestProjectorForES do
      @moduledoc false

      def index_mapping do
        %{"mappings" => %{"properties" => %{"order_id" => %{"type" => "keyword"}}}}
      end
    end

    # -------------------------------------------------------------------------
    # Test 1: Behaviour contract
    # -------------------------------------------------------------------------
    describe "behaviour contract" do
      test "Elasticsearch module declares @behaviour Orkestra.Projection.Storage" do
        behaviours =
          Elasticsearch.__info__(:attributes) |> Keyword.get_values(:behaviour) |> List.flatten()

        assert Storage in behaviours
      end
    end

    # -------------------------------------------------------------------------
    # Tests 2-5: write/4 (purely functional — no Mox needed)
    # -------------------------------------------------------------------------
    describe "write/4" do
      test "returns {:ok, %{action: :index, id: _, doc: _}} when handler returns {:ok, doc, id}" do
        handler = fn _projector_name, _event, _position ->
          {:ok, %{"order_id" => "order-123", "status" => "placed"}, "order-123"}
        end

        result =
          Elasticsearch.write("test_projector", %{type: "OrderPlaced"}, 1, handler: handler)

        assert {:ok, %{action: :index, id: "order-123", doc: doc}} = result
        assert doc["order_id"] == "order-123"
        assert doc["status"] == "placed"
      end

      test "write/4 is deterministic: same handler returns same :id (ADPT-04)" do
        handler = fn _projector_name, _event, _position ->
          {:ok, %{"order_id" => "order-123"}, "order-123"}
        end

        {:ok, result1} =
          Elasticsearch.write("test_projector", %{type: "OrderPlaced"}, 1, handler: handler)

        {:ok, result2} =
          Elasticsearch.write("test_projector", %{type: "OrderPlaced"}, 1, handler: handler)

        assert result1.id == result2.id
        assert result1.id == "order-123"
      end

      test "returns {:ok, %{action: :skip}} when handler returns :skip" do
        handler = fn _projector_name, _event, _position -> :skip end

        result =
          Elasticsearch.write("test_projector", %{type: "UnknownEvent"}, 0, handler: handler)

        assert {:ok, %{action: :skip}} = result
      end

      test "returns {:error, reason} when handler returns {:error, reason}" do
        handler = fn _projector_name, _event, _position ->
          {:error, :unrecognised_event}
        end

        assert {:error, :unrecognised_event} =
                 Elasticsearch.write("test_projector", %{type: "Unknown"}, 0, handler: handler)
      end

      test "raises KeyError when :handler option is missing" do
        assert_raise KeyError, fn ->
          Elasticsearch.write("test_projector", %{type: "SomeEvent"}, 0, [])
        end
      end
    end

    # -------------------------------------------------------------------------
    # Tests 6-8: detect_engine — tested via init/1 which calls detect_engine
    # -------------------------------------------------------------------------
    describe "detect_engine (via init/1)" do
      test "returns :opensearch when GET / returns version.distribution: 'opensearch'" do
        es_response_body =
          Jason.encode!(%{
            "version" => %{
              "number" => "2.17.0",
              "distribution" => "opensearch"
            },
            "name" => "opensearch-node"
          })

        # Mock GET / for engine detection
        expect(Snap.MockHTTPClient, :request, fn _cluster,
                                                 :get,
                                                 "http://localhost:9200",
                                                 _headers,
                                                 _body,
                                                 _opts ->
          {:ok, %Snap.HTTPClient.Response{status: 200, headers: [], body: es_response_body}}
        end)

        # Mock PUT /{index} for ensure_index
        expect(Snap.MockHTTPClient, :request, fn _cluster, :put, _url, _headers, _body, _opts ->
          {:ok,
           %Snap.HTTPClient.Response{
             status: 200,
             headers: [],
             body: Jason.encode!(%{"acknowledged" => true})
           }}
        end)

        {:ok, state} =
          Elasticsearch.init(
            cluster: Orkestra.Test.ESCluster,
            index: "test_orders",
            projector_module: TestProjectorForES
          )

        assert state.engine == :opensearch
      end

      test "returns :elasticsearch when GET / returns version without distribution field" do
        es_response_body =
          Jason.encode!(%{
            "version" => %{
              "number" => "8.15.0",
              "lucene_version" => "9.11.1"
            },
            "name" => "es-node"
          })

        expect(Snap.MockHTTPClient, :request, fn _cluster,
                                                 :get,
                                                 "http://localhost:9200",
                                                 _headers,
                                                 _body,
                                                 _opts ->
          {:ok, %Snap.HTTPClient.Response{status: 200, headers: [], body: es_response_body}}
        end)

        expect(Snap.MockHTTPClient, :request, fn _cluster, :put, _url, _headers, _body, _opts ->
          {:ok,
           %Snap.HTTPClient.Response{
             status: 200,
             headers: [],
             body: Jason.encode!(%{"acknowledged" => true})
           }}
        end)

        {:ok, state} =
          Elasticsearch.init(
            cluster: Orkestra.Test.ESCluster,
            index: "test_orders",
            projector_module: TestProjectorForES
          )

        assert state.engine == :elasticsearch
      end

      test "defaults to :elasticsearch on connection failure" do
        expect(Snap.MockHTTPClient, :request, fn _cluster,
                                                 :get,
                                                 "http://localhost:9200",
                                                 _headers,
                                                 _body,
                                                 _opts ->
          {:error, %Snap.HTTPClient.Error{reason: :econnrefused, origin: nil}}
        end)

        expect(Snap.MockHTTPClient, :request, fn _cluster, :put, _url, _headers, _body, _opts ->
          {:ok,
           %Snap.HTTPClient.Response{
             status: 200,
             headers: [],
             body: Jason.encode!(%{"acknowledged" => true})
           }}
        end)

        {:ok, state} =
          Elasticsearch.init(
            cluster: Orkestra.Test.ESCluster,
            index: "test_orders",
            projector_module: TestProjectorForES
          )

        assert state.engine == :elasticsearch
      end
    end

    # -------------------------------------------------------------------------
    # Tests 9-11: ensure_index — tested via init/1
    # -------------------------------------------------------------------------
    describe "ensure_index (via init/1)" do
      test "calls Snap.Indexes.create with dynamic: strict injected into user mapping" do
        es_response_body =
          Jason.encode!(%{
            "version" => %{"number" => "8.15.0"}
          })

        expect(Snap.MockHTTPClient, :request, fn _cluster,
                                                 :get,
                                                 "http://localhost:9200",
                                                 _headers,
                                                 _body,
                                                 _opts ->
          {:ok, %Snap.HTTPClient.Response{status: 200, headers: [], body: es_response_body}}
        end)

        # Capture the body sent to Snap.Indexes.create (PUT request)
        expect(Snap.MockHTTPClient, :request, fn _cluster, :put, _url, _headers, body, _opts ->
          decoded = Jason.decode!(body)
          # Verify dynamic: strict is present in the mappings block
          assert decoded["mappings"]["dynamic"] == "strict"
          # Verify user properties are also present
          assert decoded["mappings"]["properties"]["order_id"]["type"] == "keyword"

          {:ok,
           %Snap.HTTPClient.Response{
             status: 200,
             headers: [],
             body: Jason.encode!(%{"acknowledged" => true})
           }}
        end)

        assert {:ok, _state} =
                 Elasticsearch.init(
                   cluster: Orkestra.Test.ESCluster,
                   index: "test_orders",
                   projector_module: TestProjectorForES
                 )
      end

      test "returns :ok when index already exists (resource_already_exists_exception)" do
        es_response_body =
          Jason.encode!(%{
            "version" => %{"number" => "8.15.0"}
          })

        expect(Snap.MockHTTPClient, :request, fn _cluster,
                                                 :get,
                                                 "http://localhost:9200",
                                                 _headers,
                                                 _body,
                                                 _opts ->
          {:ok, %Snap.HTTPClient.Response{status: 200, headers: [], body: es_response_body}}
        end)

        # Simulate 400 with resource_already_exists_exception
        already_exists_body =
          Jason.encode!(%{
            "error" => %{
              "type" => "resource_already_exists_exception",
              "reason" => "index [test_orders] already exists"
            },
            "status" => 400
          })

        expect(Snap.MockHTTPClient, :request, fn _cluster, :put, _url, _headers, _body, _opts ->
          {:ok, %Snap.HTTPClient.Response{status: 400, headers: [], body: already_exists_body}}
        end)

        # Should succeed (idempotent)
        assert {:ok, _state} =
                 Elasticsearch.init(
                   cluster: Orkestra.Test.ESCluster,
                   index: "test_orders",
                   projector_module: TestProjectorForES
                 )
      end

      test "returns {:error, {:index_creation_failed, reason}} on other creation errors" do
        es_response_body =
          Jason.encode!(%{
            "version" => %{"number" => "8.15.0"}
          })

        expect(Snap.MockHTTPClient, :request, fn _cluster,
                                                 :get,
                                                 "http://localhost:9200",
                                                 _headers,
                                                 _body,
                                                 _opts ->
          {:ok, %Snap.HTTPClient.Response{status: 200, headers: [], body: es_response_body}}
        end)

        # Simulate 400 with a different error type
        error_body =
          Jason.encode!(%{
            "error" => %{
              "type" => "mapper_parsing_exception",
              "reason" => "mapping specification does not have [type] keys"
            },
            "status" => 400
          })

        expect(Snap.MockHTTPClient, :request, fn _cluster, :put, _url, _headers, _body, _opts ->
          {:ok, %Snap.HTTPClient.Response{status: 400, headers: [], body: error_body}}
        end)

        assert {:error, {:index_creation_failed, _reason}} =
                 Elasticsearch.init(
                   cluster: Orkestra.Test.ESCluster,
                   index: "test_orders",
                   projector_module: TestProjectorForES
                 )
      end
    end

    # -------------------------------------------------------------------------
    # Tests 12-14: reset/2
    # -------------------------------------------------------------------------
    describe "reset/2" do
      test "calls POST /{index}/_delete_by_query with match_all body" do
        expect(Snap.MockHTTPClient, :request, fn _cluster,
                                                 :post,
                                                 "http://localhost:9200/test_orders/_delete_by_query",
                                                 _headers,
                                                 body,
                                                 _opts ->
          decoded = Jason.decode!(body)
          assert decoded["query"]["match_all"] == %{}

          {:ok,
           %Snap.HTTPClient.Response{
             status: 200,
             headers: [],
             body: Jason.encode!(%{"deleted" => 42, "total" => 42})
           }}
        end)

        assert :ok =
                 Elasticsearch.reset("test_projector",
                   cluster: Orkestra.Test.ESCluster,
                   index: "test_orders"
                 )
      end

      test "returns :ok on successful deletion" do
        expect(Snap.MockHTTPClient, :request, fn _cluster, :post, _url, _headers, _body, _opts ->
          {:ok,
           %Snap.HTTPClient.Response{
             status: 200,
             headers: [],
             body: Jason.encode!(%{"deleted" => 0, "total" => 0})
           }}
        end)

        assert :ok =
                 Elasticsearch.reset("test_projector",
                   cluster: Orkestra.Test.ESCluster,
                   index: "test_orders"
                 )
      end

      test "returns {:error, {:reset_failed, reason}} on failure" do
        expect(Snap.MockHTTPClient, :request, fn _cluster, :post, _url, _headers, _body, _opts ->
          {:error, %Snap.HTTPClient.Error{reason: :econnrefused, origin: nil}}
        end)

        assert {:error, {:reset_failed, %Snap.HTTPClient.Error{reason: :econnrefused}}} =
                 Elasticsearch.reset("test_projector",
                   cluster: Orkestra.Test.ESCluster,
                   index: "test_orders"
                 )
      end
    end
  end
end
