if Code.ensure_loaded?(Snap.Cluster) do
  defmodule Orkestra.ES.IndexTest do
    @moduledoc false

    use ExUnit.Case, async: false

    @moduletag :elasticsearch

    import Mox

    alias Orkestra.ES.Index

    setup :verify_on_exit!

    # -------------------------------------------------------------------------
    # Tests: detect_engine/1
    # -------------------------------------------------------------------------
    describe "detect_engine/1" do
      test "returns :opensearch when GET / returns version.distribution: 'opensearch'" do
        es_response_body =
          Jason.encode!(%{
            "version" => %{
              "number" => "2.17.0",
              "distribution" => "opensearch"
            },
            "name" => "opensearch-node"
          })

        expect(Snap.MockHTTPClient, :request, fn _cluster,
                                                 :get,
                                                 "http://localhost:9200",
                                                 _headers,
                                                 _body,
                                                 _opts ->
          {:ok, %Snap.HTTPClient.Response{status: 200, headers: [], body: es_response_body}}
        end)

        {:ok, engine} = Index.detect_engine(Orkestra.Test.ESCluster)
        assert engine == :opensearch
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

        {:ok, engine} = Index.detect_engine(Orkestra.Test.ESCluster)
        assert engine == :elasticsearch
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

        {:ok, engine} = Index.detect_engine(Orkestra.Test.ESCluster)
        assert engine == :elasticsearch
      end

      test "defaults to :elasticsearch on malformed response" do
        expect(Snap.MockHTTPClient, :request, fn _cluster,
                                                 :get,
                                                 "http://localhost:9200",
                                                 _headers,
                                                 _body,
                                                 _opts ->
          {:ok, %Snap.HTTPClient.Response{status: 200, headers: [], body: "invalid json"}}
        end)

        {:ok, engine} = Index.detect_engine(Orkestra.Test.ESCluster)
        assert engine == :elasticsearch
      end
    end

    # -------------------------------------------------------------------------
    # Tests: ensure_index/3
    # -------------------------------------------------------------------------
    describe "ensure_index/3" do
      test "calls Snap.Indexes.create with dynamic: strict injected into user mapping" do
        mapping = %{"mappings" => %{"properties" => %{"order_id" => %{"type" => "keyword"}}}}

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

        assert :ok = Index.ensure_index(Orkestra.Test.ESCluster, "test_orders", mapping)
      end

      test "returns :ok when index already exists (resource_already_exists_exception)" do
        mapping = %{"mappings" => %{"properties" => %{"order_id" => %{"type" => "keyword"}}}}

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

        # Verify idempotency: ensure_index returns :ok even when the index exists
        assert :ok = Index.ensure_index(Orkestra.Test.ESCluster, "test_orders", mapping)
      end

      test "returns {:error, {:index_creation_failed, reason}} on other creation errors" do
        mapping = %{"mappings" => %{"properties" => %{"order_id" => %{"type" => "keyword"}}}}

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
                 Index.ensure_index(Orkestra.Test.ESCluster, "test_orders", mapping)
      end

      test "injects dynamic: strict when user mapping has empty mappings" do
        mapping = %{"mappings" => %{}}

        expect(Snap.MockHTTPClient, :request, fn _cluster, :put, _url, _headers, body, _opts ->
          decoded = Jason.decode!(body)
          assert decoded["mappings"]["dynamic"] == "strict"

          {:ok,
           %Snap.HTTPClient.Response{
             status: 200,
             headers: [],
             body: Jason.encode!(%{"acknowledged" => true})
           }}
        end)

        assert :ok = Index.ensure_index(Orkestra.Test.ESCluster, "test_orders", mapping)
      end

      test "injects dynamic: strict even when user supplies a different dynamic value" do
        # User tries to set dynamic: false, but our function overrides it to strict
        mapping = %{
          "mappings" => %{
            "dynamic" => false,
            "properties" => %{"order_id" => %{"type" => "keyword"}}
          }
        }

        expect(Snap.MockHTTPClient, :request, fn _cluster, :put, _url, _headers, body, _opts ->
          decoded = Jason.decode!(body)
          # Verify our override wins
          assert decoded["mappings"]["dynamic"] == "strict"
          assert decoded["mappings"]["properties"]["order_id"]["type"] == "keyword"

          {:ok,
           %Snap.HTTPClient.Response{
             status: 200,
             headers: [],
             body: Jason.encode!(%{"acknowledged" => true})
           }}
        end)

        assert :ok = Index.ensure_index(Orkestra.Test.ESCluster, "test_orders", mapping)
      end
    end
  end
end
