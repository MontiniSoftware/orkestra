defmodule OrderSystem.Projections.OrderReadModel do
  @moduledoc "Ecto schema for the orders read model in PostgreSQL."
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :string, autogenerate: false}
  schema "orders" do
    field(:product_name, :string)
    field(:quantity, :integer)
    field(:price, :float)
    field(:total, :float)
    field(:customer_email, :string)
    field(:status, :string, default: "placed")
    field(:cancelled_at, :utc_datetime_usec)
    field(:cancel_reason, :string)

    timestamps()
  end

  def changeset(order, attrs) do
    order
    |> cast(attrs, [
      :id,
      :product_name,
      :quantity,
      :price,
      :total,
      :customer_email,
      :status,
      :cancelled_at,
      :cancel_reason
    ])
    |> validate_required([
      :id,
      :product_name,
      :quantity,
      :price,
      :total,
      :customer_email,
      :status
    ])
  end
end
