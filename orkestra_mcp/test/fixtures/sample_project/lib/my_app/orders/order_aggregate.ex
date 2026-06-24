defmodule MyApp.Orders.OrderAggregate do
  @behaviour Orkestra.Aggregate

  defstruct []

  @impl true
  def init_state, do: %__MODULE__{}

  @impl true
  def stream_id(command), do: command.params.order_id

  @impl true
  def decide(_state, _command), do: {:ok, []}

  @impl true
  def evolve(state, _event), do: state
end
