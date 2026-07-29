if Code.ensure_loaded?(Ecto.Multi) do
  defmodule Orkestra.Projection.Storage.PostgresTest do
    @moduledoc false

    use ExUnit.Case, async: false

    @moduletag :postgres

    import Ecto.Query, only: [from: 2]

    alias Orkestra.Projection.Storage.Postgres
    alias Orkestra.Projection.Storage
    alias Orkestra.Test.ProjectionRepo
    alias Orkestra.Test.ProjectionReadModel
    alias Orkestra.Test.ProjectionMigrations

    # Run the read-model migration once for the whole test module (DDL outside the
    # per-test sandbox transaction). SQL.Sandbox's :manual mode rolls back DML per
    # test but does not roll back DDL — so the table is created once and rows are
    # cleaned up automatically by the sandbox on each checkout/checkin cycle.
    setup_all do
      # Migrations run via unboxed_run so Ecto.Migrator uses a real (non-sandbox)
      # connection.  migration_lock: false prevents the migrator from spawning a
      # Task for advisory locking, which can't inherit the checked-out connection.
      # Uses a separate migration_source table to avoid version conflicts with
      # Orkestra.Projection.Migration (both use version 1).
      Ecto.Adapters.SQL.Sandbox.unboxed_run(ProjectionRepo, fn ->
        base_config = Application.get_env(:orkestra, ProjectionRepo, [])

        patched_config =
          Keyword.put(base_config, :migration_source, "test_read_model_schema_migrations")

        Application.put_env(:orkestra, ProjectionRepo, patched_config)

        Ecto.Migrator.run(
          ProjectionRepo,
          [{ProjectionMigrations.version(), ProjectionMigrations}],
          :up,
          all: true,
          migration_lock: false
        )

        Application.put_env(:orkestra, ProjectionRepo, base_config)
      end)

      :ok
    end

    setup do
      :ok = Ecto.Adapters.SQL.Sandbox.checkout(ProjectionRepo)
      :ok
    end

    # 1. Behaviour contract: Postgres adapter implements Orkestra.Projection.Storage
    describe "behaviour contract" do
      test "Orkestra.Projection.Storage.Postgres satisfies the Storage behaviour" do
        behaviours =
          Postgres.__info__(:attributes) |> Keyword.get_values(:behaviour) |> List.flatten()

        assert Storage in behaviours
      end
    end

    # 2. write/4 returns {:ok, %Ecto.Multi{}} for a valid :handler
    describe "write/4" do
      test "returns {:ok, %Ecto.Multi{}} when :handler returns a read-model insert Multi" do
        handler = fn projector_name, _event, position ->
          multi =
            Ecto.Multi.new()
            |> Ecto.Multi.insert(
              :read_model_insert,
              ProjectionReadModel.changeset(%ProjectionReadModel{}, %{
                projector_name: projector_name,
                position: position,
                payload: %{type: "SomeEvent"}
              })
            )

          {:ok, multi}
        end

        result = Postgres.write("test_projector", %{type: "SomeEvent"}, 1, handler: handler)
        assert {:ok, multi} = result
        assert is_struct(multi, Ecto.Multi)
      end

      # 3. write/4 propagates {:error, _} when handler returns an error
      test "propagates {:error, reason} when :handler returns an error" do
        handler = fn _projector_name, _event, _position ->
          {:error, :unrecognised_event}
        end

        assert {:error, :unrecognised_event} =
                 Postgres.write("test_projector", %{type: "Unknown"}, 0, handler: handler)
      end

      # 4. Composition: Multi.append with :checkpoint step does NOT raise
      test "returned Multi can be appended to a checkpoint Multi without name clash" do
        handler = fn projector_name, _event, position ->
          multi =
            Ecto.Multi.new()
            |> Ecto.Multi.insert(
              :read_model_insert,
              ProjectionReadModel.changeset(%ProjectionReadModel{}, %{
                projector_name: projector_name,
                position: position,
                payload: %{}
              })
            )

          {:ok, multi}
        end

        {:ok, write_multi} =
          Postgres.write("test_projector", %{type: "SomeEvent"}, 2, handler: handler)

        # GenServer's checkpoint step name — must NOT clash with :read_model_insert
        checkpoint_multi =
          Ecto.Multi.new()
          |> Ecto.Multi.run(:checkpoint, fn _repo, _changes -> {:ok, :advanced} end)

        # Must NOT raise ArgumentError: cannot merge multis with overlapping names
        composed = Ecto.Multi.append(write_multi, checkpoint_multi)
        assert %Ecto.Multi{} = composed
      end

      # 5. Real-DB persistence: commit the appended Multi and assert row is queryable
      test "committed appended Multi persists the read-model row (STORE-02)" do
        projector_name = "test_projector_persistence_#{:erlang.unique_integer([:positive])}"
        position = 10

        handler = fn pname, _event, pos ->
          multi =
            Ecto.Multi.new()
            |> Ecto.Multi.insert(
              :read_model_insert,
              ProjectionReadModel.changeset(%ProjectionReadModel{}, %{
                projector_name: pname,
                position: pos,
                payload: %{type: "OrderPlaced", order_id: "order-123"}
              })
            )

          {:ok, multi}
        end

        {:ok, write_multi} =
          Postgres.write(projector_name, %{type: "OrderPlaced"}, position, handler: handler)

        # Append checkpoint step (no real table needed — it's a Multi.run)
        checkpoint_multi =
          Ecto.Multi.new()
          |> Ecto.Multi.run(:checkpoint, fn _repo, _changes -> {:ok, :checkpoint_advanced} end)

        composed = Ecto.Multi.append(write_multi, checkpoint_multi)

        # Commit the combined Multi on the isolated test Repo
        assert {:ok, results} = ProjectionRepo.transaction(composed)
        assert Map.has_key?(results, :read_model_insert)
        assert Map.has_key?(results, :checkpoint)

        # Row must be queryable via Ecto
        assert row = ProjectionRepo.get_by(ProjectionReadModel, projector_name: projector_name)
        assert row.position == position
        assert row.payload["type"] == "OrderPlaced"
        assert row.payload["order_id"] == "order-123"
      end
    end

    # 6. reset/2 clears read-model rows for the projector (STORE-04)
    describe "reset/2" do
      test "deletes all rows for the projector and returns :ok" do
        projector_name = "test_projector_reset_#{:erlang.unique_integer([:positive])}"

        # Insert a few read-model rows directly
        Enum.each(1..3, fn pos ->
          changeset =
            ProjectionReadModel.changeset(%ProjectionReadModel{}, %{
              projector_name: projector_name,
              position: pos,
              payload: %{}
            })

          ProjectionRepo.insert!(changeset)
        end)

        # Verify rows exist before reset
        rows =
          ProjectionRepo.all(
            from(r in ProjectionReadModel, where: r.projector_name == ^projector_name)
          )

        assert length(rows) == 3

        # reset/2 must delete them and return :ok
        assert :ok =
                 Postgres.reset(projector_name, repo: ProjectionRepo, schema: ProjectionReadModel)

        # Verify rows are gone
        remaining =
          ProjectionRepo.all(
            from(r in ProjectionReadModel, where: r.projector_name == ^projector_name)
          )

        assert remaining == []
      end

      test "reset/2 on a projector with no rows returns :ok" do
        assert :ok =
                 Postgres.reset("nonexistent_projector_#{:erlang.unique_integer([:positive])}",
                   repo: ProjectionRepo,
                   schema: ProjectionReadModel
                 )
      end
    end
  end
end
