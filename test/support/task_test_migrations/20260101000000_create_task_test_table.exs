defmodule TaskTestMigration do
  use Ecto.Migration

  def up do
    create table(:task_test_read_model, primary_key: false) do
      add(:id, :binary_id, primary_key: true)
      add(:projector_name, :string, null: false)
      add(:value, :string)
    end
  end

  def down do
    drop(table(:task_test_read_model))
  end
end
