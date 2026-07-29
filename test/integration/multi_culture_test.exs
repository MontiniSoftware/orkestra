defmodule Orkestra.ES.Integration.MultiCultureTest do
  @moduledoc """
  Multi-culture isolation against a real Elasticsearch node: the same primary
  key stored in `:it` and `:en` yields distinct documents per culture, the
  aliases are distinct physical indexes, and a delete in one culture leaves the
  other untouched.
  """

  use ExUnit.Case, async: false

  @moduletag :integration

  alias Orkestra.ES.Index
  alias Orkestra.Test.ESIntegration

  setup_all do
    ESIntegration.ensure_cluster!()
    prefix = ESIntegration.unique_prefix("culture")

    schema =
      ESIntegration.define!(
        :CultureProduct,
        quote do
          use Orkestra.ES.Schema,
            index: unquote(prefix),
            cultures: [:it, :en],
            default_culture: :it

          schema do
            field(:product_id, :keyword, primary_key: true)
            field(:name, :text, searchable: true)
          end
        end
      )

    repo =
      ESIntegration.define!(
        :CultureRepo,
        quote do
          use Orkestra.ES.Repository,
            schema: unquote(schema),
            cluster: Orkestra.Test.ESIntegrationCluster
        end
      )

    cluster = ESIntegration.cluster()
    {:ok, _} = Index.setup(cluster, schema, :it)
    {:ok, _} = Index.setup(cluster, schema, :en)

    on_exit(fn -> ESIntegration.cleanup(prefix) end)
    {:ok, schema: schema, repo: repo}
  end

  test "aliases are distinct and suffixed per culture", %{schema: schema} do
    assert schema.alias_for(:it) != schema.alias_for(:en)
    assert String.ends_with?(schema.alias_for(:it), "_it")
    assert String.ends_with?(schema.alias_for(:en), "_en")
  end

  test "same id, different content per culture; get resolves the right one",
       %{schema: schema, repo: repo} do
    {:ok, _} = repo.save(struct(schema, product_id: "shared", name: "Martello"), culture: :it)
    {:ok, _} = repo.save(struct(schema, product_id: "shared", name: "Hammer"), culture: :en)
    :ok = repo.refresh(culture: :it)
    :ok = repo.refresh(culture: :en)

    assert {:ok, it_doc} = repo.get("shared", culture: :it)
    assert {:ok, en_doc} = repo.get("shared", culture: :en)

    assert it_doc.name == "Martello"
    assert en_doc.name == "Hammer"
  end

  test "delete in one culture does not touch the other", %{schema: schema, repo: repo} do
    {:ok, _} = repo.save(struct(schema, product_id: "iso", name: "Chiave"), culture: :it)
    {:ok, _} = repo.save(struct(schema, product_id: "iso", name: "Wrench"), culture: :en)
    :ok = repo.refresh(culture: :it)
    :ok = repo.refresh(culture: :en)

    assert :ok = repo.delete("iso", culture: :it)
    :ok = repo.refresh(culture: :it)

    assert {:error, :not_found} = repo.get("iso", culture: :it)
    assert {:ok, en_doc} = repo.get("iso", culture: :en)
    assert en_doc.name == "Wrench"
  end

  test "an unknown culture is a tuple error, never a raise", %{repo: repo} do
    assert {:error, {:unknown_culture, :fr, valid}} = repo.get("x", culture: :fr)
    assert :it in valid and :en in valid
  end
end
