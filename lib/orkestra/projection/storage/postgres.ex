if Code.ensure_loaded?(Ecto.Multi) do
  defmodule Orkestra.Projection.Storage.Postgres do
    @moduledoc """
    PostgreSQL storage adapter implementing `Orkestra.Projection.Storage`.

    ## write/4

    Returns an `Ecto.Multi.t()` fragment — a pure, composable data structure
    describing the read-model writes for a single event. The Projector GenServer
    (Plan 03) appends this fragment to its checkpoint upsert Multi before calling
    `Repo.transaction/1`, enabling the atomic co-write required by STORE-03.

    **The Repo is never referenced here.** It is injected by the calling GenServer
    at transaction time, so the adapter has no direct dependency on any specific
    `Ecto.Repo` module. This preserves the STORE-03 boundary: the GenServer owns
    the transaction; the adapter produces only a composable descriptor.

    ## Step Naming Convention

    All read-model steps in the Multi returned by `write/4` must use the
    `:read_model_` prefix (e.g. `:read_model_insert`, `:read_model_update`).
    This prevents name collisions when the GenServer appends the read-model Multi
    to its own checkpoint Multi using `Ecto.Multi.append/2`. The GenServer's
    reserved step names are `:checkpoint`, `:halted_checkpoint`, and
    `:dead_letter` — none of which start with `:read_model_`.

    This naming convention is a contract between the adapter and the GenServer.
    Consumers implementing the `:handler` option for `write/4` should follow the
    same prefix convention in their Multi step names.

    ## Evolution Note

    `write/4` currently takes a 3-arity `:handler` function injected by the
    caller (the per-projector DSL or test). The Phase 3 DSL will wire this
    automatically from the projector definition, eliminating the need to pass
    `:handler` explicitly at every call site. This is the planned Phase-2/3 seam.

    ## STORE-02 Compliance

    This adapter satisfies STORE-02 (Postgres read-model writes) by returning a
    composable `Ecto.Multi.t()` that integrates with the GenServer's checkpoint
    transaction. All writes go through Ecto parameterized queries / changesets —
    no raw string-built SQL (T-02-04).

    ## STORE-04 Compliance

    `reset/2` clears all read-model rows for a projector on the injected Repo,
    enabling rebuild from position 0.
    """

    @behaviour Orkestra.Projection.Storage

    import Ecto.Query, only: [from: 2]

    @impl true
    @spec write(
            Orkestra.Projection.Storage.projector_name(),
            Orkestra.Projection.Storage.event(),
            non_neg_integer(),
            Orkestra.Projection.Storage.opts()
          ) :: {:ok, Ecto.Multi.t()} | {:error, term()}
    @doc """
    Returns a composable `Ecto.Multi.t()` fragment for the read-model write.

    Requires a `:handler` option — a 3-arity function with signature:

        (projector_name :: String.t(), event :: map(), position :: non_neg_integer())
        -> {:ok, Ecto.Multi.t()} | {:error, term()}

    The handler must build a Multi whose step names all start with `:read_model_`
    to avoid clashing with the GenServer's reserved `:checkpoint`,
    `:halted_checkpoint`, and `:dead_letter` steps (see module doc).

    Returns `{:ok, multi}` on success or `{:error, reason}` if the handler
    returns an error.
    """
    def write(projector_name, event, position, opts) do
      handler = Keyword.fetch!(opts, :handler)

      case handler.(projector_name, event, position) do
        {:ok, multi} when is_struct(multi, Ecto.Multi) -> {:ok, multi}
        {:error, reason} -> {:error, reason}
      end
    end

    @impl true
    @spec reset(
            Orkestra.Projection.Storage.projector_name(),
            Orkestra.Projection.Storage.opts()
          ) :: :ok | {:error, term()}
    @doc """
    Deletes all read-model rows for `projector_name` on the injected Repo.

    Requires `:repo` (the `Ecto.Repo` module) and `:schema` (the Ecto schema
    module for the read-model table) as options. The `schema` module must have
    a `projector_name` field.

    Used during projector rebuild (STORE-04) to clear the read model before
    replaying the event stream from position 0.

    Returns `:ok` on success.
    """
    def reset(projector_name, opts) do
      repo = Keyword.fetch!(opts, :repo)
      schema = Keyword.fetch!(opts, :schema)

      repo.delete_all(from(s in schema, where: s.projector_name == ^projector_name))
      :ok
    end
  end
end
