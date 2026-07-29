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

    # Mono-culture schema fixture for the schema-path init tests.
    defmodule OrderSchema do
      @moduledoc false
      use Orkestra.ES.Schema, index: "schema_orders"

      schema do
        field(:order_id, :keyword, primary_key: true)
        field(:status, :keyword)
      end
    end

    defp es_ok(body) do
      {:ok, %Snap.HTTPClient.Response{status: 200, headers: [], body: Jason.encode!(body)}}
    end

    defp es_not_found(index) do
      body =
        Jason.encode!(%{
          "error" => %{
            "type" => "index_not_found_exception",
            "root_cause" => [
              %{"type" => "index_not_found_exception", "reason" => "no such index [#{index}]"}
            ]
          },
          "status" => 404
        })

      {:ok, %Snap.HTTPClient.Response{status: 404, headers: [], body: body}}
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

        # Note: Snap.Request.parse_response/2 converts an HTTP 400 response into
        # {:error, %Snap.ResponseError{type: "resource_already_exists_exception"}}.
        # The body below uses the nested "error" => %{"type" => ...} structure that
        # Snap.ResponseError.exception_from_json/1 reads to populate the :type field.
        # ensure_index/3 matches on %Snap.ResponseError{type: "resource_already_exists_exception"}
        # and returns :ok, making init/1 idempotent on restart.
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

        # Verify idempotency: init returns {:ok, state} even when the index exists
        assert {:ok, state} =
                 Elasticsearch.init(
                   cluster: Orkestra.Test.ESCluster,
                   index: "test_orders",
                   projector_module: TestProjectorForES
                 )

        assert is_map(state)
        assert state.index == "test_orders"
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
    # init/1 with schema: — delegates to Orkestra.ES.Index.setup/3
    # -------------------------------------------------------------------------
    describe "init/1 with schema:" do
      test "provisions a versioned index + alias with the _meta hash (setup path)" do
        test_pid = self()
        expected_hash = OrderSchema.mapping_hash()

        Mox.stub(Snap.MockHTTPClient, :request, fn _cluster, method, url, _headers, body, _opts ->
          cond do
            # engine detection GET /
            method == :get and url == "http://localhost:9200" ->
              es_ok(%{"version" => %{"number" => "8.15.0"}})

            # alias existence probe → not found (so setup creates)
            method == :get and String.contains?(url, "schema_orders/_mapping") ->
              es_not_found("schema_orders")

            # versioned physical index creation
            method == :put and String.match?(url, ~r{/schema_orders-\d+$}) ->
              send(test_pid, {:created, Jason.decode!(body)})
              es_ok(%{"acknowledged" => true})

            # list_starting_with for the alias swap
            method == :get and String.contains?(url, "_cat/indices") ->
              es_ok([])

            # alias swap
            method == :post and String.contains?(url, "_aliases") ->
              es_ok(%{"acknowledged" => true})

            true ->
              {:error, %Snap.HTTPClient.Error{reason: :unexpected_call, origin: nil}}
          end
        end)

        assert {:ok, state} =
                 Elasticsearch.init(
                   cluster: Orkestra.Test.ESCluster,
                   index: "schema_orders",
                   schema: OrderSchema,
                   culture: nil
                 )

        # index in the returned state is the alias (load-bearing for the GenServer)
        assert state.index == "schema_orders"
        assert state.engine == :elasticsearch

        # The created physical mapping carries the strict + _meta hash markers.
        assert_receive {:created, created_mapping}
        assert created_mapping["mappings"]["dynamic"] == "strict"
        assert created_mapping["mappings"]["_meta"]["orkestra_schema_hash"] == expected_hash
      end

      test "is a no-op when the alias already exists" do
        Mox.stub(Snap.MockHTTPClient, :request, fn _cluster,
                                                   method,
                                                   url,
                                                   _headers,
                                                   _body,
                                                   _opts ->
          cond do
            method == :get and url == "http://localhost:9200" ->
              es_ok(%{"version" => %{"number" => "8.15.0"}})

            method == :get and String.contains?(url, "schema_orders/_mapping") ->
              es_ok(%{"schema_orders-111" => %{"mappings" => %{}}})

            true ->
              {:error, %Snap.HTTPClient.Error{reason: :unexpected_call, origin: nil}}
          end
        end)

        assert {:ok, state} =
                 Elasticsearch.init(
                   cluster: Orkestra.Test.ESCluster,
                   index: "schema_orders",
                   schema: OrderSchema,
                   culture: nil
                 )

        assert state.index == "schema_orders"
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

      test "returns :ok when index does not exist (index_not_found_exception)" do
        # Simulates the case where reset/2 is called before init/1 has run,
        # or after manual index deletion. Snap.Request.parse_response/2 converts
        # HTTP 404 with index_not_found_exception into
        # {:error, %Snap.ResponseError{type: "index_not_found_exception"}}.
        # reset/2 treats this as a no-op — the index is already empty.
        index_not_found_body =
          Jason.encode!(%{
            "error" => %{
              "type" => "index_not_found_exception",
              "reason" => "no such index [test_orders]"
            },
            "status" => 404
          })

        expect(Snap.MockHTTPClient, :request, fn _cluster, :post, _url, _headers, _body, _opts ->
          {:ok, %Snap.HTTPClient.Response{status: 404, headers: [], body: index_not_found_body}}
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
