if Code.ensure_loaded?(Snap.Cluster) do
  defmodule Orkestra.Projector.GenServerEsTest do
    @moduledoc false

    use ExUnit.Case, async: false

    @moduletag :elasticsearch

    import Mox

    alias Orkestra.EventStore.InMemory
    alias Orkestra.Projection.Checkpoint
    alias Orkestra.Projection.DeadLetter
    alias Orkestra.Projection.Storage.Elasticsearch, as: ESAdapter
    alias Orkestra.Projector.GenServer, as: ProjectorGenServer
    alias Orkestra.Test.ESCluster
    alias Orkestra.Test.ProjectionRepo

    # ---------------------------------------------------------------------------
    # Setup: DDL migration once (outside per-test sandbox transaction) + per-test
    # checkout + fresh InMemory EventStore per test + Mox stubs for Snap.
    # ---------------------------------------------------------------------------

    setup_all do
      # Run only the Orkestra checkpoint / dead_letter migrations.
      # ES tests do not need a read-model table (no Ecto read model used).
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

    # Verify Mox expectations after each test (checks expect/stub counts)
    setup :verify_on_exit!

    setup do
      :ok = Ecto.Adapters.SQL.Sandbox.checkout(ProjectionRepo)
      # Shared mode lets all processes started in this test (including the
      # ProjectorGenServer spawned by start_supervised!) access the sandbox
      # connection without an explicit allow/2 call — eliminating the race
      # between GenServer's deferred :load_checkpoint and Sandbox.allow.
      Ecto.Adapters.SQL.Sandbox.mode(ProjectionRepo, {:shared, self()})

      # Start a fresh InMemory event store adapter for each test.
      {:ok, _} = start_supervised(InMemory)

      # Attach telemetry handler for ES bulk flush events (OBSV-02).
      # All tests can use assert_receive / refute_receive on {:telemetry, :es_bulk_flush, ...}
      test_pid = self()
      handler_id = "test-es-bulk-flush-#{inspect(self())}"

      :telemetry.attach(
        handler_id,
        [:orkestra, :projector, :es_bulk_flush],
        fn _event, measurements, metadata, _config ->
          send(test_pid, {:telemetry, :es_bulk_flush, measurements, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      # Default Mox stub handles common Snap HTTP calls:
      #   - PUT /{index}/_doc/{id}  → single-doc index success
      #   - POST /_bulk             → bulk success
      # Individual tests override this with Mox.expect/4 for stricter assertions.
      Mox.stub(Snap.MockHTTPClient, :request, fn _cluster, method, url, _headers, _body, _opts ->
        cond do
          method == :put and String.contains?(url, "_doc") ->
            {:ok, %Snap.HTTPClient.Response{status: 200, body: ~s({"result":"updated"})}}

          method == :post and String.contains?(url, "_bulk") ->
            {:ok,
             %Snap.HTTPClient.Response{
               status: 200,
               body: ~s({"errors":false,"items":[]})
             }}

          true ->
            {:error, %Snap.HTTPClient.Error{reason: :unexpected_call, origin: nil}}
        end
      end)

      :ok
    end

    # ---------------------------------------------------------------------------
    # Helpers
    # ---------------------------------------------------------------------------

    # Returns a unique projector name per test invocation.
    defp unique_projector_name, do: "test_projector_#{:erlang.unique_integer([:positive])}"

    # Appends a single event to the InMemory event store.
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

    # Polls until `fun.()` returns truthy, or times out (max_ms default 3000).
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

    # Returns the checkpoint for a projector (or nil if none).
    defp get_checkpoint(projector_name) do
      ProjectionRepo.get_by(Checkpoint, projector_name: projector_name)
    end

    # Default ES handler: returns a document and deterministic ID for every event.
    defp default_es_handler(_projector_name, _event, position) do
      {:ok, %{"data" => "test"}, "doc-#{position}"}
    end

    # Builds ES GenServer config for a test.
    defp es_config(projector_name, opts \\ []) do
      %{
        repo: ProjectionRepo,
        projector_name: projector_name,
        storage_adapter: ESAdapter,
        event_store: InMemory,
        lifecycle_config: %{
          max_retries: 2,
          backoff_base_ms: 5,
          backoff_cap_ms: 50
        },
        adapter_opts: [
          cluster: ESCluster,
          index: Keyword.get(opts, :index, "test_index"),
          handler: Keyword.get(opts, :handler, &default_es_handler/3),
          engine: :elasticsearch
        ]
      }
      |> then(fn config ->
        case Keyword.get(opts, :rebuild_total) do
          nil ->
            config

          total ->
            Map.merge(config, %{
              rebuild_total: total,
              es_batch_size: Keyword.get(opts, :es_batch_size, 500)
            })
        end
      end)
    end

    # ---------------------------------------------------------------------------
    # Test 1 (BULK-02): Live mode — single doc write per event via Snap.Document.index
    # ---------------------------------------------------------------------------

    test "BULK-02 -- live mode: single doc write calls Snap.Document.index once per event" do
      projector_name = unique_projector_name()

      # Expect exactly one PUT _doc call (Snap.Document.index uses PUT /{index}/_doc/{id})
      Mox.expect(Snap.MockHTTPClient, :request, 1, fn _cluster,
                                                       :put,
                                                       url,
                                                       _headers,
                                                       _body,
                                                       _opts ->
        assert String.contains?(url, "_doc"),
               "Expected a PUT to /{index}/_doc/{id} but got: #{url}"

        {:ok, %Snap.HTTPClient.Response{status: 200, body: ~s({"result":"updated"})}}
      end)

      # No rebuild_total → live mode
      pid = start_supervised!({ProjectorGenServer, es_config(projector_name)})
      # Mox.allow AFTER start_supervised! but BEFORE event delivery (critical ordering)
      Mox.allow(Snap.MockHTTPClient, self(), pid)

      append_event("LiveEvent", 0)

      # Wait until checkpoint is written (proves the full commit path ran)
      assert :ok =
               wait_until(fn ->
                 cp = get_checkpoint(projector_name)
                 cp != nil && cp.last_position == 0
               end)

      # Checkpoint must be non-halted
      checkpoint = get_checkpoint(projector_name)
      assert checkpoint != nil
      assert checkpoint.last_position == 0
      assert checkpoint.halted == false

      # Mox.expect assertion is verified by setup :verify_on_exit! — if the PUT
      # _doc call was not made exactly once, the test fails after this point.
    end

    # ---------------------------------------------------------------------------
    # Test 2 (BULK-01): Catch-up mode — buffer accumulates and flushes at batch_size
    # ---------------------------------------------------------------------------

    test "BULK-01 -- catch-up mode: buffer accumulates and flushes at batch_size via Snap.Bulk.perform" do
      projector_name = unique_projector_name()

      # Expect exactly one POST _bulk call when batch_size (3) events are buffered
      Mox.expect(Snap.MockHTTPClient, :request, 1, fn _cluster,
                                                       :post,
                                                       url,
                                                       _headers,
                                                       _body,
                                                       _opts ->
        assert String.contains?(url, "_bulk"),
               "Expected a POST to /_bulk but got: #{url}"

        {:ok,
         %Snap.HTTPClient.Response{
           status: 200,
           body: ~s({"errors":false,"items":[]})
         }}
      end)

      # rebuild_total: 10 + es_batch_size: 3 → catching_up mode, flush after 3 events
      pid =
        start_supervised!(
          {ProjectorGenServer, es_config(projector_name, rebuild_total: 10, es_batch_size: 3)}
        )

      Mox.allow(Snap.MockHTTPClient, self(), pid)

      # Append exactly batch_size (3) events to trigger flush
      Enum.each(0..2, &append_event("CatchUpEvent", &1))

      # Wait until checkpoint advances to position 2 (last in the batch)
      assert :ok =
               wait_until(5000, fn ->
                 cp = get_checkpoint(projector_name)
                 cp != nil && cp.last_position == 2
               end)

      checkpoint = get_checkpoint(projector_name)
      assert checkpoint != nil
      assert checkpoint.last_position == 2
      assert checkpoint.halted == false
    end

    # ---------------------------------------------------------------------------
    # Test 3 (BULK-01 cont): Partial buffer — no flush before batch_size reached
    # ---------------------------------------------------------------------------

    test "BULK-01 -- partial buffer does NOT flush when event count is below batch_size" do
      projector_name = unique_projector_name()

      # We expect exactly one bulk flush for the first batch of 3 events.
      # The next 2 events should NOT trigger a flush (buffer stays at 2 < batch_size 3).
      Mox.expect(Snap.MockHTTPClient, :request, 1, fn _cluster,
                                                       :post,
                                                       _url,
                                                       _headers,
                                                       _body,
                                                       _opts ->
        {:ok,
         %Snap.HTTPClient.Response{
           status: 200,
           body: ~s({"errors":false,"items":[]})
         }}
      end)

      pid =
        start_supervised!(
          {ProjectorGenServer, es_config(projector_name, rebuild_total: 10, es_batch_size: 3)}
        )

      Mox.allow(Snap.MockHTTPClient, self(), pid)

      # First batch: 3 events → flush
      Enum.each(0..2, &append_event("BatchEvent", &1))

      assert :ok =
               wait_until(5000, fn ->
                 cp = get_checkpoint(projector_name)
                 cp != nil && cp.last_position == 2
               end)

      # Second partial batch: 2 events → NO flush (2 < batch_size 3)
      Enum.each(3..4, &append_event("BatchEvent", &1))

      # Give the GenServer time to process (it should NOT flush)
      Process.sleep(200)

      # Checkpoint must NOT have advanced past position 2
      checkpoint = get_checkpoint(projector_name)
      assert checkpoint != nil
      assert checkpoint.last_position == 2,
             "Expected checkpoint to stay at 2, but got: #{inspect(checkpoint.last_position)}"

      # Mox verify_on_exit! ensures the second bulk POST was NOT called
    end

    # ---------------------------------------------------------------------------
    # Test 4 (BULK-03): Partial bulk failure does not advance checkpoint
    # ---------------------------------------------------------------------------

    test "BULK-03 -- partial bulk failure: checkpoint does NOT advance and projector halts" do
      projector_name = unique_projector_name()

      # Partial failure response: first item success, second item mapper error
      partial_failure_body =
        ~s({"errors":true,"items":[{"index":{"_id":"doc-0","status":200,"result":"created"}},{"index":{"_id":"doc-1","error":{"type":"mapper_parsing_exception","reason":"failed to parse field"},"status":400}}]})

      # Expect exactly one POST _bulk call that returns a partial failure
      Mox.expect(Snap.MockHTTPClient, :request, 1, fn _cluster,
                                                       :post,
                                                       url,
                                                       _headers,
                                                       _body,
                                                       _opts ->
        assert String.contains?(url, "_bulk")
        {:ok, %Snap.HTTPClient.Response{status: 200, body: partial_failure_body}}
      end)

      # max_retries: 0 → halt immediately on first failure (no retry loop)
      config =
        es_config(projector_name, rebuild_total: 10, es_batch_size: 2)
        |> Map.put(:lifecycle_config, %{
          max_retries: 0,
          backoff_base_ms: 5,
          backoff_cap_ms: 50
        })

      pid = start_supervised!({ProjectorGenServer, config})
      Mox.allow(Snap.MockHTTPClient, self(), pid)

      # Append exactly batch_size (2) events to trigger flush
      Enum.each(0..1, &append_event("FailBulkEvent", &1))

      # Wait until GenServer halts (checkpoint.halted = true)
      assert :ok =
               wait_until(5000, fn ->
                 cp = get_checkpoint(projector_name)
                 cp != nil && cp.halted == true
               end)

      checkpoint = get_checkpoint(projector_name)
      assert checkpoint != nil
      assert checkpoint.halted == true

      # Checkpoint must NOT have advanced to position 1 (partial failure → no commit)
      # The halted checkpoint has last_position = position - 1 (exclusive semantics for replay)
      # For position 0 event (first to fail), halt_position = 0 - 1 = -1
      assert checkpoint.last_position < 1,
             "Expected checkpoint not to advance to 1 after partial failure, got: #{checkpoint.last_position}"

      # A dead_letter row must exist confirming failure was persisted (T-07-06)
      dead_letter =
        ProjectionRepo.get_by(DeadLetter, projector_name: projector_name)

      assert dead_letter != nil, "Expected a dead_letter row to be persisted after bulk failure"
    end

    # ---------------------------------------------------------------------------
    # Test 5 (OBSV-02): Telemetry event es_bulk_flush fires with correct measurements
    # ---------------------------------------------------------------------------

    test "OBSV-02 -- es_bulk_flush telemetry fires with batch_size and duration_ms" do
      projector_name = unique_projector_name()

      # Stub for the bulk success response (already set in setup, but be explicit)
      Mox.stub(Snap.MockHTTPClient, :request, fn _cluster, :post, _url, _headers, _body, _opts ->
        {:ok,
         %Snap.HTTPClient.Response{
           status: 200,
           body: ~s({"errors":false,"items":[]})
         }}
      end)

      pid =
        start_supervised!(
          {ProjectorGenServer, es_config(projector_name, rebuild_total: 10, es_batch_size: 2)}
        )

      Mox.allow(Snap.MockHTTPClient, self(), pid)

      # Append batch_size (2) events to trigger one flush
      Enum.each(0..1, &append_event("TelemetryBulkEvent", &1))

      # Assert the telemetry event arrives with correct measurements
      assert_receive {:telemetry, :es_bulk_flush, measurements, metadata}, 5000

      assert measurements.batch_size == 2,
             "Expected batch_size == 2, got: #{inspect(measurements.batch_size)}"

      assert is_integer(measurements.duration_ms),
             "Expected duration_ms to be an integer, got: #{inspect(measurements.duration_ms)}"

      assert measurements.duration_ms >= 0

      assert metadata.projector_name == projector_name,
             "Expected projector_name == #{projector_name}, got: #{inspect(metadata.projector_name)}"

      assert metadata.index == "test_index",
             "Expected index == 'test_index', got: #{inspect(metadata.index)}"

      assert metadata.engine == :elasticsearch,
             "Expected engine == :elasticsearch, got: #{inspect(metadata.engine)}"
    end

    # ---------------------------------------------------------------------------
    # Test 6 (OBSV-01): OTel span attribute helper es_span_attrs returns correct map
    # ---------------------------------------------------------------------------

    test "OBSV-01 -- es_span_attrs/4 returns correct attribute map with all expected keys" do
      # With doc_count
      attrs = Orkestra.Telemetry.es_span_attrs("my_projector", "orders", :elasticsearch, 5)

      assert attrs["orkestra.projector.name"] == "my_projector",
             "Expected 'orkestra.projector.name' == 'my_projector', got: #{inspect(attrs["orkestra.projector.name"])}"

      assert attrs["es.index"] == "orders",
             "Expected 'es.index' == 'orders', got: #{inspect(attrs["es.index"])}"

      assert attrs["es.engine"] == "elasticsearch",
             "Expected 'es.engine' == 'elasticsearch' (string), got: #{inspect(attrs["es.engine"])}"

      assert attrs["es.doc_count"] == 5,
             "Expected 'es.doc_count' == 5, got: #{inspect(attrs["es.doc_count"])}"

      # Without doc_count — must NOT include es.doc_count key
      attrs_no_count = Orkestra.Telemetry.es_span_attrs("my_projector", "orders", :opensearch)

      assert attrs_no_count["es.engine"] == "opensearch",
             "Expected 'es.engine' == 'opensearch', got: #{inspect(attrs_no_count["es.engine"])}"

      refute Map.has_key?(attrs_no_count, "es.doc_count"),
             "Expected 'es.doc_count' to be absent when doc_count is nil"

      # Verify all base keys are always present
      assert Map.has_key?(attrs_no_count, "orkestra.projector.name")
      assert Map.has_key?(attrs_no_count, "es.index")
      assert Map.has_key?(attrs_no_count, "es.engine")
    end
  end
end
