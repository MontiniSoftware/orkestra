defmodule Orkestra.Projection.Supervisor do
  @moduledoc """
  Supervisor for Orkestra projectors.

  Starts all configured projectors under a `one_for_one` strategy, ensuring
  that one projector crashing or halting does not affect others. Each projector
  runs as an independent `Orkestra.Projector.GenServer` process.

  Halted projectors (those that have exhausted retries after an error) stay
  alive in an idle state — they do not crash or stop — so the `one_for_one`
  supervisor never sees them as failed children. This prevents restart storms
  (T-03-03).

  ## Usage

  Add to your application's supervision tree:

      children = [
        MyApp.OrderProjection.Repo,
        {Orkestra.Projection.Supervisor, projectors: [
          MyApp.OrderProjector,
          {MyApp.CustomerProjector, repo: MyApp.CustomerProjection.TestRepo}
        ]}
      ]

      Supervisor.start_link(children, strategy: :one_for_one)

  ## Options

  - `:projectors` (required) — list of projector modules or `{module, opts}`
    tuples. Bare modules use their compile-time defaults; tuple form allows
    runtime overrides (e.g., a different repo for test vs. prod).
  - `:name` — registered name for the supervisor process. Defaults to
    `Orkestra.Projection.Supervisor`.
  """

  use Supervisor

  @doc """
  Starts the projection supervisor linked to the calling process.

  Requires a `:projectors` key in `opts`. Accepts an optional `:name` key to
  register the supervisor process.
  """
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts) do
    projectors = Keyword.fetch!(opts, :projectors)
    name = Keyword.get(opts, :name, __MODULE__)
    Supervisor.start_link(__MODULE__, projectors, name: name)
  end

  @impl true
  def init(projectors) do
    children =
      Enum.map(projectors, fn
        {module, override_opts} -> module.child_spec(override_opts)
        module -> module.child_spec([])
      end)

    Supervisor.init(children, strategy: :one_for_one)
  end
end
