defmodule Orkestra.Projection.Storage do
  @moduledoc """
  Behaviour for pluggable read-model storage adapters.

  ## write/4

  Returns an opaque `ops` term describing the write operations for applying a
  single event to the read model. The `ops` value is a **data structure**, never
  a Repo-bound closure — the caller (Phase 2 Projector GenServer) decides when
  and how to commit the operations.

  The Postgres adapter (Phase 2) returns a composable transaction data structure
  that the Projector GenServer merges with the checkpoint update before executing
  the transaction, enabling the atomic co-write required by STORE-03. Future
  Mongo/Elasticsearch adapters return their own idiomatic write descriptor.

  Do not return a function or closure from `write/4` — that would bind the Repo
  at call time, preventing the caller from choosing the transaction boundary.

  ## reset/2

  Clears all read-model state for a given projector. Used during projector rebuild
  (later phases). After `reset/2`, a subsequent `write/4` for each event should
  reconstruct the read model from scratch.
  """

  @typedoc "The unique name identifying a projector."
  @type projector_name :: String.t()

  @typedoc "A domain event map, typically a `stored_event()` from the EventStore."
  @type event :: map()

  @typedoc "Options passed through to the adapter module."
  @type opts :: keyword()

  @typedoc """
  An opaque write-operations descriptor returned by `write/4`.

  The concrete type is adapter-defined:
  - Postgres adapter: a composable transaction data structure (Phase 2, STORE-03)
  - Mongo adapter: adapter-specific write description
  - Elasticsearch adapter: adapter-specific write description

  This type is `term()` by design — the behaviour itself has no dependency on
  any specific database library, keeping it adapter-agnostic.
  """
  @type ops :: term()

  @doc """
  Returns write operations for applying `event` at `position` to the read model
  for `projector_name`.

  The `position` argument is the event's global monotonic position (D-01), which
  the Postgres adapter co-writes with the checkpoint to enable STORE-03's atomic
  read-model + checkpoint update.

  Returns `{:ok, ops}` on success, where `ops` is an adapter-specific data
  structure describing the writes to perform. Must be a data structure — never a
  Repo-bound closure or function (see module doc).

  Returns `{:error, reason}` if the adapter cannot produce write operations for
  the event (e.g. unrecognised event type or schema mismatch).
  """
  @callback write(projector_name(), event(), non_neg_integer(), opts()) ::
              {:ok, ops()} | {:error, term()}

  @doc """
  Resets all read-model state for `projector_name`.

  Clears every row/document in the read-model table(s) managed by this adapter
  for the given projector. Used by the rebuild mechanism (Phase 3+) before
  replaying the event stream from position 0.

  Returns `:ok` on success or `{:error, reason}` on failure.
  """
  @callback reset(projector_name(), opts()) :: :ok | {:error, term()}
end
