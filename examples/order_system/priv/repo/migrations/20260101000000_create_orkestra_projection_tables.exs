defmodule OrderSystem.Repo.Migrations.CreateOrkestraProjectionTables do
  use Ecto.Migration

  def up, do: Orkestra.Projection.Migration.up()
  def down, do: Orkestra.Projection.Migration.down()
end
