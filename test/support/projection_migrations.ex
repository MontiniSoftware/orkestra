defmodule Orkestra.Test.ProjectionMigrations do
  @moduledoc """
  In-code migration that creates the example read-model table used by
  Postgres integration tests.

  Run programmatically via `Ecto.Migrator.run/4` with a tuple list:

      Ecto.Migrator.run(
        Orkestra.Test.ProjectionRepo,
        [{@version, Orkestra.Test.ProjectionMigrations}],
        :up,
        all: true
      )

  This migration is **not** a file under `priv/` and is never auto-discovered
  by `mix ecto.migrate`. It is intentionally isolated from the host application's
  migration history (MIG-01).

  ## Version

  The `@version` module attribute (#{1}) is the version integer used in the
  `Ecto.Migrator.run/4` tuple list, ensuring the isolated
  `migration_source` table records it unambiguously.
  """

  use Ecto.Migration

  @version 1

  @doc "Returns the migration version integer for use in programmatic `Ecto.Migrator.run/4` calls."
  @spec version() :: pos_integer()
  def version, do: @version

  @doc "Creates the `projection_read_models` table with a unique index on `[:projector_name, :position]`."
  @spec up() :: term()
  def up do
    create table(:projection_read_models, primary_key: false) do
      add(:id, :binary_id, primary_key: true)
      add(:projector_name, :string, null: false)
      add(:position, :integer, null: false)
      add(:payload, :map, default: %{})
      timestamps()
    end

    create(unique_index(:projection_read_models, [:projector_name, :position]))
  end

  @doc "Drops the `projection_read_models` table."
  @spec down() :: term()
  def down do
    drop(table(:projection_read_models))
  end
end
