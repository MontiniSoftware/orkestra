defmodule Orkestra.ES.Integration.MixTaskTest do
  @moduledoc """
  The `orkestra.es.*` mix tasks driven end-to-end against a real cluster with a
  test `:es_schemas` configuration: `setup` creates the alias, `status` reports
  no drift afterwards, and `migrate --dry-run` reports a noop without changing
  anything.
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  @moduletag :integration

  alias Orkestra.Test.ESIntegration

  setup_all do
    ESIntegration.ensure_cluster!()
    :ok
  end

  setup do
    prefix = ESIntegration.unique_prefix("mixtask")

    schema =
      ESIntegration.define!(
        :MixTaskProduct,
        quote do
          use Orkestra.ES.Schema, index: unquote(prefix)

          schema do
            field(:product_id, :keyword, primary_key: true)
            field(:name, :text, searchable: true)
          end
        end
      )

    previous = Application.get_env(:orkestra, :es_schemas)
    Application.put_env(:orkestra, :es_schemas, [{schema, ESIntegration.cluster()}])

    on_exit(fn ->
      if previous,
        do: Application.put_env(:orkestra, :es_schemas, previous),
        else: Application.delete_env(:orkestra, :es_schemas)

      ESIntegration.cleanup(prefix)
    end)

    {:ok, schema: schema, prefix: prefix, cluster: ESIntegration.cluster()}
  end

  test "orkestra.es.setup → status → migrate --dry-run against the real cluster",
       %{schema: schema, cluster: cluster} do
    # setup: creates the alias + versioned index.
    setup_out =
      capture_io(fn -> Mix.Task.rerun("orkestra.es.setup", []) end)

    assert setup_out =~ "created"

    # The alias is now provisioned with the schema hash.
    {:ok, status} = Orkestra.ES.Index.status(cluster, schema)
    assert status.exists == true
    assert status.drift? == false
    assert status.current_hash == schema.mapping_hash()

    # status: prints a row reporting no drift (drift column == "false").
    status_out =
      capture_io(fn -> Mix.Task.rerun("orkestra.es.status", []) end)

    assert status_out =~ inspect(schema)
    assert status_out =~ "false"

    # migrate --dry-run: reports a noop and changes nothing.
    dry_out =
      capture_io(fn -> Mix.Task.rerun("orkestra.es.migrate", ["--dry-run"]) end)

    assert dry_out =~ "noop"

    {:ok, still} = Orkestra.ES.Index.status(cluster, schema)
    assert still.physical_index == status.physical_index
    assert still.drift? == false
  end
end
