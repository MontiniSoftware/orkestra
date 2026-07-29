defmodule OrderSystem.Repo.Migrations.CreateOrdersReadModel do
  use Ecto.Migration

  def change do
    create table(:orders, primary_key: false) do
      add :id, :string, primary_key: true
      add :product_name, :string, null: false
      add :quantity, :integer, null: false
      add :price, :float, null: false
      add :total, :float, null: false
      add :customer_email, :string, null: false
      add :status, :string, null: false, default: "placed"
      add :cancelled_at, :utc_datetime_usec
      add :cancel_reason, :string

      timestamps()
    end

    create index(:orders, [:status])
    create index(:orders, [:customer_email])
  end
end
