defmodule Orkestra.ES.Integration.CrudTest do
  @moduledoc """
  Repository CRUD round-trip against a real Elasticsearch node: `save`/`get`
  struct fidelity (dates, arrays, nils, multi-attribute facets), bulk
  `save_all`, `delete`, `count`, and the scroll-backed `stream`.
  """

  use ExUnit.Case, async: false

  @moduletag :integration

  alias Orkestra.ES.Facet
  alias Orkestra.ES.Index
  alias Orkestra.Test.ESIntegration

  setup_all do
    ESIntegration.ensure_cluster!()
    :ok
  end

  setup do
    prefix = ESIntegration.unique_prefix("crud")

    schema =
      ESIntegration.define!(
        :CrudProduct,
        quote do
          use Orkestra.ES.Schema, index: unquote(prefix)

          schema do
            field(:product_id, :keyword, primary_key: true)
            field(:name, :text, searchable: true, keyword: true)
            field(:category, :keyword)
            field(:price, :float)
            field(:released_at, :date, sortable: true)
            field(:tags, {:array, :keyword})
            facets(:attributes)
          end
        end
      )

    repo =
      ESIntegration.define!(
        :CrudRepo,
        quote do
          use Orkestra.ES.Repository,
            schema: unquote(schema),
            cluster: Orkestra.Test.ESIntegrationCluster
        end
      )

    cluster = ESIntegration.cluster()
    assert {:ok, :created} = Index.setup(cluster, schema)

    on_exit(fn -> ESIntegration.cleanup(prefix) end)
    {:ok, schema: schema, repo: repo, prefix: prefix}
  end

  test "save → refresh → get returns an identical struct (dates, arrays, nil, facets)",
       %{schema: schema, repo: repo} do
    product =
      struct(schema,
        product_id: "p-1",
        name: "Cordless Drill",
        category: "tools",
        price: 129.9,
        released_at: ~U[2024-03-15 10:00:00Z],
        tags: ["power", "diy"],
        attributes: [
          %Facet.Attribute{
            code: "color",
            name: "Color",
            values: [%Facet.Value{code: "red", name: "Red"}]
          },
          %Facet.Attribute{
            code: "brand",
            name: "Brand",
            values: [%Facet.Value{code: "acme", name: "Acme"}]
          }
        ]
      )

    assert {:ok, ^product} = repo.save(product)
    :ok = repo.refresh()

    assert {:ok, fetched} = repo.get("p-1")
    assert fetched.product_id == "p-1"
    assert fetched.name == "Cordless Drill"
    assert fetched.category == "tools"
    assert fetched.price == 129.9
    assert fetched.released_at == ~U[2024-03-15 10:00:00Z]
    assert fetched.tags == ["power", "diy"]

    # Facets round-trip through the flattened nested mapping (multi-attribute).
    assert Enum.sort_by(fetched.attributes, & &1.code) ==
             Enum.sort_by(product.attributes, & &1.code)
  end

  test "nil fields survive the round-trip", %{schema: schema, repo: repo} do
    product = struct(schema, product_id: "p-nil", name: "Bare", category: nil, price: nil)

    assert {:ok, _} = repo.save(product)
    :ok = repo.refresh()

    assert {:ok, fetched} = repo.get("p-nil")
    assert fetched.category == nil
    assert fetched.price == nil
    assert fetched.released_at == nil
    assert fetched.tags == nil || fetched.tags == []
  end

  test "save_all bulk-indexes >= 50 documents and count reflects them",
       %{schema: schema, repo: repo} do
    products =
      for i <- 1..60 do
        struct(schema,
          product_id: "bulk-#{i}",
          name: "Item #{i}",
          category: "cat-#{rem(i, 3)}",
          price: i * 1.0
        )
      end

    assert :ok = repo.save_all(products)
    :ok = repo.refresh()

    assert {:ok, 60} = repo.count()
  end

  test "delete removes a document → get returns :not_found", %{schema: schema, repo: repo} do
    product = struct(schema, product_id: "p-del", name: "Doomed")
    assert {:ok, _} = repo.save(product)
    :ok = repo.refresh()

    assert {:ok, _} = repo.get("p-del")
    assert :ok = repo.delete("p-del")
    :ok = repo.refresh()

    assert {:error, :not_found} = repo.get("p-del")
    assert {:error, :not_found} = repo.delete("p-del")
  end

  test "stream yields every document across multiple scroll pages",
       %{schema: schema, repo: repo} do
    products =
      for i <- 1..55 do
        struct(schema, product_id: "s-#{i}", name: "Streamed #{i}", category: "stream")
      end

    assert :ok = repo.save_all(products)
    :ok = repo.refresh()

    ids =
      repo.stream(scroll: "1m", size: 10)
      |> Enum.map(& &1.product_id)
      |> Enum.sort()

    assert length(ids) == 55
    assert Enum.uniq(ids) == ids
    assert "s-1" in ids and "s-55" in ids
  end
end
