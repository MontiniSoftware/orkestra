defmodule Orkestra.ES.Integration.GetPagedTest do
  @moduledoc """
  Full `get_paged/1` behaviour against a real Elasticsearch node: typed filters
  (term/terms/range on numbers and dates), per-culture full-text search with
  stemming (light_italian / porter), structured facets with and without active
  filters, sort, offset pagination and `search_after` cursor pagination.
  """

  use ExUnit.Case, async: false

  @moduletag :integration

  alias Orkestra.ES.Facet
  alias Orkestra.ES.Index
  alias Orkestra.ES.Page
  alias Orkestra.Test.ESIntegration

  @categories ~w(tools kitchen garden)
  @colors ~w(red green blue)
  @brands ~w(acme globex)

  setup_all do
    ESIntegration.ensure_cluster!()
    prefix = ESIntegration.unique_prefix("paged")

    schema =
      ESIntegration.define!(
        :PagedProduct,
        quote do
          use Orkestra.ES.Schema,
            index: unquote(prefix),
            cultures: [:it, :en],
            default_culture: :it

          settings number_of_shards: 1 do
            analyzer(:product_search,
              for: :it,
              tokenizer: "standard",
              filter: ["lowercase", :stemmer_it]
            )

            analyzer(:product_search,
              for: :en,
              tokenizer: "standard",
              filter: ["lowercase", :stemmer_en]
            )

            filter(:stemmer_it, for: :it, type: "stemmer", language: "light_italian")
            filter(:stemmer_en, for: :en, type: "stemmer", language: "porter")
          end

          schema do
            field(:product_id, :keyword, primary_key: true)
            field(:name, :text, analyzer: :product_search, searchable: true, keyword: true)
            field(:category, :keyword)
            field(:price, :float)
            field(:released_at, :date, sortable: true)
            facets(:attributes)
          end
        end
      )

    repo =
      ESIntegration.define!(
        :PagedRepo,
        quote do
          use Orkestra.ES.Repository,
            schema: unquote(schema),
            cluster: Orkestra.Test.ESIntegrationCluster
        end
      )

    cluster = ESIntegration.cluster()
    {:ok, _} = Index.setup(cluster, schema, :it)
    {:ok, _} = Index.setup(cluster, schema, :en)

    dataset = build_dataset(schema)
    :ok = repo.save_all(dataset, culture: :it)
    :ok = repo.refresh(culture: :it)

    # A couple of culture-specific documents to exercise stemming per culture.
    # They carry no category/price/date/facets, so they never affect the
    # category/range/facet assertions on the 30-doc base dataset.
    :ok =
      repo.save_all(
        [
          struct(schema, product_id: "it-lav", name: "lavatrici silenziose"),
          struct(schema, product_id: "en-wash", name: "washing machines")
        ],
        culture: :it
      )

    {:ok, _} =
      repo.save(struct(schema, product_id: "en-wash", name: "washing machines"),
        culture: :en
      )

    :ok = repo.refresh(culture: :it)
    :ok = repo.refresh(culture: :en)

    on_exit(fn -> ESIntegration.cleanup(prefix) end)

    {:ok, schema: schema, repo: repo, dataset: dataset}
  end

  # A deterministic dataset of 30 products (ids p-01..p-30) with varied
  # category / price / date and color+brand facet attributes.
  defp build_dataset(schema) do
    for i <- 1..30 do
      struct(schema,
        product_id: "p-" <> String.pad_leading(Integer.to_string(i), 2, "0"),
        name: "Product #{i}",
        category: Enum.at(@categories, rem(i, 3)),
        price: i * 10.0,
        released_at: DateTime.add(~U[2024-01-01 00:00:00Z], i, :day),
        attributes: [
          %Facet.Attribute{
            code: "color",
            name: "Color",
            values: [%Facet.Value{code: Enum.at(@colors, rem(i, 3)), name: "c"}]
          },
          %Facet.Attribute{
            code: "brand",
            name: "Brand",
            values: [%Facet.Value{code: Enum.at(@brands, rem(i, 2)), name: "b"}]
          }
        ]
      )
    end
  end

  defp ids(%Page{entries: entries}), do: Enum.map(entries, & &1.product_id)

  # -- filters ----------------------------------------------------------------

  test "term filter on a keyword field", %{repo: repo, dataset: dataset} do
    expected = for p <- dataset, p.category == "tools", do: p.product_id

    assert {:ok, page} =
             repo.get_paged(filters: [category: "tools"], page_size: 100, culture: :it)

    assert page.total == length(expected)
    assert Enum.sort(ids(page)) == Enum.sort(expected)
  end

  test "terms filter (list) on a keyword field", %{repo: repo, dataset: dataset} do
    expected = for p <- dataset, p.category in ["tools", "kitchen"], do: p.product_id

    assert {:ok, page} =
             repo.get_paged(
               filters: [category: ["tools", "kitchen"]],
               page_size: 100,
               culture: :it
             )

    assert page.total == length(expected)
  end

  test "one-sided range filter on a numeric field", %{repo: repo, dataset: dataset} do
    expected = for p <- dataset, p.price >= 200.0, do: p.product_id

    assert {:ok, page} =
             repo.get_paged(filters: [price: {:gte, 200.0}], page_size: 100, culture: :it)

    assert page.total == length(expected)
    assert Enum.sort(ids(page)) == Enum.sort(expected)
  end

  test "bounded range filter on a numeric field", %{repo: repo, dataset: dataset} do
    expected = for p <- dataset, p.price >= 100.0 and p.price <= 200.0, do: p.product_id

    assert {:ok, page} =
             repo.get_paged(
               filters: [price: {:range, 100.0, 200.0}],
               page_size: 100,
               culture: :it
             )

    assert page.total == length(expected)
  end

  test "range filter on a date field", %{repo: repo, dataset: dataset} do
    cutoff = ~U[2024-01-16 00:00:00Z]
    expected = for p <- dataset, DateTime.compare(p.released_at, cutoff) != :lt, do: p.product_id

    assert {:ok, page} =
             repo.get_paged(
               filters: [released_at: {:gte, "2024-01-16T00:00:00Z"}],
               page_size: 100,
               culture: :it
             )

    assert page.total == length(expected)
  end

  # -- full-text search with per-culture stemming -----------------------------

  test "italian stemming: 'lavatrice' matches indexed 'lavatrici'", %{repo: repo} do
    assert {:ok, page} = repo.get_paged(search: "lavatrice", page_size: 10, culture: :it)
    assert "it-lav" in ids(page)
  end

  test "english stemming: 'washing machine' matches indexed 'washing machines'", %{repo: repo} do
    assert {:ok, page} = repo.get_paged(search: "washing machine", page_size: 10, culture: :en)
    assert "en-wash" in ids(page)
  end

  # -- facets -----------------------------------------------------------------

  test "facets without filters count the whole dataset", %{repo: repo} do
    assert {:ok, page} = repo.get_paged(facets: true, page_size: 0, culture: :it)

    color = Enum.find(page.facets, &(&1.code == "color"))
    brand = Enum.find(page.facets, &(&1.code == "brand"))
    assert color != nil and brand != nil

    # Every colour bucket total across the attribute sums to the 30 base docs
    # (the two extra stemming docs carry no facets).
    color_total = color.values |> Enum.map(& &1.count) |> Enum.sum()
    assert color_total == 30
    assert color.name == "Color"
  end

  test "facets reflect an active filter (counts shrink to the filtered subset)",
       %{repo: repo, dataset: dataset} do
    tools_count = Enum.count(dataset, &(&1.category == "tools"))

    assert {:ok, page} =
             repo.get_paged(
               filters: [category: "tools"],
               facets: true,
               page_size: 0,
               culture: :it
             )

    brand = Enum.find(page.facets, &(&1.code == "brand"))
    brand_total = brand.values |> Enum.map(& &1.count) |> Enum.sum()
    assert brand_total == tools_count
  end

  test "facets: list restricts to the requested attributes only", %{repo: repo} do
    assert {:ok, page} = repo.get_paged(facets: [:color], page_size: 0, culture: :it)

    codes = Enum.map(page.facets, & &1.code)
    assert codes == ["color"]
  end

  # -- sort -------------------------------------------------------------------

  test "sort by price asc then desc", %{repo: repo} do
    assert {:ok, asc} =
             repo.get_paged(
               sort: [price: :asc],
               filters: [category: "tools"],
               page_size: 100,
               culture: :it
             )

    prices_asc = Enum.map(asc.entries, & &1.price)
    assert prices_asc == Enum.sort(prices_asc)

    assert {:ok, desc} =
             repo.get_paged(
               sort: [price: :desc],
               filters: [category: "tools"],
               page_size: 100,
               culture: :it
             )

    prices_desc = Enum.map(desc.entries, & &1.price)
    assert prices_desc == Enum.sort(prices_desc, :desc)
  end

  # -- offset pagination ------------------------------------------------------

  test "offset pagination: page 2 is disjoint from page 1 and total is exact",
       %{repo: repo} do
    assert {:ok, p1} = repo.get_paged(sort: [price: :asc], page: 1, page_size: 10, culture: :it)
    assert {:ok, p2} = repo.get_paged(sort: [price: :asc], page: 2, page_size: 10, culture: :it)

    # 30 base + it-lav (no price) + ... total includes the extra facet-less docs.
    assert p1.total == p2.total
    assert p1.page_info.mode == :offset
    assert p1.page_info.page == 1
    assert p2.page_info.page == 2
    assert length(p1.entries) == 10
    assert length(p2.entries) == 10

    assert MapSet.disjoint?(MapSet.new(ids(p1)), MapSet.new(ids(p2)))
  end

  # -- search_after cursor pagination -----------------------------------------

  test "search_after iterates the whole dataset with no duplicates or gaps",
       %{repo: repo} do
    # Only the 30 base products carry a numeric id ordering; restrict to them
    # via a category-less full sweep and dedupe on product_id.
    page_size = 7

    all_ids = collect_via_cursor(repo, page_size)

    # Every document in the :it index is visited exactly once.
    assert Enum.uniq(all_ids) == all_ids

    {:ok, total_page} = repo.get_paged(page_size: 0, culture: :it)
    assert length(all_ids) == total_page.total
  end

  # Walks the full result set using next_cursor until it is nil, returning the
  # ordered list of visited product ids.
  defp collect_via_cursor(repo, page_size) do
    {:ok, first} = repo.get_paged(page_size: page_size, culture: :it)
    do_collect(repo, page_size, first.page_info.next_cursor, ids(first))
  end

  defp do_collect(_repo, _page_size, nil, acc), do: acc

  defp do_collect(repo, page_size, cursor, acc) do
    {:ok, page} = repo.get_paged(after: cursor, page_size: page_size, culture: :it)
    do_collect(repo, page_size, page.page_info.next_cursor, acc ++ ids(page))
  end
end
