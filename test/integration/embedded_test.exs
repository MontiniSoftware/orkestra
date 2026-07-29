defmodule Orkestra.ES.Integration.EmbeddedTest do
  @moduledoc """
  Embedded-schema behaviour against a real Elasticsearch node: recursive
  round-trip of nested structs, the correlation semantics of `mode: :nested`
  versus the cross-entry false positives of `mode: :object` (same embedded
  schema, two root fixtures), full-text search reaching a searchable field
  inside a nested embed, nested filters combined with facets, and the
  inheritance of `dynamic: strict` into embedded properties.
  """

  use ExUnit.Case, async: false

  @moduletag :integration

  alias Orkestra.ES.Facet
  alias Orkestra.ES.Index
  alias Orkestra.ES.Page
  alias Orkestra.Test.ESIntegration

  setup_all do
    ESIntegration.ensure_cluster!()
    prefix = ESIntegration.unique_prefix("embedded")
    nested_index = prefix <> "_nested"
    object_index = prefix <> "_object"

    sub =
      ESIntegration.define!(
        :EmbSub,
        quote do
          use Orkestra.ES.Schema, embedded: true

          schema do
            field(:code, :keyword)
            field(:note, :text)
          end
        end
      )

    item =
      ESIntegration.define!(
        :EmbItem,
        quote do
          use Orkestra.ES.Schema, embedded: true

          schema do
            field(:sku, :keyword)
            field(:name, :text, searchable: true)
            field(:quantity, :integer)
            embeds_many(:subs, unquote(sub), mode: :nested)
          end
        end
      )

    nested_schema =
      ESIntegration.define!(
        :EmbNestedRoot,
        quote do
          use Orkestra.ES.Schema, index: unquote(nested_index)

          schema do
            field(:order_id, :keyword, primary_key: true)
            field(:status, :keyword)
            embeds_many(:items, unquote(item), mode: :nested)
            facets(:attributes)
          end
        end
      )

    object_schema =
      ESIntegration.define!(
        :EmbObjectRoot,
        quote do
          use Orkestra.ES.Schema, index: unquote(object_index)

          schema do
            field(:order_id, :keyword, primary_key: true)
            field(:status, :keyword)
            embeds_many(:items, unquote(item), mode: :object)
          end
        end
      )

    nested_repo =
      ESIntegration.define!(
        :EmbNestedRepo,
        quote do
          use Orkestra.ES.Repository,
            schema: unquote(nested_schema),
            cluster: Orkestra.Test.ESIntegrationCluster
        end
      )

    object_repo =
      ESIntegration.define!(
        :EmbObjectRepo,
        quote do
          use Orkestra.ES.Repository,
            schema: unquote(object_schema),
            cluster: Orkestra.Test.ESIntegrationCluster
        end
      )

    cluster = ESIntegration.cluster()
    {:ok, _} = Index.setup(cluster, nested_schema, nil)
    {:ok, _} = Index.setup(cluster, object_schema, nil)

    # o-1: item A has quantity 1 and item B has quantity 5 — the pivotal doc
    # for the correlation demonstration. o-2: item A has quantity 7, so the
    # combined condition (sku A AND quantity >= 5) truly holds on one entry.
    items_o1 = [
      struct(item,
        sku: "A",
        name: "Cordless Drill",
        quantity: 1,
        subs: [struct(sub, code: "warranty", note: "two years")]
      ),
      struct(item, sku: "B", name: "Hand Saw", quantity: 5)
    ]

    items_o2 = [
      struct(item, sku: "A", name: "Cordless Drill", quantity: 7),
      struct(item, sku: "C", name: "Wood Glue", quantity: 1)
    ]

    facet = fn color ->
      [
        %Facet.Attribute{
          code: "color",
          name: "Color",
          values: [%Facet.Value{code: color, name: String.capitalize(color)}]
        }
      ]
    end

    :ok =
      nested_repo.save_all([
        struct(nested_schema,
          order_id: "o-1",
          status: "placed",
          items: items_o1,
          attributes: facet.("red")
        ),
        struct(nested_schema,
          order_id: "o-2",
          status: "placed",
          items: items_o2,
          attributes: facet.("blue")
        )
      ])

    :ok =
      object_repo.save_all([
        struct(object_schema, order_id: "o-1", status: "placed", items: items_o1),
        struct(object_schema, order_id: "o-2", status: "placed", items: items_o2)
      ])

    :ok = nested_repo.refresh()
    :ok = object_repo.refresh()

    on_exit(fn -> ESIntegration.cleanup(prefix) end)

    {:ok,
     item: item,
     sub: sub,
     nested_schema: nested_schema,
     object_schema: object_schema,
     nested_repo: nested_repo,
     object_repo: object_repo,
     items_o1: items_o1}
  end

  defp ids(%Page{entries: entries}), do: entries |> Enum.map(& &1.order_id) |> Enum.sort()

  # -- round-trip -------------------------------------------------------------

  test "recursive round-trip of nested structs through a real index",
       %{nested_repo: repo, items_o1: items_o1} do
    assert {:ok, order} = repo.get("o-1")

    assert order.order_id == "o-1"
    assert order.status == "placed"
    assert order.items == items_o1

    # Second level survives the round-trip too.
    [first_item | _] = order.items
    assert [%{code: "warranty", note: "two years"}] = first_item.subs

    # Facets regroup alongside the embeds.
    assert [%Facet.Attribute{code: "color"}] = order.attributes
  end

  # -- correlation semantics: nested vs object --------------------------------

  test "a nested combined filter requires both conditions on the SAME entry",
       %{nested_repo: repo} do
    assert {:ok, page} =
             repo.get_paged(filters: [items: [sku: "A", quantity: {:gte, 5}]], page_size: 10)

    # o-1 has sku A (qty 1) and qty 5 (sku B) on DIFFERENT entries: no match.
    assert ids(page) == ["o-2"]
    assert page.total == 1
  end

  test "the same filter in object mode produces the cross-entry false positive",
       %{object_repo: repo} do
    assert {:ok, page} =
             repo.get_paged(filters: [items: [sku: "A", quantity: {:gte, 5}]], page_size: 10)

    # Object mode flattens the array: sku A (from one entry) and quantity >= 5
    # (from another) both exist somewhere in o-1, so it matches too.
    assert ids(page) == ["o-1", "o-2"]
    assert page.total == 2
  end

  # -- full-text search into nested embeds ------------------------------------

  test "search reaches a searchable field inside a nested embed", %{nested_repo: repo} do
    assert {:ok, page} = repo.get_paged(search: "drill", page_size: 10)
    assert ids(page) == ["o-1", "o-2"]

    assert {:ok, page} = repo.get_paged(search: "saw", page_size: 10)
    assert ids(page) == ["o-1"]
  end

  # -- nested filter + facets together ----------------------------------------

  test "get_paged combines a nested filter with facet aggregations", %{nested_repo: repo} do
    assert {:ok, page} =
             repo.get_paged(
               filters: [items: [sku: "A", quantity: {:gte, 5}]],
               facets: true,
               page_size: 10
             )

    assert ids(page) == ["o-2"]

    # Facet counts reflect the active nested filter: only o-2 (blue) remains.
    color = Enum.find(page.facets, &(&1.code == "color"))
    assert [%Facet.Value{code: "blue", count: 1}] = color.values
  end

  # -- dynamic strict inheritance ---------------------------------------------

  test "dynamic: strict at the top level rejects unknown fields inside embeds",
       %{nested_schema: schema} do
    cluster = ESIntegration.cluster()
    alias_name = schema.alias_for()

    doc = %{
      "order_id" => "bad-1",
      "status" => "placed",
      "items" => [%{"sku" => "X", "bogus_field" => 1}]
    }

    assert {:error, %Snap.ResponseError{type: type}} =
             Snap.post(cluster, "/#{alias_name}/_doc/bad-1", doc)

    assert type == "strict_dynamic_mapping_exception"
  end
end
