if Code.ensure_loaded?(Ecto.Multi) do
  defmodule Orkestra.Projector.ProjectorDslTest do
    @moduledoc false

    use ExUnit.Case, async: true

    # -------------------------------------------------------------------------
    # Inline event stubs — minimal structs to carry a :type field
    # -------------------------------------------------------------------------

    defmodule OrderPlaced do
      @moduledoc false
      defstruct [:id, :type, :data, :global_position]
    end

    defmodule OrderCancelled do
      @moduledoc false
      defstruct [:id, :type, :data, :global_position]
    end

    # -------------------------------------------------------------------------
    # Inline projector with auto-derived name
    # -------------------------------------------------------------------------

    defmodule TestProjector do
      @moduledoc false

      use Orkestra.Projector,
        repo: SomeRepo,
        event_store: SomeEventStore

      project(Orkestra.Projector.ProjectorDslTest.OrderPlaced, fn _event, multi ->
        multi
      end)

      project(Orkestra.Projector.ProjectorDslTest.OrderCancelled, fn _event, multi ->
        multi
      end)
    end

    # -------------------------------------------------------------------------
    # Inline projector with custom name override
    # -------------------------------------------------------------------------

    defmodule CustomNameProjector do
      @moduledoc false

      use Orkestra.Projector,
        repo: SomeRepo,
        event_store: SomeEventStore,
        name: "custom_orders"

      project(Orkestra.Projector.ProjectorDslTest.OrderPlaced, fn _event, multi ->
        multi
      end)
    end

    # -------------------------------------------------------------------------
    # Tests
    # -------------------------------------------------------------------------

    describe "__projection_config__/0" do
      test "returns map with repo, projector_name, migrations_path, migration_source" do
        config = TestProjector.__projection_config__()

        assert is_map(config)
        assert Map.has_key?(config, :repo)
        assert Map.has_key?(config, :projector_name)
        assert Map.has_key?(config, :migrations_path)
        assert Map.has_key?(config, :migration_source)
      end

      test "projector_name is auto-derived from inspect(__MODULE__)" do
        config = TestProjector.__projection_config__()
        expected = inspect(Orkestra.Projector.ProjectorDslTest.TestProjector)
        assert config.projector_name == expected
      end

      test "custom name override works" do
        config = CustomNameProjector.__projection_config__()
        assert config.projector_name == "custom_orders"
      end

      test "migrations_path derives from projector_name slug" do
        config = TestProjector.__projection_config__()

        # "Orkestra.Projector.ProjectorDslTest.TestProjector"
        # -> "orkestra_projector_projectordsltest_testprojector"
        assert String.contains?(config.migrations_path, "priv/projections/")
        assert String.contains?(config.migrations_path, "migrations")
        # Confirm no dots in path (slug derived correctly)
        refute String.contains?(config.migrations_path, ".")
      end

      test "migration_source starts with projection_ prefix" do
        config = TestProjector.__projection_config__()
        assert String.starts_with?(config.migration_source, "projection_")
        assert String.ends_with?(config.migration_source, "_schema_migrations")
      end

      test "custom name override shapes slug-based paths" do
        config = CustomNameProjector.__projection_config__()
        assert config.migrations_path == "priv/projections/custom_orders/migrations"
        assert config.migration_source == "projection_custom_orders_schema_migrations"
      end
    end

    describe "__dispatch__/3" do
      test "routes registered event types to handler fns" do
        event = %OrderPlaced{
          id: "1",
          type: inspect(Orkestra.Projector.ProjectorDslTest.OrderPlaced),
          data: %{},
          global_position: 0
        }

        result = TestProjector.__dispatch__(event.type, event, 0)
        assert {:ok, %Ecto.Multi{}} = result
      end

      test "returns :skip for unregistered event types" do
        event = %OrderPlaced{type: "Unknown.Event", global_position: 0}
        assert :skip == TestProjector.__dispatch__("Unknown.Event", event, 0)
      end

      test "routes OrderCancelled to its handler" do
        event = %OrderCancelled{
          id: "2",
          type: inspect(Orkestra.Projector.ProjectorDslTest.OrderCancelled),
          data: %{},
          global_position: 1
        }

        result = TestProjector.__dispatch__(event.type, event, 1)
        assert {:ok, %Ecto.Multi{}} = result
      end
    end

    describe "__handle__/3" do
      test "wraps __dispatch__ and translates :skip to {:ok, empty Multi}" do
        event = %{type: "Unknown.Event", global_position: 0}
        result = TestProjector.__handle__("test_projector", event, 0)
        assert {:ok, %Ecto.Multi{}} = result
      end

      test "passes through {:ok, multi} from dispatch" do
        event = %OrderPlaced{
          id: "1",
          type: inspect(Orkestra.Projector.ProjectorDslTest.OrderPlaced),
          data: %{},
          global_position: 0
        }

        result = TestProjector.__handle__("test_projector", event, 0)
        assert {:ok, %Ecto.Multi{}} = result
      end
    end

    describe "child_spec/1" do
      test "returns spec targeting Projector.GenServer.start_link/1" do
        spec = TestProjector.child_spec([])

        assert %{id: TestProjector, start: {Orkestra.Projector.GenServer, :start_link, [config]}} =
                 spec

        assert config.repo == SomeRepo
        assert config.projector_name == inspect(Orkestra.Projector.ProjectorDslTest.TestProjector)
        assert config.storage_adapter == Orkestra.Projection.Storage.Postgres
        assert config.event_store == SomeEventStore
        assert is_map(config.lifecycle_config)
      end

      test "opts override defaults" do
        spec = TestProjector.child_spec(repo: OverrideRepo)

        assert %{start: {Orkestra.Projector.GenServer, :start_link, [config]}} = spec
        assert config.repo == OverrideRepo
      end

      test "config includes handler pointing to __handle__/3" do
        spec = TestProjector.child_spec([])

        assert %{start: {_, _, [config]}} = spec
        handler = Keyword.get(config.adapter_opts, :handler)
        assert is_function(handler, 3)
      end

      test "lifecycle_config defaults are present" do
        spec = TestProjector.child_spec([])
        assert %{start: {_, _, [config]}} = spec
        assert config.lifecycle_config.max_retries == 5
        assert config.lifecycle_config.backoff_base_ms == 500
        assert config.lifecycle_config.backoff_cap_ms == 30_000
      end
    end
  end
end
