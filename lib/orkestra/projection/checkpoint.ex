if Code.ensure_loaded?(Ecto.Schema) do
  defmodule Orkestra.Projection.Checkpoint do
    @moduledoc """
    Ecto schema for persisting a projector's position and halt status.

    Each row tracks a single named projector's last successfully processed
    event position and whether the projector is currently halted due to a
    dead-lettered event (ERR-03).

    ## Fields

    - `:projector_name` — unique identifier for the projector (e.g., `"MyApp.OrderProjector"`)
    - `:last_position` — the global monotonic integer position of the last successfully
      applied event (D-02). Starts at `-1` (no events processed). Enables positional
      lag arithmetic: `head_position - last_position`.
    - `:halted` — `true` when the projector has exhausted retries and parked an event;
      the projector must not advance until the dead-letter entry is resolved (ERR-03).
    - `:halted_at` — timestamp of when the projector entered the halted state.
    - `:updated_at` — auto-managed timestamp of the last checkpoint update.

    ## Table

    `projection_checkpoints` — created by `Orkestra.Projection.Migration.up/0`.
    """

    use Ecto.Schema

    @primary_key {:id, :binary_id, autogenerate: true}
    @timestamps_opts [type: :utc_datetime_usec]

    schema "projection_checkpoints" do
      field(:projector_name, :string)
      field(:last_position, :integer, default: -1)
      field(:halted, :boolean, default: false)
      field(:halted_at, :utc_datetime_usec)
      timestamps(inserted_at: false, updated_at: :updated_at)
    end
  end
end
