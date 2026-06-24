if Code.ensure_loaded?(Ecto.Migration) do
  defmodule Orkestra.Projection.Migration do
    @moduledoc """
    Creates and drops Orkestra's internal projection tables.

    This module follows the Oban-style library migration pattern: Orkestra
    defines the DDL internally, and the consuming application generates a
    thin wrapper migration that delegates to `up/0` and `down/0`.

    ## Usage

    Generate a migration in your application:

        mix ecto.gen.migration create_orkestra_projection_tables

    In the generated migration file, delegate to this module:

        defmodule MyApp.Repo.Migrations.CreateOrkestraProjectionTables do
          use Ecto.Migration

          def up, do: Orkestra.Projection.Migration.up()
          def down, do: Orkestra.Projection.Migration.down()
        end

    Then run:

        mix ecto.migrate

    ## Tables

    - `projection_checkpoints` — one row per projector; tracks `last_position` and
      halt status (`halted`, `halted_at`). Unique index on `projector_name`.
    - `projection_dead_letters` — one row per parked event; carries the six ERR-02
      fields. Indexed on `projector_name` and `(projector_name, position)`.
    """

    use Ecto.Migration

    # Note: `Ecto.Migration.create/2`/`drop/1` return migration instruction terms,
    # not `:ok` (the migrator ignores the return value), so these specs are
    # `term()` rather than `:: :ok` (IN-03). Also note `last_position` is declared
    # `:bigint` here while the `Checkpoint` schema field is `:integer` — this is the
    # correct Ecto mapping (`:bigint` is a column type, not an Ecto field type), so
    # do not "fix" the schema field to `:bigint`.
    @doc "Creates the `projection_checkpoints` and `projection_dead_letters` tables."
    @spec up() :: term()
    def up do
      create table(:projection_checkpoints, primary_key: false) do
        add(:id, :binary_id, primary_key: true)
        add(:projector_name, :string, null: false)
        add(:last_position, :bigint, default: -1, null: false)
        add(:halted, :boolean, default: false, null: false)
        add(:halted_at, :utc_datetime_usec)
        timestamps(inserted_at: false, updated_at: :updated_at)
      end

      create(unique_index(:projection_checkpoints, [:projector_name]))

      create table(:projection_dead_letters, primary_key: false) do
        add(:id, :binary_id, primary_key: true)
        add(:projector_name, :string, null: false)
        add(:position, :bigint, null: false)
        add(:event_data, :map, null: false)
        add(:error, :text, null: false)
        add(:attempts, :integer, default: 0, null: false)
        add(:occurred_at, :utc_datetime_usec, null: false)
      end

      create(index(:projection_dead_letters, [:projector_name]))
      create(index(:projection_dead_letters, [:projector_name, :position]))
    end

    @doc "Drops the `projection_dead_letters` and `projection_checkpoints` tables."
    @spec down() :: term()
    def down do
      drop(table(:projection_dead_letters))
      drop(table(:projection_checkpoints))
    end
  end
end
