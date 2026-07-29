if Code.ensure_loaded?(Ecto.Multi) do
  # Test projector module that implements __projection_config__/0 without using
  # the DSL macro — tests the mix tasks' contract directly, not the macro itself.
  defmodule Mix.Tasks.Orkestra.Projection.TasksTest.TestProjector do
    @moduledoc false

    @spec __projection_config__() :: map()
    def __projection_config__ do
      %{
        repo: Orkestra.Test.ProjectionRepo,
        projector_name: "TasksTest.TestProjector",
        migrations_path: "test/support/task_test_migrations",
        migration_source: "test_task_projection_migrations"
      }
    end

    @spec child_spec(keyword()) :: Supervisor.child_spec()
    def child_spec(_opts \\ []) do
      # Minimal child spec using an Agent — no DB dependency, just OTP lifecycle.
      %{
        id: __MODULE__,
        start: {Agent, :start_link, [fn -> :running end, [name: __MODULE__]]}
      }
    end
  end

  defmodule Mix.Tasks.Orkestra.Projection.TasksTest do
    @moduledoc false

    use ExUnit.Case, async: false

    @moduletag :postgres

    import Ecto.Query, only: [from: 2]

    alias Orkestra.Projection.Checkpoint
    alias Orkestra.Test.ProjectionRepo

    @test_projector_str "Mix.Tasks.Orkestra.Projection.TasksTest.TestProjector"
    @test_projector_name "TasksTest.TestProjector"

    # Set up the shared projection_checkpoints / projection_dead_letters tables
    # once for the whole test module. DDL is not rolled back per-test by the
    # sandbox — only DML rows are cleaned up on checkout/checkin.
    #
    # Migrations run via unboxed_run so Ecto.Migrator's internal task gets a
    # real (non-sandbox) connection.  DDL is not rolled back per-test by the
    # sandbox, so running once here is idempotent and safe.
    setup_all do
      Ecto.Adapters.SQL.Sandbox.unboxed_run(ProjectionRepo, fn ->
        Ecto.Migrator.run(
          ProjectionRepo,
          [{1, Orkestra.Projection.Migration}],
          :up,
          all: true
        )
      end)

      :ok
    end

    setup do
      :ok = Ecto.Adapters.SQL.Sandbox.checkout(ProjectionRepo)

      # Shared mode so the process that `Ecto.Migrator.run` spawns to execute the
      # migration (a Task) can reuse the test's single sandbox connection without
      # an explicit allow/3. Combined with `migration_lock: false` in the repo's
      # test config (see test_helper.exs), the migrator no longer needs a second
      # connection for a table lock, so it runs cleanly inside the sandbox.
      Ecto.Adapters.SQL.Sandbox.mode(ProjectionRepo, {:shared, self()})
      :ok
    end

    describe "Mix.Tasks.Orkestra.Projection.Migrate" do
      test "raises Mix.Error when no module name provided" do
        assert_raise Mix.Error, fn ->
          Mix.Tasks.Orkestra.Projection.Migrate.run([])
        end
      end

      test "runs pending migrations and creates the read-model table" do
        # Run migrate — creates the task_test_read_model table
        Mix.Tasks.Orkestra.Projection.Migrate.run([@test_projector_str])

        # Verify by inserting a row into the created table (would raise if table missing).
        # Repo.insert_all/3 returns {rows_inserted, returned}, not an :ok tuple.
        {1, _} =
          ProjectionRepo.insert_all(
            "task_test_read_model",
            [
              # Schemaless insert_all does not cast, and the id column is
              # :binary_id (uuid) — pass the raw 16-byte binary, not the string
              # form (Ecto.UUID.generate/0), or Postgrex rejects it.
              %{
                id: Ecto.UUID.bingenerate(),
                projector_name: @test_projector_name,
                value: "present"
              }
            ],
            on_conflict: :nothing
          )

        # Clean up: roll back the migration so the table is gone for other tests
        Mix.Tasks.Orkestra.Projection.Rollback.run([@test_projector_str, "--all"])
      end
    end

    describe "Mix.Tasks.Orkestra.Projection.Rollback" do
      test "raises Mix.Error when no module name provided" do
        assert_raise Mix.Error, fn ->
          Mix.Tasks.Orkestra.Projection.Rollback.run([])
        end
      end

      test "migrate then rollback round-trip leaves no table behind" do
        Mix.Tasks.Orkestra.Projection.Migrate.run([@test_projector_str])
        Mix.Tasks.Orkestra.Projection.Rollback.run([@test_projector_str, "--all"])

        # The table should be gone after rollback — any query against it raises
        assert_raise Postgrex.Error, fn ->
          ProjectionRepo.all(from(r in "task_test_read_model", select: r.id))
        end
      end
    end

    describe "Mix.Tasks.Orkestra.Projection.Drop" do
      test "raises Mix.Error when no module name provided" do
        assert_raise Mix.Error, fn ->
          Mix.Tasks.Orkestra.Projection.Drop.run([])
        end
      end

      test "drop rolls back migrations and deletes checkpoint row" do
        # Insert a checkpoint row to verify drop cleans it up
        ProjectionRepo.insert!(%Checkpoint{
          projector_name: @test_projector_name,
          last_position: 42,
          halted: false
        })

        # Migrate first so there is something to drop
        Mix.Tasks.Orkestra.Projection.Migrate.run([@test_projector_str])

        # Drop removes migrations AND the checkpoint row
        Mix.Tasks.Orkestra.Projection.Drop.run([@test_projector_str])

        # Checkpoint row must be gone
        assert ProjectionRepo.get_by(Checkpoint, projector_name: @test_projector_name) == nil
      end
    end

    describe "Mix.Tasks.Orkestra.Projection.Rebuild" do
      test "raises Mix.Error when no module name provided" do
        assert_raise Mix.Error, fn ->
          Mix.Tasks.Orkestra.Projection.Rebuild.run([])
        end
      end

      test "raises Mix.Error with clear message when projector not found under supervisor" do
        # Start an EMPTY projection supervisor (no children) under the default
        # name the task looks up. The test projector is therefore not a child of
        # it, so `Supervisor.terminate_child/2` returns {:error, :not_found} and
        # the task raises the expected Mix.Error. (With no supervisor running at
        # all, terminate_child would instead exit with :noproc — a different
        # failure than the "not found under" contract this test verifies.)
        start_supervised!(
          {Orkestra.Projection.Supervisor, projectors: [], name: Orkestra.Projection.Supervisor}
        )

        # Rebuild with --yes skips the confirmation prompt.
        # This should fail with a clear error because the test projector is not
        # registered under the running Orkestra.Projection.Supervisor.
        assert_raise Mix.Error, ~r/not found under/, fn ->
          Mix.Tasks.Orkestra.Projection.Rebuild.run([
            @test_projector_str,
            "--yes"
          ])
        end
      end
    end

    describe "all four tasks have @shortdoc" do
      test "migrate has shortdoc" do
        assert Mix.Task.shortdoc(Mix.Tasks.Orkestra.Projection.Migrate) =~ "migration"
      end

      test "rollback has shortdoc" do
        assert Mix.Task.shortdoc(Mix.Tasks.Orkestra.Projection.Rollback) =~ "oll"
      end

      test "drop has shortdoc" do
        assert Mix.Task.shortdoc(Mix.Tasks.Orkestra.Projection.Drop) =~ "rop"
      end

      test "rebuild has shortdoc" do
        assert Mix.Task.shortdoc(Mix.Tasks.Orkestra.Projection.Rebuild) =~ "ebuild"
      end
    end
  end
end
