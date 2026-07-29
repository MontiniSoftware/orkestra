if Code.ensure_loaded?(Snap.Cluster) do
  # ---------------------------------------------------------------------------
  # Inline schemas used to exercise the alias + versioning lifecycle.
  # ---------------------------------------------------------------------------
  defmodule Orkestra.ES.IndexLifecycleTest.Product do
    @moduledoc false

    use Orkestra.ES.Schema,
      index: "products_lc",
      cultures: [:it, :en],
      default_culture: :it

    settings number_of_shards: 1 do
      analyzer(:std, for: :it, tokenizer: "standard", filter: ["lowercase"])
      analyzer(:std, for: :en, tokenizer: "standard", filter: ["lowercase", "porter_stem"])
    end

    schema do
      field(:product_id, :keyword, primary_key: true)
      field(:name, :text, analyzer: :std, searchable: true)
    end
  end

  defmodule Orkestra.ES.IndexLifecycleTest.Mono do
    @moduledoc false

    use Orkestra.ES.Schema, index: "mono_lc"

    schema do
      field(:id, :keyword, primary_key: true)
      field(:title, :text)
    end
  end

  defmodule Orkestra.ES.IndexLifecycleTest do
    @moduledoc false

    use ExUnit.Case, async: false

    @moduletag :elasticsearch

    import Mox

    alias Orkestra.ES.Index
    alias Orkestra.ES.IndexLifecycleTest.Mono
    alias Orkestra.ES.IndexLifecycleTest.Product

    @cluster Orkestra.Test.ESCluster

    setup :verify_on_exit!

    # -------------------------------------------------------------------------
    # HTTP mock helpers
    # -------------------------------------------------------------------------

    defp ok(body) do
      {:ok, %Snap.HTTPClient.Response{status: 200, headers: [], body: Jason.encode!(body)}}
    end

    defp not_found(index) do
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

    # Extracts the last path segment (the physical index name) from a request URL.
    defp physical_from_url(url) do
      url |> URI.parse() |> Map.get(:path) |> String.trim_leading("/")
    end

    # -------------------------------------------------------------------------
    # setup/3 — creation, naming convention, _meta hash injection
    # -------------------------------------------------------------------------

    describe "setup/3" do
      test "creates a Snap-compatible versioned index with the _meta hash and points the alias" do
        test_pid = self()
        expected_hash = Product.mapping_hash(:it)

        Mox.stub(Snap.MockHTTPClient, :request, fn _cluster, method, url, _headers, body, _opts ->
          cond do
            # alias existence probe
            method == :get and String.contains?(url, "products_lc_it/_mapping") ->
              not_found("products_lc_it")

            # versioned physical index creation
            method == :put and String.match?(url, ~r{/products_lc_it-\d+$}) ->
              send(test_pid, {:created, physical_from_url(url), Jason.decode!(body)})
              ok(%{"acknowledged" => true})

            # list_starting_with for the alias swap
            method == :get and String.contains?(url, "_cat/indices") ->
              ok([])

            # alias swap
            method == :post and String.contains?(url, "_aliases") ->
              ok(%{"acknowledged" => true})

            true ->
              {:error, %Snap.HTTPClient.Error{reason: :unexpected_call, origin: nil}}
          end
        end)

        assert {:ok, :created} = Index.setup(@cluster, Product, :it)

        assert_receive {:created, physical, created_mapping}

        # Naming convention: matches Snap.Indexes list_starting_with / cleanup regex.
        assert Regex.match?(~r/^products_lc_it-[0-9]+$/, physical)

        # _meta hash is injected into the created mapping.
        assert created_mapping["mappings"]["_meta"]["orkestra_schema_hash"] == expected_hash
        # dynamic: strict is enforced.
        assert created_mapping["mappings"]["dynamic"] == "strict"
      end

      test "returns :already_exists when the alias already resolves to an index" do
        Mox.stub(Snap.MockHTTPClient, :request, fn _cluster, :get, url, _headers, _body, _opts ->
          assert String.contains?(url, "products_lc_it/_mapping")
          ok(%{"products_lc_it-111" => %{"mappings" => %{}}})
        end)

        assert {:ok, :already_exists} = Index.setup(@cluster, Product, :it)
      end

      test "supports mono-culture schemas with a single unsuffixed alias" do
        test_pid = self()

        Mox.stub(Snap.MockHTTPClient, :request, fn _cluster,
                                                   method,
                                                   url,
                                                   _headers,
                                                   _body,
                                                   _opts ->
          cond do
            method == :get and String.contains?(url, "mono_lc/_mapping") ->
              not_found("mono_lc")

            method == :put and String.match?(url, ~r{/mono_lc-\d+$}) ->
              send(test_pid, {:created, physical_from_url(url)})
              ok(%{"acknowledged" => true})

            method == :get and String.contains?(url, "_cat/indices") ->
              ok([])

            method == :post and String.contains?(url, "_aliases") ->
              ok(%{"acknowledged" => true})

            true ->
              {:error, %Snap.HTTPClient.Error{reason: :unexpected_call, origin: nil}}
          end
        end)

        assert {:ok, :created} = Index.setup(@cluster, Mono)
        assert_receive {:created, physical}
        assert Regex.match?(~r/^mono_lc-[0-9]+$/, physical)
      end
    end

    # -------------------------------------------------------------------------
    # status/3 — drift detection
    # -------------------------------------------------------------------------

    describe "status/3" do
      test "reports no drift when the deployed hash matches the schema" do
        hash = Product.mapping_hash(:it)

        Mox.stub(Snap.MockHTTPClient, :request, fn _cluster, :get, _url, _headers, _body, _opts ->
          ok(%{
            "products_lc_it-999" => %{
              "mappings" => %{"_meta" => %{"orkestra_schema_hash" => hash}}
            }
          })
        end)

        assert {:ok, status} = Index.status(@cluster, Product, :it)
        assert status.exists == true
        assert status.physical_index == "products_lc_it-999"
        assert status.current_hash == hash
        assert status.schema_hash == hash
        assert status.drift? == false
      end

      test "reports drift when the deployed hash differs from the schema" do
        Mox.stub(Snap.MockHTTPClient, :request, fn _cluster, :get, _url, _headers, _body, _opts ->
          ok(%{
            "products_lc_it-999" => %{
              "mappings" => %{"_meta" => %{"orkestra_schema_hash" => "stale-hash"}}
            }
          })
        end)

        assert {:ok, status} = Index.status(@cluster, Product, :it)
        assert status.exists == true
        assert status.current_hash == "stale-hash"
        assert status.drift? == true
      end

      test "reports drift with current_hash nil for an index created outside Orkestra" do
        Mox.stub(Snap.MockHTTPClient, :request, fn _cluster, :get, _url, _headers, _body, _opts ->
          ok(%{"products_lc_it-999" => %{"mappings" => %{"properties" => %{}}}})
        end)

        assert {:ok, status} = Index.status(@cluster, Product, :it)
        assert status.exists == true
        assert status.current_hash == nil
        assert status.drift? == true
      end

      test "reports the alias as absent on a 404" do
        Mox.stub(Snap.MockHTTPClient, :request, fn _cluster, :get, _url, _headers, _body, _opts ->
          not_found("products_lc_it")
        end)

        assert {:ok, status} = Index.status(@cluster, Product, :it)
        assert status.exists == false
        assert status.physical_index == nil
        assert status.current_hash == nil
        assert status.drift? == false
      end
    end

    # -------------------------------------------------------------------------
    # migrate/4 — noop path
    # -------------------------------------------------------------------------

    describe "migrate/4" do
      test "is a noop when the deployed hash already matches the schema" do
        hash = Product.mapping_hash(:it)

        Mox.stub(Snap.MockHTTPClient, :request, fn _cluster, :get, _url, _headers, _body, _opts ->
          ok(%{
            "products_lc_it-999" => %{
              "mappings" => %{"_meta" => %{"orkestra_schema_hash" => hash}}
            }
          })
        end)

        assert {:ok, :noop} = Index.migrate(@cluster, Product, :it)
      end

      test "creates the index when the alias is absent" do
        Mox.stub(Snap.MockHTTPClient, :request, fn _cluster,
                                                   method,
                                                   url,
                                                   _headers,
                                                   _body,
                                                   _opts ->
          cond do
            method == :get and String.contains?(url, "products_lc_it/_mapping") ->
              not_found("products_lc_it")

            method == :put and String.match?(url, ~r{/products_lc_it-\d+$}) ->
              ok(%{"acknowledged" => true})

            method == :get and String.contains?(url, "_cat/indices") ->
              ok([])

            method == :post and String.contains?(url, "_aliases") ->
              ok(%{"acknowledged" => true})

            true ->
              {:error, %Snap.HTTPClient.Error{reason: :unexpected_call, origin: nil}}
          end
        end)

        assert {:ok, :created} = Index.migrate(@cluster, Product, :it)
      end
    end

    # -------------------------------------------------------------------------
    # setup_all/2 and migrate_all/2 — iterate every culture
    # -------------------------------------------------------------------------

    describe "setup_all/2 and migrate_all/2" do
      test "setup_all creates an index for every declared culture" do
        test_pid = self()

        Mox.stub(Snap.MockHTTPClient, :request, fn _cluster,
                                                   method,
                                                   url,
                                                   _headers,
                                                   _body,
                                                   _opts ->
          cond do
            method == :get and String.contains?(url, "/_mapping") ->
              not_found(physical_from_url(url))

            method == :put and String.match?(url, ~r{/products_lc_(it|en)-\d+$}) ->
              send(test_pid, {:created, physical_from_url(url)})
              ok(%{"acknowledged" => true})

            method == :get and String.contains?(url, "_cat/indices") ->
              ok([])

            method == :post and String.contains?(url, "_aliases") ->
              ok(%{"acknowledged" => true})

            true ->
              {:error, %Snap.HTTPClient.Error{reason: :unexpected_call, origin: nil}}
          end
        end)

        assert {:ok, results} = Index.setup_all(@cluster, Product)
        assert results == [{:it, :created}, {:en, :created}]

        assert_receive {:created, it_physical}
        assert_receive {:created, en_physical}

        physicals = Enum.sort([it_physical, en_physical])
        assert Enum.any?(physicals, &String.starts_with?(&1, "products_lc_it-"))
        assert Enum.any?(physicals, &String.starts_with?(&1, "products_lc_en-"))
      end

      test "migrate_all returns a noop for every in-sync culture" do
        Mox.stub(Snap.MockHTTPClient, :request, fn _cluster, :get, url, _headers, _body, _opts ->
          culture = if String.contains?(url, "products_lc_en"), do: :en, else: :it
          hash = Product.mapping_hash(culture)

          ok(%{
            physical_from_url(url) => %{
              "mappings" => %{"_meta" => %{"orkestra_schema_hash" => hash}}
            }
          })
        end)

        assert {:ok, results} = Index.migrate_all(@cluster, Product)
        assert results == [{:it, :noop}, {:en, :noop}]
      end
    end
  end
end
