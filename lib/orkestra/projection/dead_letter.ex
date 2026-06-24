if Code.ensure_loaded?(Ecto.Schema) do
  defmodule Orkestra.Projection.DeadLetter do
    @moduledoc """
    Ecto schema for persisting parked (dead-lettered) events (ERR-02).

    When a projector exhausts its retry budget for a given event, that event is
    parked in the dead-letter store. This record captures all information needed
    to diagnose the failure and, in a future release (ERR-05), to resume processing.

    ## Fields

    - `:projector_name` — identifier of the halted projector.
    - `:position` — global monotonic integer position of the failing event (D-02).
    - `:event_data` — the full event payload as a Jason-serialisable map (stored as
      jsonb in PostgreSQL). Using JSON (not `:erlang.binary_to_term`) avoids unsafe
      atom deserialization (T-01-05).
    - `:error` — human-readable error description (e.g., `Exception.message/1` or
      `inspect(reason)`).
    - `:attempts` — number of times the event was attempted before being parked.
    - `:occurred_at` — timestamp when the event was parked; set explicitly by the
      caller (not auto-managed by a `timestamps` macro).

    ## Table

    `projection_dead_letters` — created by `Orkestra.Projection.Migration.up/0`.
    """

    use Ecto.Schema

    @primary_key {:id, :binary_id, autogenerate: true}

    schema "projection_dead_letters" do
      field(:projector_name, :string)
      field(:position, :integer)
      field(:event_data, :map)
      field(:error, :string)
      field(:attempts, :integer, default: 0)
      field(:occurred_at, :utc_datetime_usec)
    end
  end
end
