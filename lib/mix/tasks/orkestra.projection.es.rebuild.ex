if Code.ensure_loaded?(Snap.Cluster) and Code.ensure_loaded?(Ecto.Migrator) do
  defmodule Mix.Tasks.Orkestra.Projection.Es.Rebuild do
    @shortdoc "Zero-downtime rebuild of an Elasticsearch projection"
    @moduledoc """
    Rebuilds an Elasticsearch projection by creating a new versioned index,
    replaying all events, atomically swapping the alias, and cleaning up
    the old index — without any search downtime.

    ## Usage

        mix orkestra.projection.es.rebuild MyApp.OrderESProjector

    ## Options

    - `--yes` - Skip confirmation prompt (for scripting/CI).

    ## Rebuild sequence

    1. Validate that the module is an ES projector (`backend: :elasticsearch`).
    2. Build a stream of `Snap.Bulk.Action.Index` structs by replaying all
       events from the EventStore through the projector's `__handle_es__/3`.
    3. Call `Snap.Indexes.hotswap/5` which atomically creates a versioned
       index, bulk-loads the stream, refreshes, swaps the alias, and
       cleans up old indexes (keeping the 2 most recent).
    4. Pause the live GenServer via `GenServer.call(pid, :pause_writes)` to
       prevent race conditions during the alias swap window (RBLD-03).
    5. Reset the Postgres checkpoint so the GenServer replays from position 0.
    6. Resume the live GenServer via `GenServer.call(pid, :resume_writes)`.

    After resume, the GenServer resubscribes from position -1 (no checkpoint)
    and replays all events into the new index. Documents are idempotent
    (deterministic `_id`), so duplicate writes are safe.

    ## Error handling

    If `hotswap/5` fails (e.g. bulk error, connection failure), the task
    exits with an error. The old index and alias remain untouched — no
    data loss. Re-running the task starts a fresh rebuild.
    """

    use Mix.Task

    import Ecto.Query, only: [from: 2]

    require Logger
    require OpenTelemetry.Tracer, as: Tracer

    alias Orkestra.Projection.Checkpoint

    @impl Mix.Task
    def run(args) do
      {opts, positional, _} = OptionParser.parse(args, strict: [yes: :boolean])

      case positional do
        [projector_module_str | _] ->
          Mix.Task.run("app.start")

          module = Module.concat([projector_module_str])
          config = module.__projection_config__()

          # Validate ES backend (T-09-04 mitigation)
          unless config.backend == :elasticsearch do
            Mix.raise(
              "#{projector_module_str} is not an Elasticsearch projector " <>
                "(backend: #{inspect(config.backend)}). " <>
                "Use `mix orkestra.projection.rebuild` for Postgres projectors."
            )
          end

          unless Keyword.get(opts, :yes, false) do
            Mix.shell().info(
              "This will rebuild the Elasticsearch index for #{projector_module_str}.\n" <>
                "A new versioned index will be created, all events replayed, " <>
                "and the alias swapped atomically."
            )

            unless Mix.shell().yes?("Continue?") do
              Mix.raise("Rebuild cancelled.")
            end
          end

          cluster = config.cluster
          index = config.index
          projector_module = config.projector_module
          projector_name = config.projector_name
          repo = config.repo

          event_store =
            Application.get_env(:orkestra, Orkestra.EventStore, [])
            |> Keyword.get(:adapter, Orkestra.EventStore.InMemory)

          mapping = projector_module.index_mapping()

          # Step 1: Build the stream of Snap.Bulk.Action.Index structs.
          # Collect events eagerly because InMemory delivers synchronously and
          # hotswap consumes the entire Enumerable in one pass.
          Mix.shell().info("Collecting events from EventStore...")
          events = collect_all_events(event_store)
          Mix.shell().info("Collected #{length(events)} events.")

          Mix.shell().info("Building ES document stream...")

          stream =
            Enum.flat_map(events, fn event ->
              case projector_module.__handle_es__(projector_name, event, event.global_position) do
                {:ok, doc, id} ->
                  [%Snap.Bulk.Action.Index{id: id, doc: doc}]

                :skip ->
                  []

                {:error, reason} ->
                  Mix.raise(
                    "Handler error during rebuild at position #{event.global_position}: #{inspect(reason)}"
                  )
              end
            end)

          Mix.shell().info("Built #{length(stream)} ES documents for indexing.")

          # Step 2: Pause the live GenServer before hotswap (RBLD-03).
          # Pausing before the hotswap (not only during alias swap) guarantees
          # zero chance of a race between live writes and the index swap window.
          pid = GenServer.whereis(module)

          if pid do
            Mix.shell().info("Pausing live projector writes...")
            GenServer.call(pid, :pause_writes, 10_000)
          else
            Mix.shell().info("No live projector GenServer found — skipping pause.")
          end

          # Step 3: Run hotswap (create versioned index, bulk load, alias swap, cleanup).
          # Wrapped in try/after so resume_writes is always called — even on failure —
          # preventing an orphan paused GenServer (T-09-08 mitigation).
          try do
            Mix.shell().info("Running hotswap (create index → bulk load → alias swap)...")

            # Log only projector_name and index name — never credentials (T-09-05)
            Tracer.with_span "orkestra.es.rebuild",
              attributes: %{
                "orkestra.projector.name" => projector_name,
                "es.index" => index,
                "es.document_count" => length(stream)
              } do
              case Snap.Indexes.hotswap(stream, cluster, index, mapping,
                     page_size: 500,
                     page_wait: 0
                   ) do
                :ok ->
                  Mix.shell().info("Hotswap complete — alias swapped successfully.")

                  # Step 4: Reset Postgres checkpoint ONLY after successful hotswap
                  # (T-09-07 mitigation — checkpoint reset never precedes hotswap success).
                  Mix.shell().info("Resetting checkpoint...")

                  {:ok, _, _} =
                    Ecto.Migrator.with_repo(repo, fn r ->
                      r.delete_all(
                        from(c in Checkpoint, where: c.projector_name == ^projector_name)
                      )
                    end)

                  Mix.shell().info("Checkpoint reset.")

                {:error, reason} ->
                  Mix.raise("Hotswap failed: #{inspect(reason)}")
              end
            end
          after
            # Step 5: Always resume the live GenServer, even on hotswap failure.
            # Process.alive? check prevents calling a dead GenServer (T-09-08).
            if pid && Process.alive?(pid) do
              Mix.shell().info("Resuming live projector writes...")
              GenServer.call(pid, :resume_writes, 10_000)
              Mix.shell().info("Projector resumed — replaying from position 0.")
            end
          end

          Mix.shell().info(
            "Rebuild complete. #{projector_name} index alias has been swapped to the new index."
          )

        [] ->
          Mix.raise(
            "mix orkestra.projection.es.rebuild requires a projector module name\n\n" <>
              "Usage: mix orkestra.projection.es.rebuild MyApp.OrderESProjector"
          )
      end
    end

    # Collects all events from the EventStore by subscribing from position -1
    # and collecting pushed events until no more arrive within a 2-second timeout.
    # For InMemory, all events are delivered synchronously in subscribe_from_position,
    # so the first timeout triggers the exit. For EventStoreDB, events arrive
    # asynchronously and the timeout detects the end of the stream.
    defp collect_all_events(event_store) do
      {:ok, ref} = event_store.subscribe_from_position(:all, -1, self())

      events = collect_events_loop([])

      # Unsubscribe after collection to clean up the subscription (idempotent)
      if function_exported?(event_store, :unsubscribe, 1) do
        event_store.unsubscribe(ref)
      end

      events
    end

    # Drains events from the process mailbox.
    # Matches on map with global_position key (the stored_event shape from EventStore).
    defp collect_events_loop(acc) do
      receive do
        %{global_position: _} = event ->
          collect_events_loop(acc ++ [event])
      after
        2_000 ->
          Enum.sort_by(acc, & &1.global_position)
      end
    end
  end
end
