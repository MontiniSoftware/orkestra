if Code.ensure_loaded?(Ecto.Migrator) do
  defmodule Mix.Tasks.Orkestra.Projection.Rebuild do
    @shortdoc "Rebuild an Orkestra projection from scratch"
    @moduledoc """
    Rebuilds a projection by stopping its GenServer, rolling back and
    re-running all migrations, resetting the checkpoint, and restarting
    the GenServer. The projector then replays the full event stream from
    position 0, transitioning to live automatically once caught up.

    Requires the projector to be running under `Orkestra.Projection.Supervisor`.
    If the projector uses a custom supervision tree, stop and restart it manually.

    ## Usage

        mix orkestra.projection.rebuild MyApp.OrderProjector

    ## Options

    - `--yes` - Skip confirmation prompt (for scripting/CI).
    - `--supervisor` - Supervisor name (default: `Orkestra.Projection.Supervisor`).

    ## Rebuild sequence

    1. Stop the projector GenServer via `Supervisor.terminate_child/2`.
    2. Roll back all projection migrations.
    3. Re-run all migrations.
    4. Delete checkpoint and dead-letter rows (projector starts from position 0).
    5. Restart the GenServer via `Supervisor.restart_child/2`.

    After restart, the GenServer subscribes from position -1 (no checkpoint)
    and replays all events in order, then transitions to live automatically
    (RBLD-02 — gap-free replay, no special rebuild path needed).
    """

    use Mix.Task

    import Ecto.Query, only: [from: 2]

    alias Orkestra.Projection.Checkpoint
    alias Orkestra.Projection.DeadLetter

    @impl Mix.Task
    def run(args) do
      {opts, positional, _} =
        OptionParser.parse(args, strict: [yes: :boolean, supervisor: :string])

      case positional do
        [projector_module_str | _] ->
          unless Keyword.get(opts, :yes, false) do
            Mix.shell().info(
              "This will DROP and RECREATE all tables for #{projector_module_str}."
            )

            unless Mix.shell().yes?("Continue?") do
              Mix.raise("Rebuild cancelled.")
            end
          end

          # app.start (not just app.config) because rebuild needs running
          # processes: supervisor, GenServer, and repo connections.
          Mix.Task.run("app.start")

          module = Module.concat([projector_module_str])
          config = module.__projection_config__()

          supervisor_name =
            case Keyword.get(opts, :supervisor) do
              nil -> Orkestra.Projection.Supervisor
              name -> String.to_existing_atom("Elixir.#{name}")
            end

          # Step 1: Stop the projector GenServer
          Mix.shell().info("Stopping #{config.projector_name}...")

          case Supervisor.terminate_child(supervisor_name, module) do
            :ok ->
              :ok

            {:error, :not_found} ->
              Mix.raise(
                "Projector #{config.projector_name} not found under #{inspect(supervisor_name)}. " <>
                  "Ensure it is started under Orkestra.Projection.Supervisor."
              )
          end

          # Step 2: Roll back all migrations
          Mix.shell().info("Rolling back migrations...")

          {:ok, _, _} =
            Ecto.Migrator.with_repo(config.repo, fn repo ->
              Ecto.Migrator.run(repo, config.migrations_path, :down,
                all: true,
                migration_source: config.migration_source
              )
            end)

          # Step 3: Re-run all migrations
          Mix.shell().info("Re-running migrations...")

          {:ok, _, _} =
            Ecto.Migrator.with_repo(config.repo, fn repo ->
              Ecto.Migrator.run(repo, config.migrations_path, :up,
                all: true,
                migration_source: config.migration_source
              )
            end)

          # Step 4: Reset checkpoint and dead-letter rows — projector will
          # start from position -1 (no checkpoint) and replay from position 0.
          Mix.shell().info("Resetting checkpoint...")

          {:ok, _, _} =
            Ecto.Migrator.with_repo(config.repo, fn repo ->
              repo.delete_all(
                from(c in Checkpoint, where: c.projector_name == ^config.projector_name)
              )

              repo.delete_all(
                from(d in DeadLetter, where: d.projector_name == ^config.projector_name)
              )
            end)

          # Step 5: Restart the GenServer — subscribes from -1, replays all
          # events sequentially, then transitions to live automatically (RBLD-02).
          Mix.shell().info("Restarting #{config.projector_name}...")

          case Supervisor.restart_child(supervisor_name, module) do
            {:ok, _pid} ->
              Mix.shell().info(
                "Rebuild complete. #{config.projector_name} is replaying from position 0."
              )

            {:error, reason} ->
              Mix.raise("Failed to restart #{config.projector_name}: #{inspect(reason)}")
          end

        [] ->
          Mix.raise(
            "mix orkestra.projection.rebuild requires a projector module name\n\n" <>
              "Usage: mix orkestra.projection.rebuild MyApp.OrderProjector"
          )
      end
    end
  end
end
