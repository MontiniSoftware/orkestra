defmodule Orkestra.ES.Integration.ProjectionTest do
  @moduledoc """
  End-to-end projection against real infrastructure: an InMemory event store
  drives an `Orkestra.Projector.GenServer` whose Elasticsearch storage adapter
  is provisioned from an `Orkestra.ES.Schema` (the new `schema:` path, which
  provisions the alias + versioned index with the `_meta` hash via
  `Orkestra.ES.Index.setup/3`). Published events become ES documents castable
  with the schema's `from_hit/1`, and the projector checkpoint (in real
  Postgres) advances.

  Mirrors the wiring of `test/orkestra/projector/gen_server_es_test.exs`, but
  against a live cluster rather than the Mox HTTP mock.
  """

  use ExUnit.Case, async: false

  @moduletag :integration
  @moduletag :postgres

  alias Orkestra.EventStore.InMemory
  alias Orkestra.Projection.Checkpoint
  alias Orkestra.Projection.Storage.Elasticsearch, as: ESAdapter
  alias Orkestra.Projector.GenServer, as: ProjectorGenServer
  alias Orkestra.Test.ESIntegration
  alias Orkestra.Test.ProjectionRepo

  setup_all do
    ESIntegration.ensure_cluster!()

    # Run the Orkestra checkpoint / dead_letter migrations once.
    Ecto.Adapters.SQL.Sandbox.unboxed_run(ProjectionRepo, fn ->
      Ecto.Migrator.run(
        ProjectionRepo,
        [{1, Orkestra.Projection.Migration}],
        :up,
        all: true,
        migration_lock: false
      )
    end)

    :ok
  end

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(ProjectionRepo)
    Ecto.Adapters.SQL.Sandbox.mode(ProjectionRepo, {:shared, self()})

    {:ok, _} = start_supervised(InMemory)

    prefix = ESIntegration.unique_prefix("proj")

    schema =
      ESIntegration.define!(
        :ProjOrder,
        quote do
          use Orkestra.ES.Schema, index: unquote(prefix)

          schema do
            field(:order_id, :keyword, primary_key: true)
            field(:status, :keyword)
            field(:total, :float)
          end
        end
      )

    on_exit(fn -> ESIntegration.cleanup(prefix) end)
    {:ok, schema: schema, prefix: prefix, cluster: ESIntegration.cluster()}
  end

  defp unique_projector_name, do: "it_proj_#{:erlang.unique_integer([:positive])}"

  # Appends an OrderPlaced-like event carrying an order id + total.
  defp append_order(order_id, total, stream_revision) do
    InMemory.append_events(
      "orders-stream",
      [
        %{
          id: "evt-#{stream_revision}",
          type: "OrderPlaced",
          data: %{order_id: order_id, total: total},
          metadata: %{},
          stream_revision: stream_revision
        }
      ],
      :any
    )
  end

  defp wait_until(max_ms \\ 5000, fun) do
    deadline = System.monotonic_time(:millisecond) + max_ms
    poll(deadline, fun)
  end

  defp poll(deadline, fun) do
    if fun.() do
      :ok
    else
      if System.monotonic_time(:millisecond) >= deadline do
        {:error, :timeout}
      else
        Process.sleep(25)
        poll(deadline, fun)
      end
    end
  end

  defp get_checkpoint(name), do: ProjectionRepo.get_by(Checkpoint, projector_name: name)

  test "events flow through the projector into ES as castable documents; checkpoint advances",
       %{schema: schema, cluster: cluster} do
    projector_name = unique_projector_name()

    # Schema-aware handler: builds a struct from the event and returns the
    # {:ok, doc, id} triple the ES storage adapter expects — exactly what the
    # generated `project_es` DSL produces for a `schema:`-backed projector.
    handler = fn _name, event, _pos ->
      %{order_id: order_id, total: total} = event.data
      doc = schema.to_doc(struct(schema, order_id: order_id, status: "placed", total: total))
      {:ok, doc, order_id}
    end

    config = %{
      repo: ProjectionRepo,
      projector_name: projector_name,
      storage_adapter: ESAdapter,
      event_store: InMemory,
      lifecycle_config: %{max_retries: 2, backoff_base_ms: 5, backoff_cap_ms: 50},
      adapter_opts: [
        cluster: cluster,
        index: schema.alias_for(),
        schema: schema,
        culture: nil,
        handler: handler
      ]
    }

    _pid = start_supervised!({ProjectorGenServer, config})

    append_order("ORD-1", 42.5, 0)
    append_order("ORD-2", 10.0, 1)

    # Checkpoint advances to the last event position.
    assert :ok =
             wait_until(fn ->
               cp = get_checkpoint(projector_name)
               cp != nil && cp.last_position == 1
             end)

    cp = get_checkpoint(projector_name)
    assert cp.halted == false

    # The schema-driven alias + versioned index was provisioned with the
    # _meta hash (new schema path via Index.setup).
    {:ok, status} = Orkestra.ES.Index.status(cluster, schema)
    assert status.exists == true
    assert status.drift? == false
    assert status.current_hash == schema.mapping_hash()

    # The documents are searchable and cast back into the schema struct.
    :ok = ESIntegration.refresh(schema.alias_for())

    assert {:ok, %{"found" => true, "_source" => source}} =
             Snap.Document.get(cluster, schema.alias_for(), "ORD-1")

    order = schema.from_hit(source)
    assert order.order_id == "ORD-1"
    assert order.status == "placed"
    assert order.total == 42.5

    assert {:ok, %{"found" => true}} = Snap.Document.get(cluster, schema.alias_for(), "ORD-2")
  end
end
