if Code.ensure_loaded?(Ecto.Multi) do
  defmodule Orkestra.Projector.EventStoreDBIntegrationTest do
    @moduledoc """
    Acceptance test: a *real* `Orkestra.Projector.GenServer` (Postgres read-model
    + checkpoint) driven by a *real* EventStoreDB via the Spear adapter.

    Proves the end-to-end delivery + resume contract that the connection-free
    tests cannot:

      * events appended through `Orkestra.EventStore.EventStoreDB.append_events/3`
        are delivered to the projector as `stored_event_with_position()` maps and
        projected into the Postgres read model, with the checkpoint advancing to
        the event's `:global_position` (commit_position);
      * a **multi-event atomic append** (two events in a single
        `append_events/3` call — the `Aggregate.Root` "one decide emits several
        events" case) is projected fully; and, after **stopping the projector and
        appending that batch, then starting a fresh projector with the same
        name**, resume replays the batch exactly once — neither losing the second
        intra-commit event nor double-applying any event;
      * an **unhandled event type** (what a `snapshot-*` / foreign event looks
        like to a projector) advances the checkpoint without dead-lettering and
        without halting.

    Requires the same backends as the rest of `test/integration/`:

        docker run -d --name orkestra-esdb-test -p 2113:2113 \\
          -e EVENTSTORE_INSECURE=true -e EVENTSTORE_MEM_DB=true \\
          -e EVENTSTORE_RUN_PROJECTIONS=None eventstore/eventstore:24.10.0
        # + a Postgres reachable via DATABASE_URL (docker-compose.es.yml)

    Run with `mix test --only integration`.
    """

    use ExUnit.Case, async: false

    @moduletag :integration

    import Ecto.Query, only: [from: 2]

    alias Ecto.Adapters.SQL.Sandbox
    alias Orkestra.EventStore.EventStoreDB
    alias Orkestra.Projection.{Checkpoint, DeadLetter}
    alias Orkestra.Projection.Storage.Postgres, as: PostgresAdapter
    alias Orkestra.Projector.GenServer, as: ProjectorGenServer
    alias Orkestra.Test.{ProjectionMigrations, ProjectionReadModel, ProjectionRepo}

    @conn Orkestra.EventStore.EventStoreDB.Connection

    # ---------------------------------------------------------------------------
    # Setup: real Spear connection under the adapter's hard-coded name + one-time
    # migration of the checkpoint / dead_letter / read-model tables.
    # ---------------------------------------------------------------------------

    setup_all do
      start_supervised!(
        {Spear.Connection, name: @conn, connection_string: "esdb://localhost:2113?tls=false"}
      )

      wait_ready(@conn, 40)

      Sandbox.unboxed_run(ProjectionRepo, fn ->
        Ecto.Migrator.run(
          ProjectionRepo,
          [{1, Orkestra.Projection.Migration}],
          :up,
          all: true,
          migration_lock: false
        )

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
      :ok = Sandbox.checkout(ProjectionRepo)
      # Shared mode so the start_supervised! projector shares the test's sandbox
      # connection without an explicit allow race (see gen_server_test.exs).
      Sandbox.mode(ProjectionRepo, {:shared, self()})
      {:ok, tag: rand(), stream: "orkestra-pit-#{rand()}"}
    end

    # ---------------------------------------------------------------------------
    # Tests
    # ---------------------------------------------------------------------------

    test "projects appended events into the read model and advances the checkpoint",
         %{tag: tag, stream: stream} do
      projector_name = unique_projector_name()
      seed_checkpoint(projector_name)
      pid = start_supervised!({ProjectorGenServer, config(projector_name, tag)})
      Sandbox.allow(ProjectionRepo, self(), pid)

      {:ok, _} = EventStoreDB.append_events(stream, [evt("Created", tag)], -1)
      {:ok, _} = EventStoreDB.append_events(stream, [evt("Updated", tag)], 0)
      {:ok, _} = EventStoreDB.append_events(stream, [evt("Updated", tag)], 1)

      assert :ok = wait_until(fn -> row_count(projector_name) == 3 end)

      rows = rows(projector_name)
      # Positions are the ESDB $all commit_positions: strictly increasing, unique.
      positions = Enum.map(rows, & &1.position)
      assert positions == Enum.sort(positions)
      assert positions == Enum.uniq(positions)

      cp = checkpoint(projector_name)
      assert cp.halted == false
      # Checkpoint sits at (at least) the last projected event's position.
      assert cp.last_position >= List.last(positions)
      # No spurious dead-lettering of the foreign $all traffic the projector saw.
      assert dead_letters(projector_name) == 0
    end

    test "multi-event atomic append is projected fully and survives a mid-stream restart",
         %{tag: tag, stream: stream} do
      projector_name = unique_projector_name()
      seed_checkpoint(projector_name)

      # Phase 1 — project two single events, then stop the projector.
      pid1 = start_supervised!({ProjectorGenServer, config(projector_name, tag)}, id: :p1)
      Sandbox.allow(ProjectionRepo, self(), pid1)

      {:ok, _} = EventStoreDB.append_events(stream, [evt("Created", tag)], -1)
      {:ok, _} = EventStoreDB.append_events(stream, [evt("Updated", tag)], 0)
      assert :ok = wait_until(fn -> row_count(projector_name) == 2 end)

      cp_before = checkpoint(projector_name)
      assert cp_before.halted == false
      stop_supervised(:p1)

      # While the projector is DOWN, append a *single atomic* multi-event batch
      # (two events, one `append_events/3` call → one decide emitting two events)
      # plus a trailing single event.
      {:ok, _} =
        EventStoreDB.append_events(stream, [evt("MultiA", tag), evt("MultiB", tag)], 1)

      {:ok, _} = EventStoreDB.append_events(stream, [evt("Updated", tag)], 3)

      # Phase 2 — a fresh projector with the SAME name resumes from the checkpoint.
      pid2 = start_supervised!({ProjectorGenServer, config(projector_name, tag)}, id: :p2)
      Sandbox.allow(ProjectionRepo, self(), pid2)

      # Exactly 5 rows total: 2 (phase 1) + 2 (multi) + 1 (trailing). Neither 4
      # (a lost intra-commit event) nor >5 (reprocessing of phase-1 events).
      assert :ok = wait_until(fn -> row_count(projector_name) == 5 end)
      # Give any erroneous duplicate/extra delivery a chance to (not) land.
      Process.sleep(300)
      assert row_count(projector_name) == 5

      rows = rows(projector_name)
      positions = Enum.map(rows, & &1.position)
      assert positions == Enum.uniq(positions), "resume must not double-apply any event"
      assert positions == Enum.sort(positions)

      # Both intra-commit events made it into the read model.
      types = rows |> Enum.map(& &1.payload["type"])
      assert "MultiA" in types
      assert "MultiB" in types

      cp_after = checkpoint(projector_name)
      assert cp_after.halted == false
      assert cp_after.last_position >= List.last(positions)
      assert dead_letters(projector_name) == 0
    end

    test "an unhandled event type advances the checkpoint without dead-lettering",
         %{tag: tag, stream: stream} do
      projector_name = unique_projector_name()
      seed_checkpoint(projector_name)
      pid = start_supervised!({ProjectorGenServer, config(projector_name, tag)})
      Sandbox.allow(ProjectionRepo, self(), pid)

      # A handled event, then an event the handler does not recognise (this is
      # what a snapshot-* / foreign event looks like to the projector), then
      # another handled event.
      {:ok, _} = EventStoreDB.append_events(stream, [evt("Created", tag)], -1)
      {:ok, _} = EventStoreDB.append_events(stream, [evt("SnapshotLike", tag)], 0)
      {:ok, _} = EventStoreDB.append_events(stream, [evt("Updated", tag)], 1)

      # Only the two handled events produce rows; the checkpoint still advances
      # past the unhandled one (proved by the third event being projected).
      assert :ok = wait_until(fn -> row_count(projector_name) == 2 end)

      assert dead_letters(projector_name) == 0
      assert Process.alive?(pid)
      cp = checkpoint(projector_name)
      assert cp.halted == false
    end

    # ---------------------------------------------------------------------------
    # Helpers
    # ---------------------------------------------------------------------------

    # Projector config: EventStoreDB event store + Postgres storage. The handler
    # only writes rows for THIS run's tag and known types; everything else
    # (other tests' $all traffic, unknown types) returns an empty Multi so the
    # checkpoint advances without a read-model row and without dead-lettering.
    defp config(projector_name, tag) do
      %{
        repo: ProjectionRepo,
        projector_name: projector_name,
        storage_adapter: PostgresAdapter,
        event_store: EventStoreDB,
        lifecycle_config: %{max_retries: 2, backoff_base_ms: 5, backoff_cap_ms: 50},
        adapter_opts: [handler: handler(tag)]
      }
    end

    # The real Orkestra.Event module the adapter can resolve, so the JSON-decoded
    # event `data` is atomized back to the field atoms and the handler can read
    # `event.data.field` the way a real app does.
    @known_type "Orkestra.Test.Fixtures.WorkspaceCreated"

    defp handler(tag) do
      known_labels = ["Created", "Updated", "MultiA", "MultiB"]

      fn projector_name, event, position ->
        # `and` short-circuits: the type/tag gates run BEFORE any `event.data`
        # access, so foreign $all traffic and the unresolvable SnapshotLike event
        # (whose data stays string-keyed) are never read via atom keys.
        if event.type == @known_type and event.metadata["test_tag"] == tag and
             event.data.name in known_labels do
          # Real-app style ATOM access on event.data — pre-fix the string-keyed
          # data raised `(KeyError) key :name not found` here, halting the
          # projector so these rows would never appear (the bug this guards).
          multi =
            Ecto.Multi.new()
            |> Ecto.Multi.insert(
              :read_model_insert,
              ProjectionReadModel.changeset(%ProjectionReadModel{}, %{
                projector_name: projector_name,
                position: position,
                payload: %{
                  "type" => event.data.name,
                  "workspace_id" => event.data.workspace_id
                }
              })
            )

          {:ok, multi}
        else
          # Unhandled: advance the checkpoint (empty read-model Multi), no dead-letter.
          {:ok, Ecto.Multi.new()}
        end
      end
    end

    # A stored_event map for append_events/3, tagged with the run tag in metadata.
    #
    # A handled `label` is emitted as the real @known_type event with the label
    # carried in the atom-keyed `:name` field (so the adapter round-trips it back
    # to atoms); "SnapshotLike" is emitted as an unresolvable foreign type whose
    # string-keyed data the handler never reads.
    defp evt(label, tag) do
      {type, data} =
        if label == "SnapshotLike" do
          {"SnapshotLike", %{"v" => 1}}
        else
          {@known_type, %{workspace_id: "ws-#{tag}", name: label}}
        end

      %{
        id: rand(),
        type: type,
        data: data,
        metadata: %{"test_tag" => tag, "correlation_id" => "c-#{tag}"},
        stream_revision: 0
      }
    end

    # Seeds a non-halted checkpoint at the CURRENT $all head, so the projector
    # resumes from "now" and only processes events this test appends — rather
    # than replaying the whole accumulated $all history (which, in a long-lived
    # MEM_DB container, is thousands of events and would both slow the test and
    # saturate the shared Spear connection). Inserted in the test process under
    # shared-sandbox mode, so it is visible to the projector's deferred
    # :load_checkpoint read.
    defp seed_checkpoint(projector_name) do
      ProjectionRepo.insert!(%Checkpoint{
        projector_name: projector_name,
        last_position: all_head(),
        halted: false,
        updated_at: DateTime.utc_now()
      })
    end

    # The commit_position of the last event currently on $all (or -1 if empty).
    defp all_head do
      case Spear.read_stream(@conn, :all, from: :end, direction: :backwards, max_count: 1) do
        {:ok, stream} ->
          case Enum.take(stream, 1) do
            [%Spear.Event{metadata: %{commit_position: pos}}] when is_integer(pos) and pos >= 0 ->
              pos

            _ ->
              -1
          end

        _ ->
          -1
      end
    end

    defp rand, do: Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)

    defp unique_projector_name, do: "pit_projector_#{:erlang.unique_integer([:positive])}"

    defp row_count(projector_name) do
      ProjectionRepo.aggregate(
        from(r in ProjectionReadModel, where: r.projector_name == ^projector_name),
        :count
      )
    end

    defp rows(projector_name) do
      ProjectionRepo.all(
        from(r in ProjectionReadModel,
          where: r.projector_name == ^projector_name,
          order_by: r.position
        )
      )
    end

    defp checkpoint(projector_name),
      do: ProjectionRepo.get_by(Checkpoint, projector_name: projector_name)

    defp dead_letters(projector_name) do
      ProjectionRepo.aggregate(
        from(d in DeadLetter, where: d.projector_name == ^projector_name),
        :count
      )
    end

    defp wait_until(max_ms \\ 5_000, fun) do
      deadline = System.monotonic_time(:millisecond) + max_ms
      poll(deadline, fun)
    end

    defp poll(deadline, fun) do
      cond do
        fun.() ->
          :ok

        System.monotonic_time(:millisecond) >= deadline ->
          {:error, :timeout}

        true ->
          Process.sleep(20)
          poll(deadline, fun)
      end
    end

    defp wait_ready(_conn, 0), do: flunk("EventStoreDB connection never became ready")

    defp wait_ready(conn, attempts) do
      probe = Spear.Event.new("ReadinessProbe", %{})

      case Spear.append([probe], conn, "orkestra-pit-readiness", expect: :any) do
        :ok ->
          :ok

        _ ->
          Process.sleep(250)
          wait_ready(conn, attempts - 1)
      end
    end
  end
end
