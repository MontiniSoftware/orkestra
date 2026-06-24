if Code.ensure_loaded?(Ecto.Schema) do
  defmodule Orkestra.Projection.SchemasTest do
    @moduledoc false

    use ExUnit.Case, async: true

    alias Orkestra.Projection.Checkpoint
    alias Orkestra.Projection.DeadLetter

    describe "Orkestra.Projection.Checkpoint schema" do
      test "maps to the projection_checkpoints table" do
        assert Checkpoint.__schema__(:source) == "projection_checkpoints"
      end

      test "has the ERR-03 persisted halt fields: halted, halted_at, last_position" do
        fields = Checkpoint.__schema__(:fields)
        assert :halted in fields
        assert :halted_at in fields
        assert :last_position in fields
      end

      test "last_position field type is :integer" do
        assert Checkpoint.__schema__(:type, :last_position) == :integer
      end

      test "halted field type is :boolean" do
        assert Checkpoint.__schema__(:type, :halted) == :boolean
      end

      test "halted_at field type is :utc_datetime_usec" do
        assert Checkpoint.__schema__(:type, :halted_at) == :utc_datetime_usec
      end

      test "projector_name field exists with type :string" do
        fields = Checkpoint.__schema__(:fields)
        assert :projector_name in fields
        assert Checkpoint.__schema__(:type, :projector_name) == :string
      end

      test "has an updated_at timestamp field" do
        fields = Checkpoint.__schema__(:fields)
        assert :updated_at in fields
      end

      test "primary key is a binary_id" do
        # __schema__(:primary_key) returns a list of PK field atoms, e.g. [:id]
        pk_fields = Checkpoint.__schema__(:primary_key)
        assert :id in pk_fields
        assert Checkpoint.__schema__(:type, :id) == :binary_id
      end
    end

    describe "Orkestra.Projection.DeadLetter schema" do
      test "maps to the projection_dead_letters table" do
        assert DeadLetter.__schema__(:source) == "projection_dead_letters"
      end

      test "has all six ERR-02 fields" do
        fields = DeadLetter.__schema__(:fields)
        assert :projector_name in fields
        assert :position in fields
        assert :event_data in fields
        assert :error in fields
        assert :attempts in fields
        assert :occurred_at in fields
      end

      test "position field type is :integer" do
        assert DeadLetter.__schema__(:type, :position) == :integer
      end

      test "event_data field type is :map (for jsonb storage)" do
        assert DeadLetter.__schema__(:type, :event_data) == :map
      end

      test "error field type is :string" do
        assert DeadLetter.__schema__(:type, :error) == :string
      end

      test "attempts field type is :integer" do
        assert DeadLetter.__schema__(:type, :attempts) == :integer
      end

      test "occurred_at field type is :utc_datetime_usec" do
        assert DeadLetter.__schema__(:type, :occurred_at) == :utc_datetime_usec
      end

      test "does not have an auto-managed inserted_at or updated_at timestamp" do
        fields = DeadLetter.__schema__(:fields)
        refute :inserted_at in fields
        refute :updated_at in fields
      end

      test "primary key is a binary_id" do
        # __schema__(:primary_key) returns a list of PK field atoms, e.g. [:id]
        pk_fields = DeadLetter.__schema__(:primary_key)
        assert :id in pk_fields
        assert DeadLetter.__schema__(:type, :id) == :binary_id
      end
    end
  end
end
