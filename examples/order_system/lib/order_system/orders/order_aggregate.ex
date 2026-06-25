defmodule OrderSystem.Orders.OrderAggregate do
  @moduledoc """
  Pure aggregate for the Order domain.

  Implements the CQRS/ES pattern:
  - `decide/2` — validates commands against current state, returns events
  - `evolve/2` — folds events into state (pure, no I/O)
  """
  @behaviour Orkestra.Aggregate

  alias OrderSystem.Orders.Events.{OrderPlaced, OrderCancelled}

  @place_order_type "OrderSystem.Orders.Commands.PlaceOrder"
  @cancel_order_type "OrderSystem.Orders.Commands.CancelOrder"
  @order_placed_type "OrderSystem.Orders.Events.OrderPlaced"
  @order_cancelled_type "OrderSystem.Orders.Events.OrderCancelled"

  defstruct [:order_id, :status, :product_name, :quantity, :price, :total]

  @impl true
  def init_state, do: %__MODULE__{}

  @impl true
  def stream_id(command), do: "order-#{command.params.order_id}"

  # --- Decide ---

  @impl true
  def decide(%__MODULE__{status: nil}, %{type: @place_order_type} = command) do
    total = command.params.quantity * command.params.price

    event =
      OrderPlaced.new!(%{
        order_id: command.params.order_id,
        product_name: command.params.product_name,
        quantity: command.params.quantity,
        price: command.params.price,
        customer_email: command.params.customer_email,
        total: total
      })

    {:ok, [event]}
  end

  def decide(%__MODULE__{status: :placed}, %{type: @cancel_order_type} = command) do
    event =
      OrderCancelled.new!(%{
        order_id: command.params.order_id,
        reason: command.params.reason,
        cancelled_at: DateTime.utc_now() |> DateTime.to_iso8601()
      })

    {:ok, [event]}
  end

  def decide(%__MODULE__{status: nil}, %{type: @cancel_order_type}) do
    {:error, :order_not_found}
  end

  def decide(%__MODULE__{status: :cancelled}, _command) do
    {:error, :order_already_cancelled}
  end

  def decide(%__MODULE__{status: :placed}, %{type: @place_order_type}) do
    {:error, :order_already_exists}
  end

  # --- Evolve ---

  @impl true
  def evolve(%__MODULE__{} = state, %{type: @order_placed_type} = event) do
    %__MODULE__{
      state
      | order_id: event.data.order_id,
        status: :placed,
        product_name: event.data.product_name,
        quantity: event.data.quantity,
        price: event.data.price,
        total: event.data.total
    }
  end

  def evolve(%__MODULE__{} = state, %{type: @order_cancelled_type}) do
    %__MODULE__{state | status: :cancelled}
  end

  def evolve(state, _event), do: state
end
