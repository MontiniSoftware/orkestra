if Code.ensure_loaded?(Ecto.Multi) do
  defmodule Orkestra.Projector.TelemetryTest do
    @moduledoc false

    use ExUnit.Case, async: false

    @moduletag :postgres

    alias Orkestra.EventStore.InMemory
    alias Orkestra.Projection.Checkpoint
    alias Orkestra.Projection.Storage.Postgres, as: PostgresAdapter
    alias Orkestra.Projector.GenServer, as: ProjectorGenServer
    alias Orkestra.Test.ProjectionMigrations
    alias Orkestra.Test.ProjectionReadModel
    alias Orkestra.Test.ProjectionRepo

    # ---------------------------------------------------------------------------
    # Setup: DDL migration once (outside per-test sandbox transaction) + per-test
    # checkout + fresh InMemory EventStore per test + telemetry handlers.
    # ---------------------------------------------------------------------------

    setup_all do
      # Migrations run via unboxed_run so Ecto.Migrator uses a real (non-sandbox)
      # connection.  migration_lock: false prevents the migrator from spawning a
      # Task for advisory locking, which can't inherit the checked-out connection.
      # DDL is not rolled back per-test by the sandbox, so this is idempotent.
      Ecto.Adapters.SQL.Sandbox.unboxed_run(ProjectionRepo, fn ->
        # Run the Orkestra checkpoint / dead_letter migrations (idempotent with `all: true`).
        # Uses the repo's default migration_source ("orkestra_test_projection_schema_migrations").
        Ecto.Migrator.run(
          ProjectionRepo,
          [{1, Orkestra.Projection.Migration}],
          :up,
          all: true,
          migration_lock: false
        )

        # Run the test read-model migration with a separate migration_source table so
        # its version 1 does not collide with Orkestra.Projection.Migration version 1.
        # The Ecto.Migrator always reads migration_source from repo.config(), so we
        # temporarily patch Application env to override it.
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

        # Restore original config
        Application.put_env(:orkestra, ProjectionRepo, base_config)
      end)

      :ok
    end

    setup do
      :ok = Ecto.Adapters.SQL.Sandbox.checkout(ProjectionRepo)
      # Shared mode lets all processes started in this test (including the
      # ProjectorGenServer spawned by start_supervised!) access the sandbox
      # connection without an explicit allow/2 call — eliminating the race
      # between GenServer's deferred :load_checkpoint and Sandbox.allow.
      Ecto.Adapters.SQL.Sandbox.mode(ProjectionRepo, {:shared, self()})

      # Start a fresh InMemory adapter for each test (supervisor cleans it up after).
      {:ok, _} = start_supervised(InMemory)

      test_pid = self()

      events = [
        {:lag, [:orkestra, :projector, :lag]},
        {:halted, [:orkestra, :projector, :halted]},
        {:retry, [:orkestra, :projector, :retry]},
        {:rebuild, [:orkestra, :projector, :rebuild_progress]}
      ]

      # Use inspect(self()) in handler IDs to avoid cross-test collisions when
      # tests run concurrently (they do not here since async: false, but this is
      # defensive and documents intent).
      for {tag, event_name} <- events do
        handler_id = "test-#{tag}-#{inspect(self())}"

        :telemetry.attach(
          handler_id,
          event_name,
          fn _event, measurements, metadata, _config ->
            send(test_pid, {:telemetry, tag, measurements, metadata})
          end,
          nil
        )
      end

      on_exit(fn ->
        for {tag, _} <- events do
          :telemetry.detach("test-#{tag}-#{inspect(self())}")
        end
      end)

      :ok
    end

    # ---------------------------------------------------------------------------
    # Helpers
    # ---------------------------------------------------------------------------

    defp unique_projector_name, do: "test_projector_#{:erlang.unique_integer([:positive])}"

    defp read_model_handler do
      fn projector_name, _event, position ->
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
    end

    defp test_config(projector_name, handler \\ nil, lifecycle_config \\ nil) do
      %{
        repo: ProjectionRepo,
        projector_name: projector_name,
        storage_adapter: PostgresAdapter,
        event_store: InMemory,
        lifecycle_config:
          lifecycle_config ||
            %{
              max_retries: 2,
              backoff_base_ms: 5,
              backoff_cap_ms: 50
            },
        adapter_opts: [handler: handler || read_model_handler()]
      }
    end

    defp append_event(type, stream_revision) do
      InMemory.append_events(
        "test-stream",
        [
          %{
            id: "evt-#{stream_revision}",
            type: type,
            data: %{},
            metadata: %{},
            stream_revision: stream_revision
          }
        ],
        :any
      )
    end

    defp wait_until(max_ms \\ 3000, fun) do
      deadline = System.monotonic_time(:millisecond) + max_ms
      poll(deadline, fun)
    end

    defp poll(deadline, fun) do
      if fun.() do
        :ok
      else
        now = System.monotonic_time(:millisecond)

        if now >= deadline do
          {:error, :timeout}
        else
          Process.sleep(10)
          poll(deadline, fun)
        end
      end
    end

    defp get_checkpoint(projector_name) do
      ProjectionRepo.get_by(Checkpoint, projector_name: projector_name)
    end

    # ---------------------------------------------------------------------------
    # Test 1 (TEL-02): Emits lag telemetry after successful commit
    # ---------------------------------------------------------------------------

    test "TEL-02 -- emits [:orkestra, :projector, :lag] after successful event commit" do
      projector_name = unique_projector_name()
      pid = start_supervised!({ProjectorGenServer, test_config(projector_name)})
      Ecto.Adapters.SQL.Sandbox.allow(ProjectionRepo, self(), pid)

      append_event("LagEvent", 0)

      assert_receive {:telemetry, :lag, %{lag: lag}, %{projector_name: ^projector_name}}, 3000
      assert is_integer(lag)
      assert lag >= 0
    end

    # ---------------------------------------------------------------------------
    # Test 2 (TEL-02): Lag is zero when fully caught up (single event)
    # ---------------------------------------------------------------------------

    test "TEL-02 -- lag is zero when projector processes the only pending event" do
      projector_name = unique_projector_name()

      # Append one event BEFORE starting the projector -- when it processes this
      # single event, last_seen_position == position so lag == 0
      append_event("LagZeroEvent", 0)

      pid = start_supervised!({ProjectorGenServer, test_config(projector_name)})
      Ecto.Adapters.SQL.Sandbox.allow(ProjectionRepo, self(), pid)

      assert_receive {:telemetry, :lag, %{lag: 0}, %{projector_name: ^projector_name}}, 3000
    end

    # ---------------------------------------------------------------------------
    # Test 3 (TEL-04): Emits halted telemetry after retry exhaustion
    # ---------------------------------------------------------------------------

    test "TEL-04 -- emits [:orkestra, :projector, :halted] after retry exhaustion" do
      projector_name = unique_projector_name()

      always_fails = fn _pname, _event, _position ->
        {:error, :always_fails}
      end

      # max_retries: 0 => park immediately on first failure
      config =
        test_config(projector_name, always_fails, %{
          max_retries: 0,
          backoff_base_ms: 5,
          backoff_cap_ms: 50
        })

      pid = start_supervised!({ProjectorGenServer, config})
      Ecto.Adapters.SQL.Sandbox.allow(ProjectionRepo, self(), pid)

      append_event("HaltEvent", 0)

      assert_receive {:telemetry, :halted, %{attempts: attempts}, meta}, 5000
      assert attempts > 0
      assert meta.projector_name == projector_name
      assert meta.position == 0
      assert is_binary(meta.reason)

      # Verify halt is persisted (TEL-04 persistence requirement)
      assert :ok =
               wait_until(fn ->
                 cp = get_checkpoint(projector_name)
                 cp != nil && cp.halted == true
               end)
    end

    # ---------------------------------------------------------------------------
    # Test 4 (TEL-04): Emits retry telemetry on scheduled retry
    # ---------------------------------------------------------------------------

    test "TEL-04 -- emits [:orkestra, :projector, :retry] when scheduling a retry" do
      projector_name = unique_projector_name()

      # Handler that fails for position 0 (will trigger retry)
      retry_handler = fn pname, event, position ->
        if event.global_position == 0 do
          {:error, :retry_me}
        else
          multi =
            Ecto.Multi.new()
            |> Ecto.Multi.insert(
              :read_model_insert,
              ProjectionReadModel.changeset(%ProjectionReadModel{}, %{
                projector_name: pname,
                position: position,
                payload: %{}
              })
            )

          {:ok, multi}
        end
      end

      # max_retries: 2 => first failure triggers retry, not immediate park
      config =
        test_config(projector_name, retry_handler, %{
          max_retries: 2,
          backoff_base_ms: 5,
          backoff_cap_ms: 50
        })

      pid = start_supervised!({ProjectorGenServer, config})
      Ecto.Adapters.SQL.Sandbox.allow(ProjectionRepo, self(), pid)

      append_event("RetryEvent", 0)

      assert_receive {:telemetry, :retry, %{attempts: attempts, delay_ms: delay}, meta}, 3000
      assert attempts == 1
      assert delay > 0
      assert meta.projector_name == projector_name
      assert meta.position == 0
    end

    # ---------------------------------------------------------------------------
    # Test 5 (TEL-03): Emits rebuild_progress telemetry when rebuild_total is set
    # ---------------------------------------------------------------------------

    test "TEL-03 -- emits [:orkestra, :projector, :rebuild_progress] when rebuild_total is set" do
      projector_name = unique_projector_name()

      # Pass rebuild_total in config to simulate rebuild mode
      config =
        test_config(projector_name)
        |> Map.put(:rebuild_total, 3)

      pid = start_supervised!({ProjectorGenServer, config})
      Ecto.Adapters.SQL.Sandbox.allow(ProjectionRepo, self(), pid)

      Enum.each(0..2, &append_event("RebuildEvent", &1))

      # Should receive 3 rebuild_progress events, one per event
      for expected_replayed <- 1..3 do
        assert_receive {:telemetry, :rebuild, measurements, meta}, 3000
        assert measurements.events_replayed == expected_replayed
        assert measurements.total_events == 3
        assert meta.projector_name == projector_name
        assert is_float(meta.percent)
      end
    end

    # ---------------------------------------------------------------------------
    # Test 6 (TEL-03): Does NOT emit rebuild_progress in normal (live) mode
    # ---------------------------------------------------------------------------

    test "TEL-03 -- does not emit rebuild_progress in normal (non-rebuild) mode" do
      projector_name = unique_projector_name()

      # No rebuild_total in config -- normal live mode
      pid = start_supervised!({ProjectorGenServer, test_config(projector_name)})
      Ecto.Adapters.SQL.Sandbox.allow(ProjectionRepo, self(), pid)

      append_event("LiveEvent", 0)

      # Should receive lag but NOT rebuild_progress
      assert_receive {:telemetry, :lag, _, _}, 3000
      refute_receive {:telemetry, :rebuild, _, _}, 500
    end
  end
end
