defmodule Orkestra.Test.ProjectionReadModel do
  @moduledoc false

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @timestamps_opts [type: :utc_datetime_usec]

  schema "projection_read_models" do
    field(:projector_name, :string)
    field(:position, :integer)
    field(:payload, :map, default: %{})
    timestamps()
  end

  @doc "Builds a changeset for inserting or updating a read-model row."
  @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
  def changeset(read_model, attrs) do
    read_model
    |> cast(attrs, [:projector_name, :position, :payload])
    |> validate_required([:projector_name, :position])
  end
end
