if Code.ensure_loaded?(Snap.Cluster) and Code.ensure_loaded?(Ecto.Migrator) do
  # ---------------------------------------------------------------------------
  # Event stub module — used as the project_es/2 target so inspect/1 returns
  # a predictable string for type-based dispatch.
  # ---------------------------------------------------------------------------
  defmodule Mix.Tasks.Orkestra.Projection.Es.RebuildTest.RebuildOrderPlaced do
    @moduledoc false
    defstruct [:id, :type, :data, :metadata, :global_position]
  end

  # ---------------------------------------------------------------------------
  # Inline ES projector — uses the real Orkestra.Projector macro DSL with
  # Orkestra.Test.ESCluster and InMemory event store.
  # ---------------------------------------------------------------------------
  defmodule Mix.Tasks.Orkestra.Projection.Es.RebuildTest.TestRebuildESProjector do
    @moduledoc false

    alias Mix.Tasks.Orkestra.Projection.Es.RebuildTest.RebuildOrderPlaced

    use Orkestra.Projector,
      backend: :elasticsearch,
      repo: Orkestra.Test.ProjectionRepo,
      cluster: Orkestra.Test.ESCluster,
      index: "rebuild_test_orders",
      event_store: Orkestra.EventStore.InMemory

    # index_mapping/0 is declared as a plain function (no @impl) —
    # the Projector macro does not declare a @behaviour for index_mapping/0.
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

    # project_es/2 takes a module as first arg; inspect/1 of the module becomes
    # the type_string used for dispatch. Test events must set type: inspect(module).
    project_es(RebuildOrderPlaced, fn event, _position ->
      order_id =
        (is_map(event.data) && (event.data[:order_id] || event.data["order_id"])) ||
          "order-#{event.global_position}"

      {:ok, %{"order_id" => order_id, "status" => "placed"}, "order-#{order_id}"}
    end)
  end

  # ---------------------------------------------------------------------------
  # Inline Postgres projector — used to test the backend validation error path.
  # Uses atom literals for repo/event_store (never called at runtime in this test).
  # ---------------------------------------------------------------------------
  defmodule Mix.Tasks.Orkestra.Projection.Es.RebuildTest.TestPostgresProjector do
    @moduledoc false

    use Orkestra.Projector,
      repo: Orkestra.Test.ProjectionRepo,
      event_store: Orkestra.EventStore.InMemory
  end

  defmodule Mix.Tasks.Orkestra.Projection.Es.RebuildTest do
    @moduledoc false

    use ExUnit.Case, async: false

    @moduletag :elasticsearch

    import Mox

    alias Mix.Tasks.Orkestra.Projection.Es.RebuildTest.RebuildOrderPlaced
    alias Orkestra.EventStore.InMemory
    alias Orkestra.Projection.Checkpoint
    alias Orkestra.Test.ProjectionRepo

    @projector_module Mix.Tasks.Orkestra.Projection.Es.RebuildTest.TestRebuildESProjector
    @projector_module_str "Mix.Tasks.Orkestra.Projection.Es.RebuildTest.TestRebuildESProjector"
    @projector_name "Mix.Tasks.Orkestra.Projection.Es.RebuildTest.TestRebuildESProjector"

    @postgres_projector_str "Mix.Tasks.Orkestra.Projection.Es.RebuildTest.TestPostgresProjector"

    # The event type string used for dispatch (inspect of the RebuildOrderPlaced module).
    @event_type inspect(RebuildOrderPlaced)

    # -------------------------------------------------------------------------
    # setup_all: Run Orkestra checkpoint/dead_letter migration once (DDL)
    # -------------------------------------------------------------------------

    setup_all do
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

    # -------------------------------------------------------------------------
    # setup: per-test sandbox checkout + fresh InMemory + Mox stubs
    # -------------------------------------------------------------------------

    setup :verify_on_exit!

    setup do
      :ok = Ecto.Adapters.SQL.Sandbox.checkout(ProjectionRepo)
      # Shared sandbox mode so GenServer spawned via start_supervised! can use
      # the repo connection without a separate Sandbox.allow/2 call.
      Ecto.Adapters.SQL.Sandbox.mode(ProjectionRepo, {:shared, self()})

      # Fresh InMemory event store per test
      {:ok, _} = start_supervised(InMemory)

      # Configure the Mix task to use InMemory for event collection.
      # The Mix task reads Application.get_env(:orkestra, Orkestra.EventStore, [])
      # |> Keyword.get(:adapter, ...) to find the event store module.
      Application.put_env(:orkestra, Orkestra.EventStore, adapter: InMemory)

      on_exit(fn ->
        Application.delete_env(:orkestra, Orkestra.EventStore)
      end)

      # Default Mox stub: handles all HTTP calls made by hotswap and the
      # projector GenServer (engine detection, index creation, bulk, etc.).
      # Individual tests can override with Mox.expect/4 for stricter checks.
      Mox.stub(Snap.MockHTTPClient, :request, fn _cluster, method, url, _headers, _body, _opts ->
        cond do
          # Engine detection: GET /
          method == :get and
              (String.ends_with?(url, ":9200/") or String.ends_with?(url, ":9200")) ->
            body = ~s({"name":"test","version":{"number":"8.0.0"}})
            {:ok, %Snap.HTTPClient.Response{status: 200, body: body}}

          # Index listing for alias/cleanup: GET /_cat/indices
          method == :get and String.contains?(url, "_cat/indices") ->
            # Return one old versioned index for cleanup to exercise the code path
            body = ~s([{"index":"rebuild_test_orders-11111111"}])
            {:ok, %Snap.HTTPClient.Response{status: 200, body: body}}

          # Versioned index creation: PUT /rebuild_test_orders-{timestamp}
          method == :put and String.match?(url, ~r/rebuild_test_orders-\d+$/) ->
            {:ok, %Snap.HTTPClient.Response{status: 200, body: ~s({"acknowledged":true})}}

          # Initial index creation by ES adapter init: PUT /rebuild_test_orders
          method == :put and String.ends_with?(url, "rebuild_test_orders") ->
            {:ok, %Snap.HTTPClient.Response{status: 200, body: ~s({"acknowledged":true})}}

          # Bulk indexing: POST /_bulk
          method == :post and String.contains?(url, "_bulk") ->
            body = ~s({"errors":false,"items":[]})
            {:ok, %Snap.HTTPClient.Response{status: 200, body: body}}

          # Index refresh: POST /rebuild_test_orders-{ts}/_refresh
          method == :post and String.contains?(url, "_refresh") ->
            {:ok, %Snap.HTTPClient.Response{status: 200, body: ~s({"_shards":{"total":1}})}}

          # Alias swap: POST /_aliases
          method == :post and String.contains?(url, "_aliases") ->
            {:ok, %Snap.HTTPClient.Response{status: 200, body: ~s({"acknowledged":true})}}

          # Old index deletion: DELETE /rebuild_test_orders-11111111
          method == :delete and String.contains?(url, "rebuild_test_orders") ->
            {:ok, %Snap.HTTPClient.Response{status: 200, body: ~s({"acknowledged":true})}}

          # Single-doc live write: PUT /{index}/_doc/{id}
          method == :put and String.contains?(url, "_doc") ->
            {:ok, %Snap.HTTPClient.Response{status: 200, body: ~s({"result":"updated"})}}

          true ->
            {:error, %Snap.HTTPClient.Error{reason: :unexpected_call, origin: nil}}
        end
      end)

      :ok
    end

    # -------------------------------------------------------------------------
    # Helpers
    # -------------------------------------------------------------------------

    # Appends a raw event to the InMemory EventStore.
    # Uses @event_type (inspect of RebuildOrderPlaced) so __dispatch_es__/3 matches.
    defp append_event(stream_revision) do
      InMemory.append_events(
        "test-stream",
        [
          %{
            id: "evt-rebuild-#{stream_revision}",
            type: @event_type,
            data: %{order_id: "order-#{stream_revision}"},
            metadata: %{},
            stream_revision: stream_revision
          }
        ],
        :any
      )
    end

    defp get_checkpoint(projector_name) do
      ProjectionRepo.get_by(Checkpoint, projector_name: projector_name)
    end

    # Polls until fun.() returns truthy, or times out (max_ms).
    defp wait_until(max_ms, fun) do
      deadline = System.monotonic_time(:millisecond) + max_ms
      do_wait(deadline, fun)
    end

    defp do_wait(deadline, fun) do
      if fun.() do
        :ok
      else
        if System.monotonic_time(:millisecond) >= deadline do
          {:error, :timeout}
        else
          Process.sleep(20)
          do_wait(deadline, fun)
        end
      end
    end

    # -------------------------------------------------------------------------
    # RBLD-01: Full rebuild creates versioned index, replays events, swaps alias
    # -------------------------------------------------------------------------

    describe "RBLD-01: full rebuild (hotswap sequence)" do
      test "creates versioned index, replays events, swaps alias, cleans up, resets checkpoint" do
        # Append 3 events to InMemory EventStore
        Enum.each(0..2, &append_event/1)

        # Track HTTP calls to verify hotswap sequence
        test_pid = self()

        Mox.stub(
          Snap.MockHTTPClient,
          :request,
          fn _cluster, method, url, _headers, _body, _opts ->
            send(test_pid, {:http_call, method, url})

            cond do
              method == :get and String.contains?(url, "_cat/indices") ->
                body = ~s([{"index":"rebuild_test_orders-11111111"}])
                {:ok, %Snap.HTTPClient.Response{status: 200, body: body}}

              method == :put and String.match?(url, ~r/rebuild_test_orders-\d+$/) ->
                {:ok, %Snap.HTTPClient.Response{status: 200, body: ~s({"acknowledged":true})}}

              method == :put and String.ends_with?(url, "rebuild_test_orders") ->
                {:ok, %Snap.HTTPClient.Response{status: 200, body: ~s({"acknowledged":true})}}

              method == :post and String.contains?(url, "_bulk") ->
                {:ok,
                 %Snap.HTTPClient.Response{status: 200, body: ~s({"errors":false,"items":[]})}}

              method == :post and String.contains?(url, "_refresh") ->
                {:ok, %Snap.HTTPClient.Response{status: 200, body: ~s({"_shards":{"total":1}})}}

              method == :post and String.contains?(url, "_aliases") ->
                {:ok,
                 %Snap.HTTPClient.Response{status: 200, body: ~s({"acknowledged":true})}}

              method == :delete and String.contains?(url, "rebuild_test_orders") ->
                {:ok, %Snap.HTTPClient.Response{status: 200, body: ~s({"acknowledged":true})}}

              method == :put and String.contains?(url, "_doc") ->
                {:ok,
                 %Snap.HTTPClient.Response{status: 200, body: ~s({"result":"updated"})}}

              true ->
                {:error, %Snap.HTTPClient.Error{reason: :unexpected_call, origin: nil}}
            end
          end
        )

        # Run the rebuild task (--yes skips the confirmation prompt)
        Mix.Tasks.Orkestra.Projection.Es.Rebuild.run([@projector_module_str, "--yes"])

        # Verify hotswap sequence via received HTTP call messages:
        # Step 1 — PUT versioned index (create)
        assert_receive {:http_call, :put, create_url}, 500
        assert String.match?(create_url, ~r/rebuild_test_orders-\d+/)

        # Step 2 — POST /_bulk (document load — 3 events = 3 docs)
        assert_receive {:http_call, :post, bulk_url}, 500
        assert String.contains?(bulk_url, "_bulk")

        # Step 3 — POST /{versioned-index}/_refresh
        assert_receive {:http_call, :post, refresh_url}, 500
        assert String.contains?(refresh_url, "_refresh")

        # Step 4 — GET /_cat/indices (for alias list_starting_with)
        assert_receive {:http_call, :get, cat_url}, 500
        assert String.contains?(cat_url, "_cat/indices")

        # Step 5 — POST /_aliases (alias swap)
        assert_receive {:http_call, :post, aliases_url}, 500
        assert String.contains?(aliases_url, "_aliases")

        # Verify checkpoint was reset after successful hotswap (T-09-07)
        checkpoint = get_checkpoint(@projector_name)
        assert checkpoint == nil, "Expected checkpoint to be deleted after rebuild"
      end
    end

    # -------------------------------------------------------------------------
    # RBLD-02: Mix task validation errors
    # -------------------------------------------------------------------------

    describe "RBLD-02: Mix task validation" do
      test "raises Mix.Error when no module argument provided" do
        assert_raise Mix.Error, ~r/requires a projector module name/, fn ->
          Mix.Tasks.Orkestra.Projection.Es.Rebuild.run([])
        end
      end

      test "raises Mix.Error for non-ES projector (Postgres backend)" do
        # Use the inline Postgres projector defined at the top of this file.
        # It has backend: :postgres (default), so es.rebuild should reject it.
        assert_raise Mix.Error, ~r/not an Elasticsearch projector/, fn ->
          Mix.Tasks.Orkestra.Projection.Es.Rebuild.run([@postgres_projector_str, "--yes"])
        end
      end
    end

    # -------------------------------------------------------------------------
    # RBLD-03: Live GenServer is paused during rebuild and resumed after
    # -------------------------------------------------------------------------

    describe "RBLD-03: GenServer pause/resume during rebuild" do
      test "pauses live GenServer, swaps alias, resets checkpoint, then resumes" do
        projector_name = @projector_name

        # Start the ES projector GenServer using the macro-generated child_spec/1.
        pid = start_supervised!(@projector_module)
        Mox.allow(Snap.MockHTTPClient, self(), pid)

        # Append an event and wait for the GenServer to process it (checkpoint advances).
        append_event(0)

        # Wait until checkpoint is written (proves GenServer is running and alive)
        assert :ok =
                 wait_until(5000, fn ->
                   cp = get_checkpoint(projector_name)
                   cp != nil && cp.last_position == 0
                 end)

        # Verify the GenServer is alive before rebuild
        assert Process.alive?(pid)

        # Checkpoint exists before rebuild
        assert get_checkpoint(projector_name) != nil

        # Run the rebuild task — should pause pid, hotswap, reset checkpoint, resume
        Mix.Tasks.Orkestra.Projection.Es.Rebuild.run([@projector_module_str, "--yes"])

        # GenServer must be alive after rebuild — resume_writes called in try/after (T-09-08)
        assert Process.alive?(pid), "GenServer must remain alive after rebuild"

        # Checkpoint must be reset (deleted) after successful hotswap (T-09-07)
        checkpoint_after = get_checkpoint(projector_name)

        assert checkpoint_after == nil,
               "Expected checkpoint to be deleted after rebuild, but found: #{inspect(checkpoint_after)}"
      end

      test "resumes GenServer even when no events exist (empty hotswap)" do
        # Start GenServer with no events in the EventStore
        pid = start_supervised!(@projector_module)
        Mox.allow(Snap.MockHTTPClient, self(), pid)

        # Run rebuild — empty bulk load, hotswap still succeeds, GenServer still resumes
        Mix.Tasks.Orkestra.Projection.Es.Rebuild.run([@projector_module_str, "--yes"])

        # GenServer must be alive after an empty rebuild (T-09-08 — always resume)
        assert Process.alive?(pid), "GenServer must be alive after empty rebuild"
      end
    end
  end
end
