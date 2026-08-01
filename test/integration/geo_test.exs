defmodule Orkestra.ES.Integration.GeoTest do
  @moduledoc """
  `:geo_point` behaviour against a real Elasticsearch node: the field maps to
  the native `geo_point` type, a struct round-trips through save/get with its
  `%{lat:, lon:}` value intact, and a `get_paged/1` `geo_distance` filter finds
  documents inside the radius while excluding those outside it.
  """

  use ExUnit.Case, async: false

  @moduletag :integration

  alias Orkestra.ES.Index
  alias Orkestra.Test.ESIntegration

  # A few reference points (lat, lon). Distances from Milan (the query center):
  #   Milan Duomo      → 0 km
  #   Monza            → ~15 km
  #   Rome             → ~480 km
  setup_all do
    ESIntegration.ensure_cluster!()
    :ok
  end

  setup do
    prefix = ESIntegration.unique_prefix("geo")

    schema =
      ESIntegration.define!(
        :GeoPlace,
        quote do
          use Orkestra.ES.Schema, index: unquote(prefix)

          schema do
            field(:place_id, :keyword, primary_key: true)
            field(:name, :text, searchable: true)
            field(:location, :geo_point)
          end
        end
      )

    repo =
      ESIntegration.define!(
        :GeoRepo,
        quote do
          use Orkestra.ES.Repository,
            schema: unquote(schema),
            cluster: Orkestra.Test.ESIntegrationCluster
        end
      )

    cluster = ESIntegration.cluster()
    assert {:ok, :created} = Index.setup(cluster, schema)

    places = [
      struct(schema, place_id: "milan", name: "Milan", location: %{lat: 45.4642, lon: 9.1900}),
      struct(schema, place_id: "monza", name: "Monza", location: %{lat: 45.5845, lon: 9.2744}),
      struct(schema, place_id: "rome", name: "Rome", location: %{lat: 41.9028, lon: 12.4964})
    ]

    :ok = repo.save_all(places)
    :ok = repo.refresh()

    on_exit(fn -> ESIntegration.cleanup(prefix) end)
    {:ok, schema: schema, repo: repo}
  end

  test "the field maps to the native geo_point type", %{schema: schema} do
    assert schema.mapping()["mappings"]["properties"]["location"] == %{"type" => "geo_point"}
  end

  test "save → get round-trips the geo_point value as an atom-keyed map",
       %{repo: repo} do
    assert {:ok, place} = repo.get("monza")
    assert place.location == %{lat: 45.5845, lon: 9.2744}
  end

  test "geo_distance filter finds points inside the radius and excludes those outside",
       %{repo: repo} do
    center = %{lat: 45.4642, lon: 9.1900}

    # A 25 km radius around Milan includes Milan itself and Monza (~15 km) but
    # not Rome (~480 km).
    assert {:ok, page} =
             repo.get_paged(
               filters: [location: {:geo_distance, center, "25km"}],
               page_size: 100
             )

    ids = Enum.map(page.entries, & &1.place_id) |> Enum.sort()
    assert ids == ["milan", "monza"]
    assert page.total == 2

    # Tighten to 5 km: only Milan remains.
    assert {:ok, tight} =
             repo.get_paged(
               filters: [location: {:geo_distance, center, "5km"}],
               page_size: 100
             )

    assert Enum.map(tight.entries, & &1.place_id) == ["milan"]

    # Widen to 1000 km: every place is inside.
    assert {:ok, wide} =
             repo.get_paged(
               filters: [location: {:geo_distance, center, "1000km"}],
               page_size: 100
             )

    assert wide.total == 3
  end

  test "string-keyed center coordinates work end-to-end", %{repo: repo} do
    assert {:ok, page} =
             repo.get_paged(
               filters: [location: {:geo_distance, %{"lat" => 45.4642, "lon" => 9.1900}, "25km"}],
               page_size: 100
             )

    assert Enum.sort(Enum.map(page.entries, & &1.place_id)) == ["milan", "monza"]
  end
end
