if Code.ensure_loaded?(Snap.Cluster) do
  defmodule Orkestra.Projector.ProjectorDslEsTest do
    @moduledoc false

    use ExUnit.Case, async: false

    @moduletag :elasticsearch

    # -------------------------------------------------------------------------
    # Inline event stubs — minimal structs to carry a :type field
    # -------------------------------------------------------------------------

    defmodule OrderPlaced do
      @moduledoc false
      defstruct [:id, :type, :data, :global_position]
    end

    defmodule OrderShipped do
      @moduledoc false
      defstruct [:id, :type, :data, :global_position]
    end

    # -------------------------------------------------------------------------
    # Inline Postgres projector — used in backward compatibility tests.
    # SomeRepo and SomeEventStore are atom literals (not real modules).
    # -------------------------------------------------------------------------

    defmodule TestPostgresProjectorInES do
      @moduledoc false

      use Orkestra.Projector,
        repo: SomeRepo,
        event_store: SomeEventStore

      project(Orkestra.Projector.ProjectorDslEsTest.OrderPlaced, fn _event, multi ->
        multi
      end)
    end

    # -------------------------------------------------------------------------
    # Inline ES projector definition
    # SomeCheckpointRepo and SomeEventStore are atom literals (not real modules)
    # — they are never called in compile-time DSL tests (same pattern as
    # projector_dsl_test.exs which uses SomeRepo/SomeEventStore).
    # -------------------------------------------------------------------------

    defmodule TestESProjector do
      @moduledoc false

      use Orkestra.Projector,
        backend: :elasticsearch,
        repo: SomeCheckpointRepo,
        cluster: Orkestra.Test.ESCluster,
        index: "test_orders",
        event_store: SomeEventStore

      def index_mapping do
        %{
          "mappings" => %{
            "properties" => %{
              "order_id" => %{"type" => "keyword"},
              "status" => %{"type" => "keyword"}
            }
          }
        }
      end

      project_es(Orkestra.Projector.ProjectorDslEsTest.OrderPlaced, fn event, _position ->
        {:ok, %{"order_id" => event.data.order_id, "status" => "placed"}, event.data.order_id}
      end)

      project_es(Orkestra.Projector.ProjectorDslEsTest.OrderShipped, fn event, _position ->
        {:ok, %{"order_id" => event.data.order_id, "status" => "shipped"}, event.data.order_id}
      end)
    end

    # -------------------------------------------------------------------------
    # Tests
    # -------------------------------------------------------------------------

    describe "__dispatch_es__/3" do
      test "routes OrderPlaced to its handler and returns {:ok, doc, id}" do
        event = %OrderPlaced{
          id: "order-1",
          type: inspect(Orkestra.Projector.ProjectorDslEsTest.OrderPlaced),
          data: %{order_id: "order-1"},
          global_position: 0
        }

        result = TestESProjector.__dispatch_es__(event.type, event, 0)

        assert {:ok, doc, id} = result
        assert is_map(doc)
        assert is_binary(id)
        assert doc["order_id"] == "order-1"
        assert doc["status"] == "placed"
        assert id == "order-1"
      end

      test "routes OrderShipped to its handler" do
        event = %OrderShipped{
          id: "order-2",
          type: inspect(Orkestra.Projector.ProjectorDslEsTest.OrderShipped),
          data: %{order_id: "order-2"},
          global_position: 1
        }

        result = TestESProjector.__dispatch_es__(event.type, event, 1)

        assert {:ok, doc, id} = result
        assert doc["status"] == "shipped"
        assert id == "order-2"
      end

      test "returns :skip for unregistered event types" do
        event = %OrderPlaced{type: "Unknown.Event", global_position: 0}
        assert :skip == TestESProjector.__dispatch_es__("Unknown.Event", event, 0)
      end
    end

    describe "__handle_es__/3" do
      test "passes through {:ok, doc, id} from dispatch for known events" do
        event = %OrderPlaced{
          id: "order-3",
          type: inspect(Orkestra.Projector.ProjectorDslEsTest.OrderPlaced),
          data: %{order_id: "order-3"},
          global_position: 2
        }

        result = TestESProjector.__handle_es__("test_es_projector", event, 2)

        assert {:ok, doc, id} = result
        assert doc["status"] == "placed"
        assert id == "order-3"
      end

      test "passes through :skip for unknown events (NOT wrapped in {:ok, ...})" do
        # ES path: :skip is passed through as-is (unlike Postgres path which
        # translates :skip to {:ok, Ecto.Multi.new()})
        event = %{type: "Unknown.Event", global_position: 0}
        result = TestESProjector.__handle_es__("test_es_projector", event, 0)
        assert :skip == result
      end
    end

    describe "child_spec/1 with backend: :elasticsearch" do
      test "storage_adapter is Orkestra.Projection.Storage.Elasticsearch" do
        spec = TestESProjector.child_spec([])

        assert %{start: {Orkestra.Projector.GenServer, :start_link, [config]}} = spec
        assert config.storage_adapter == Orkestra.Projection.Storage.Elasticsearch
      end

      test "adapter_opts includes :cluster matching Orkestra.Test.ESCluster" do
        spec = TestESProjector.child_spec([])
        assert %{start: {_, _, [config]}} = spec
        cluster = Keyword.get(config.adapter_opts, :cluster)
        assert cluster == Orkestra.Test.ESCluster
      end

      test "adapter_opts includes :index matching 'test_orders'" do
        spec = TestESProjector.child_spec([])
        assert %{start: {_, _, [config]}} = spec
        index = Keyword.get(config.adapter_opts, :index)
        assert index == "test_orders"
      end

      test "adapter_opts includes :handler that is a 3-arity function" do
        spec = TestESProjector.child_spec([])
        assert %{start: {_, _, [config]}} = spec
        handler = Keyword.get(config.adapter_opts, :handler)
        assert is_function(handler, 3)
      end

      test "adapter_opts includes :projector_module matching TestESProjector" do
        spec = TestESProjector.child_spec([])
        assert %{start: {_, _, [config]}} = spec
        projector_module = Keyword.get(config.adapter_opts, :projector_module)
        assert projector_module == Orkestra.Projector.ProjectorDslEsTest.TestESProjector
      end

      test "repo in config matches SomeCheckpointRepo (checkpoint stays on Postgres)" do
        spec = TestESProjector.child_spec([])
        assert %{start: {_, _, [config]}} = spec
        assert config.repo == SomeCheckpointRepo
      end

      test "spec id is the projector module" do
        spec = TestESProjector.child_spec([])
        assert spec.id == Orkestra.Projector.ProjectorDslEsTest.TestESProjector
      end

      test "runtime opts override compile-time defaults (e.g. repo override)" do
        spec = TestESProjector.child_spec(repo: OverrideCheckpointRepo)
        assert %{start: {_, _, [config]}} = spec
        assert config.repo == OverrideCheckpointRepo
        # storage_adapter is still ES (not overridden)
        assert config.storage_adapter == Orkestra.Projection.Storage.Elasticsearch
      end
    end

    describe "__projection_config__/0 ES fields (RBLD-03 support)" do
      test "ES projector returns backend: :elasticsearch in __projection_config__" do
        config = TestESProjector.__projection_config__()
        assert config.backend == :elasticsearch
      end

      test "ES projector returns correct cluster in __projection_config__" do
        config = TestESProjector.__projection_config__()
        assert config.cluster == Orkestra.Test.ESCluster
      end

      test "ES projector returns correct index in __projection_config__" do
        config = TestESProjector.__projection_config__()
        assert config.index == "test_orders"
      end

      test "ES projector returns projector_module: self in __projection_config__" do
        config = TestESProjector.__projection_config__()
        assert config.projector_module == Orkestra.Projector.ProjectorDslEsTest.TestESProjector
      end

      test "ES projector still exposes legacy fields (repo, projector_name, migrations_path, migration_source)" do
        config = TestESProjector.__projection_config__()
        assert config.repo == SomeCheckpointRepo
        assert is_binary(config.projector_name)
        assert is_binary(config.migrations_path)
        assert is_binary(config.migration_source)
      end

      test "Postgres projector returns backend: :postgres in __projection_config__" do
        config = TestPostgresProjectorInES.__projection_config__()
        assert config.backend == :postgres
      end

      test "Postgres projector returns cluster: nil in __projection_config__" do
        config = TestPostgresProjectorInES.__projection_config__()
        assert config.cluster == nil
      end

      test "Postgres projector returns index: nil in __projection_config__" do
        config = TestPostgresProjectorInES.__projection_config__()
        assert config.index == nil
      end

      test "Postgres projector returns projector_module: self in __projection_config__" do
        config = TestPostgresProjectorInES.__projection_config__()
        assert config.projector_module == Orkestra.Projector.ProjectorDslEsTest.TestPostgresProjectorInES
      end
    end

    describe "backward compatibility" do
      test "Postgres projector defined alongside ES projector still uses Storage.Postgres" do
        # TestPostgresProjectorInES is a Postgres projector defined in this same
        # test file. Verifies that adding ES backend support to the macro does not
        # break Postgres projector child_spec output (ADPT-05 regression).
        spec = Orkestra.Projector.ProjectorDslEsTest.TestPostgresProjectorInES.child_spec([])
        assert %{start: {_, _, [config]}} = spec
        assert config.storage_adapter == Orkestra.Projection.Storage.Postgres
      end

      test "ES projector exports all generated functions without conflict" do
        # Verify that both Postgres-path and ES-path dispatch functions are generated
        # even though the ES projector defines no Postgres handlers
        assert function_exported?(
                 Orkestra.Projector.ProjectorDslEsTest.TestESProjector,
                 :__dispatch_es__,
                 3
               )

        assert function_exported?(
                 Orkestra.Projector.ProjectorDslEsTest.TestESProjector,
                 :__dispatch__,
                 3
               )

        assert function_exported?(
                 Orkestra.Projector.ProjectorDslEsTest.TestESProjector,
                 :__handle_es__,
                 3
               )

        assert function_exported?(
                 Orkestra.Projector.ProjectorDslEsTest.TestESProjector,
                 :__handle__,
                 3
               )
      end

      test "Postgres projector __handle__/3 still translates :skip to {:ok, empty Multi}" do
        # Verifies the Postgres __handle__/3 behaviour is intact after ES macro changes
        event = %{type: "Unknown.Event", global_position: 0}

        result =
          Orkestra.Projector.ProjectorDslEsTest.TestPostgresProjectorInES.__handle__(
            "test",
            event,
            0
          )

        assert {:ok, %Ecto.Multi{}} = result
      end
    end
  end
end
