defmodule Orkestra.ES.Integration.LifecycleTest do
  @moduledoc """
  Index lifecycle against a real Elasticsearch node: alias + versioned physical
  index creation with the `_meta.orkestra_schema_hash` marker, idempotent
  `setup`, drift detection via `status`, and a zero-downtime `migrate` hotswap
  that preserves documents and swaps the alias to a fresh physical index.
  """

  use ExUnit.Case, async: false

  @moduletag :integration

  alias Orkestra.ES.Index
  alias Orkestra.Test.ESIntegration

  setup_all do
    ESIntegration.ensure_cluster!()
    :ok
  end

  setup do
    prefix = ESIntegration.unique_prefix("lifecycle")
    on_exit(fn -> ESIntegration.cleanup(prefix) end)
    {:ok, prefix: prefix, cluster: ESIntegration.cluster()}
  end

  # A first schema version: two fields, one searchable text.
  defp schema_v1(index) do
    ESIntegration.define!(
      :LifecycleV1,
      quote do
        use Orkestra.ES.Schema, index: unquote(index)

        schema do
          field(:product_id, :keyword, primary_key: true)
          field(:name, :text, searchable: true, keyword: true)
        end
      end
    )
  end

  # A second schema version sharing the same alias but a *different* mapping
  # (an added keyword field) — this changes the mapping hash and triggers drift.
  defp schema_v2(index) do
    ESIntegration.define!(
      :LifecycleV2,
      quote do
        use Orkestra.ES.Schema, index: unquote(index)

        schema do
          field(:product_id, :keyword, primary_key: true)
          field(:name, :text, searchable: true, keyword: true)
          field(:category, :keyword)
        end
      end
    )
  end

  test "setup creates a versioned physical index + alias carrying the schema hash",
       %{prefix: prefix, cluster: cluster} do
    schema = schema_v1(prefix)
    alias_name = schema.alias_for()

    assert {:ok, :created} = Index.setup(cluster, schema)

    # The alias resolves to exactly one physical index named "<alias>-<ts>".
    {:ok, mapping_body} = Snap.Indexes.get_mapping(cluster, alias_name)
    assert map_size(mapping_body) == 1
    [{physical, inner}] = Map.to_list(mapping_body)
    assert String.starts_with?(physical, alias_name <> "-")

    # The physical mapping carries the drift marker equal to the schema hash.
    assert get_in(inner, ["mappings", "_meta", "orkestra_schema_hash"]) ==
             schema.mapping_hash()

    # dynamic: strict is enforced.
    assert inner["mappings"]["dynamic"] == "strict"
  end

  test "repeated setup is idempotent (:already_exists)", %{prefix: prefix, cluster: cluster} do
    schema = schema_v1(prefix)
    assert {:ok, :created} = Index.setup(cluster, schema)
    assert {:ok, :already_exists} = Index.setup(cluster, schema)
  end

  test "status reports no drift for an in-sync alias", %{prefix: prefix, cluster: cluster} do
    schema = schema_v1(prefix)
    assert {:ok, :created} = Index.setup(cluster, schema)

    assert {:ok, status} = Index.status(cluster, schema)
    assert status.exists == true
    assert status.drift? == false
    assert status.current_hash == schema.mapping_hash()
    assert status.schema_hash == schema.mapping_hash()
    assert String.starts_with?(status.physical_index, schema.alias_for() <> "-")
  end

  test "status detects drift after the schema mapping changes",
       %{prefix: prefix, cluster: cluster} do
    v1 = schema_v1(prefix)
    v2 = schema_v2(prefix)

    assert {:ok, :created} = Index.setup(cluster, v1)

    # Same alias, new schema definition → drift.
    assert {:ok, status} = Index.status(cluster, v2)
    assert status.drift? == true
    assert status.current_hash == v1.mapping_hash()
    assert status.schema_hash == v2.mapping_hash()
    refute v1.mapping_hash() == v2.mapping_hash()
  end

  test "migrate hotswaps: documents survive, alias moves, old index is cleaned, then noop",
       %{prefix: prefix, cluster: cluster} do
    v1 = schema_v1(prefix)
    v2 = schema_v2(prefix)
    alias_name = v1.alias_for()

    assert {:ok, :created} = Index.setup(cluster, v1)

    # Index a document behind the alias, refresh so the reindex scroll sees it.
    doc = v1.to_doc(struct(v1, product_id: "p-1", name: "silent washing machine"))
    assert {:ok, _} = Snap.Document.index(cluster, alias_name, doc, "p-1")
    :ok = ESIntegration.refresh(alias_name)

    {:ok, before} = Index.status(cluster, v1)
    old_physical = before.physical_index

    # Migrate to v2: drift → hotswap reindex.
    assert {:ok, :migrated} = Index.migrate(cluster, v2, nil, batch_size: 10)

    :ok = ESIntegration.refresh(alias_name)

    # The document survived the reindex.
    assert {:ok, %{"found" => true, "_source" => source}} =
             Snap.Document.get(cluster, alias_name, "p-1")

    assert v2.from_hit(source).product_id == "p-1"

    # The alias now points to a *new* physical index carrying the v2 hash.
    {:ok, after_status} = Index.status(cluster, v2)
    assert after_status.exists == true
    assert after_status.drift? == false
    assert after_status.current_hash == v2.mapping_hash()
    assert after_status.physical_index != old_physical

    # The old physical index is no longer bound to the alias: resolving the
    # alias yields exactly the new physical index. (Snap's hotswap preserves
    # the 2 most recent *physical* indexes for rollback, so the old index may
    # still exist un-aliased — it is dropped once a third version is swapped in;
    # see the follow-up assertion below.)
    {:ok, aliased} = Snap.Indexes.get_mapping(cluster, alias_name)
    assert Map.keys(aliased) == [after_status.physical_index]

    # Migrating again with no drift is a no-op.
    assert {:ok, :noop} = Index.migrate(cluster, v2, nil, batch_size: 10)

    # A third distinct version forces another hotswap; now the original
    # physical index falls outside the preserve-2 window and is deleted.
    v3 =
      ESIntegration.define!(
        :LifecycleV3,
        quote do
          use Orkestra.ES.Schema, index: unquote(prefix)

          schema do
            field(:product_id, :keyword, primary_key: true)
            field(:name, :text, searchable: true, keyword: true)
            field(:category, :keyword)
            field(:brand, :keyword)
          end
        end
      )

    assert {:ok, :migrated} = Index.migrate(cluster, v3, nil, batch_size: 10)
    {:ok, remaining} = Snap.Indexes.list_starting_with(cluster, alias_name)
    refute old_physical in remaining
  end
end
