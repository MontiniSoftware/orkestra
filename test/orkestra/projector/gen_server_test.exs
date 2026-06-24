if Code.ensure_loaded?(Ecto.Multi) do
  defmodule Orkestra.Projector.GenServerTest do
    @moduledoc false

    use ExUnit.Case, async: false

    @moduletag :postgres

    import Ecto.Query, only: [from: 2]

    alias Orkestra.EventStore.InMemory
    alias Orkestra.Projection.Checkpoint
    alias Orkestra.Projection.DeadLetter
    alias Orkestra.Projection.Storage.Postgres, as: PostgresAdapter
    alias Orkestra.Projector.GenServer, as: ProjectorGenServer
    alias Orkestra.Test.ProjectionMigrations
    alias Orkestra.Test.ProjectionReadModel
    alias Orkestra.Test.ProjectionRepo

    # ---------------------------------------------------------------------------
    # Setup: DDL migration once (outside per-test sandbox transaction) + per-test
    # checkout + fresh InMemory EventStore per test.
    # ---------------------------------------------------------------------------

    setup_all do
      # Run the Orkestra checkpoint / dead_letter migrations (idempotent with `all: true`)
      Ecto.Migrator.run(
        ProjectionRepo,
        [{1, Orkestra.Projection.Migration}],
        :up,
        all: true
      )

      # Run the test read-model table migration
      Ecto.Migrator.run(
        ProjectionRepo,
        [{ProjectionMigrations.version(), ProjectionMigrations}],
        :up,
        all: true
      )

      :ok
    end

    setup do
      :ok = Ecto.Adapters.SQL.Sandbox.checkout(ProjectionRepo)

      # Start a fresh InMemory adapter for each test (supervisor cleans it up after).
      # The InMemory API is bound to __MODULE__ so a single named instance per test suffices.
      {:ok, _} = start_supervised(InMemory)

      :ok
    end

    # ---------------------------------------------------------------------------
    # Helpers
    # ---------------------------------------------------------------------------

    # Returns a unique projector name per test invocation
    defp unique_projector_name, do: "test_projector_#{:erlang.unique_integer([:positive])}"

    # Builds a standard handler that inserts a ProjectionReadModel row
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

    # Minimal GenServer config for a test
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

    # Appends a single event to the InMemory store
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

    # Polls until `fun.()` returns truthy, or times out (max_ms default 3000)
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

    # Returns the count of read-model rows for a projector
    defp row_count(projector_name) do
      ProjectionRepo.aggregate(
        from(r in ProjectionReadModel, where: r.projector_name == ^projector_name),
        :count
      )
    end

    # Returns the checkpoint for a projector (or nil if none)
    defp get_checkpoint(projector_name) do
      ProjectionRepo.get_by(Checkpoint, projector_name: projector_name)
    end

    # ---------------------------------------------------------------------------
    # Test 1 (PROJ-04): Sequential in-order delivery, no duplicates
    # ---------------------------------------------------------------------------

    test "PROJ-04 — events apply strictly in-order; unique_index guards against double-apply" do
      projector_name = unique_projector_name()

      # start_supervised! first, THEN Sandbox.allow (correct ownership ordering — Pitfall 6)
      pid = start_supervised!({ProjectorGenServer, test_config(projector_name)})
      Ecto.Adapters.SQL.Sandbox.allow(ProjectionRepo, self(), pid)

      event_count = 5
      Enum.each(0..(event_count - 1), &append_event("SequentialEvent", &1))

      # Poll until all 5 rows appear
      assert :ok = wait_until(fn -> row_count(projector_name) == event_count end)

      rows =
        ProjectionRepo.all(
          from(r in ProjectionReadModel,
            where: r.projector_name == ^projector_name,
            order_by: r.position
          )
        )

      assert length(rows) == event_count
      # Positions must be contiguous [0, 1, 2, 3, 4] in order
      assert Enum.map(rows, & &1.position) == Enum.to_list(0..(event_count - 1))
    end

    # ---------------------------------------------------------------------------
    # Test 2 (STORE-03): Atomic co-commit — checkpoint matches read-model row
    # ---------------------------------------------------------------------------

    test "STORE-03 — after processing, checkpoint.last_position equals the read-model row position" do
      projector_name = unique_projector_name()

      pid = start_supervised!({ProjectorGenServer, test_config(projector_name)})
      Ecto.Adapters.SQL.Sandbox.allow(ProjectionRepo, self(), pid)

      # Append 3 events
      Enum.each(0..2, &append_event("AtomicEvent", &1))

      # Wait for all 3 read-model rows
      assert :ok = wait_until(fn -> row_count(projector_name) == 3 end)

      checkpoint = get_checkpoint(projector_name)
      assert checkpoint != nil
      # Both are present and consistent — proving the atomic co-write
      assert checkpoint.last_position == 2
      assert checkpoint.halted == false
      assert row_count(projector_name) == 3
    end

    # ---------------------------------------------------------------------------
    # Test 3 (PROJ-03): Resume after restart
    # ---------------------------------------------------------------------------

    test "PROJ-03 — new GenServer resumes from persisted checkpoint (no reprocessing of prior events)" do
      projector_name = unique_projector_name()

      # Phase 1: start projector, process 3 events
      pid1 = start_supervised!({ProjectorGenServer, test_config(projector_name)}, id: :gs1)
      Ecto.Adapters.SQL.Sandbox.allow(ProjectionRepo, self(), pid1)

      Enum.each(0..2, &append_event("ResumeEvent", &1))
      assert :ok = wait_until(fn -> row_count(projector_name) == 3 end)

      checkpoint_before = get_checkpoint(projector_name)
      assert checkpoint_before.last_position == 2

      # Stop the first projector
      stop_supervised(:gs1)

      # Phase 2: start a new projector with the same name — it reads the checkpoint
      pid2 = start_supervised!({ProjectorGenServer, test_config(projector_name)}, id: :gs2)
      Ecto.Adapters.SQL.Sandbox.allow(ProjectionRepo, self(), pid2)

      # Append 2 more events
      Enum.each(3..4, &append_event("ResumeEvent", &1))
      # Should reach exactly 5 total rows (not 7 if 0..2 were reprocessed)
      assert :ok = wait_until(fn -> row_count(projector_name) == 5 end)

      checkpoint_after = get_checkpoint(projector_name)
      assert checkpoint_after.last_position == 4

      # All 5 positions must be present with no duplicates
      rows =
        ProjectionRepo.all(
          from(r in ProjectionReadModel,
            where: r.projector_name == ^projector_name,
            order_by: r.position
          )
        )

      assert length(rows) == 5
      assert Enum.map(rows, & &1.position) == [0, 1, 2, 3, 4]
    end

    # ---------------------------------------------------------------------------
    # Test 4 (STORE-03): Crash-between-writes rollback — no double/missed write
    # ---------------------------------------------------------------------------

    test "STORE-03 — failed transaction rolls back both read-model and checkpoint atomically" do
      projector_name = unique_projector_name()

      # Handler that fails for position 0 (simulates a crash during write)
      crash_handler = fn pname, event, position ->
        if event.global_position == 0 do
          {:error, :simulated_crash_between_writes}
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

      # max_retries: 0 → park immediately on the first failure (attempt 1 >= 0 max → :park)
      config =
        test_config(projector_name, crash_handler, %{
          max_retries: 0,
          backoff_base_ms: 5,
          backoff_cap_ms: 50
        })

      pid = start_supervised!({ProjectorGenServer, config})
      Ecto.Adapters.SQL.Sandbox.allow(ProjectionRepo, self(), pid)

      # Append position 0 event — will fail and be parked atomically
      append_event("CrashEvent", 0)

      # Wait for the halt
      assert :ok =
               wait_until(fn ->
                 cp = get_checkpoint(projector_name)
                 cp != nil && cp.halted == true
               end)

      # Rollback proof: no read-model row for position 0 (transaction rolled back)
      assert row_count(projector_name) == 0

      # Checkpoint: halted=true; last_position is set to position - 1 (= -1 for position 0)
      # so that on a future restart the failing event at position 0 is NOT skipped
      # (exclusive > semantics: subscribe from -1 delivers position > -1, i.e. position 0+)
      checkpoint = get_checkpoint(projector_name)
      assert checkpoint.halted == true
      assert checkpoint.last_position == -1

      # Dead-letter row confirms the failure was persisted
      dead_letter = ProjectionRepo.get_by(DeadLetter, projector_name: projector_name, position: 0)
      assert dead_letter != nil
      assert dead_letter.error =~ "simulated_crash_between_writes"
    end

    # ---------------------------------------------------------------------------
    # Test 5 (ERR-04): Halt persistence + stay-alive + post-halt discard
    # ---------------------------------------------------------------------------

    test "ERR-04 — retry exhaustion persists dead_letter + halted=true; projector discards subsequent events" do
      projector_name = unique_projector_name()

      # Handler that always fails for position 0
      always_fails = fn pname, event, position ->
        if event.global_position == 0 do
          {:error, :always_fails}
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

      # max_retries: 2 → attempt 1 retries, attempt 2 retries, attempt 3 parks
      config =
        test_config(projector_name, always_fails, %{
          max_retries: 2,
          backoff_base_ms: 5,
          backoff_cap_ms: 50
        })

      pid = start_supervised!({ProjectorGenServer, config})
      Ecto.Adapters.SQL.Sandbox.allow(ProjectionRepo, self(), pid)

      # Trigger the failing event
      append_event("FailEvent", 0)

      # Wait for checkpoint to show halted = true
      assert :ok =
               wait_until(5000, fn ->
                 cp = get_checkpoint(projector_name)
                 cp != nil && cp.halted == true
               end)

      # 1. Dead-letter row must exist with attempt count
      dead_letter = ProjectionRepo.get_by(DeadLetter, projector_name: projector_name, position: 0)
      assert dead_letter != nil, "Expected a dead_letter row to be persisted"
      assert dead_letter.attempts == 2
      assert dead_letter.error =~ "always_fails"

      # 2. Checkpoint must have halted=true and halted_at timestamp set
      checkpoint = get_checkpoint(projector_name)
      assert checkpoint.halted == true
      assert checkpoint.halted_at != nil

      # 3. The GenServer process must remain alive (no crash, no stop)
      assert Process.alive?(pid), "Expected projector GenServer to stay alive after halt"

      # 4. Post-halt event must be discarded — row count must not change
      row_count_before = row_count(projector_name)
      append_event("PostHaltEvent", 1)
      # Allow delivery time
      Process.sleep(200)

      assert row_count(projector_name) == row_count_before,
             "Expected post-halt event to be discarded (row count unchanged)"
    end

    # ---------------------------------------------------------------------------
    # Test 6 (READ-01): Developer can query the read model directly via Ecto
    # ---------------------------------------------------------------------------

    test "READ-01 — read-model rows are queryable via Ecto after successful projection" do
      projector_name = unique_projector_name()

      # Handler that stores the event type in payload
      query_handler = fn pname, event, position ->
        multi =
          Ecto.Multi.new()
          |> Ecto.Multi.insert(
            :read_model_insert,
            ProjectionReadModel.changeset(%ProjectionReadModel{}, %{
              projector_name: pname,
              position: position,
              payload: %{"type" => event.type}
            })
          )

        {:ok, multi}
      end

      pid = start_supervised!({ProjectorGenServer, test_config(projector_name, query_handler)})
      Ecto.Adapters.SQL.Sandbox.allow(ProjectionRepo, self(), pid)

      Enum.each(0..2, &append_event("OrderPlaced", &1))
      assert :ok = wait_until(fn -> row_count(projector_name) == 3 end)

      # Query 1: get_by on a specific position (READ-01 — developer-facing Ecto query path)
      row =
        ProjectionRepo.get_by(ProjectionReadModel, projector_name: projector_name, position: 1)

      assert row != nil
      assert row.payload["type"] == "OrderPlaced"

      # Query 2: all rows via Ecto.Query
      all_rows =
        ProjectionRepo.all(
          from(r in ProjectionReadModel,
            where: r.projector_name == ^projector_name,
            order_by: r.position
          )
        )

      assert length(all_rows) == 3
      assert Enum.map(all_rows, & &1.position) == [0, 1, 2]
      assert Enum.all?(all_rows, fn r -> r.payload["type"] == "OrderPlaced" end)

      # Query 3: aggregate count
      count =
        ProjectionRepo.aggregate(
          from(r in ProjectionReadModel, where: r.projector_name == ^projector_name),
          :count
        )

      assert count == 3

      # Projector is still alive (not halted)
      assert Process.alive?(pid)
    end
  end
end
