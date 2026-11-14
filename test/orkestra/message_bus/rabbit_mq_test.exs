defmodule Orkestra.MessageBus.RabbitMQTest do
  @moduledoc """
  `Orkestra.MessageBus.RabbitMQ` against a live RabbitMQ (tagged `:rabbitmq`,
  excluded by default):

      RABBITMQ_URL=amqp://guest:guest@localhost:5672 mix test --include rabbitmq
  """
  use ExUnit.Case, async: false

  alias Orkestra.EventEnvelope
  alias Orkestra.MessageBus.RabbitMQ, as: Bus

  @moduletag :rabbitmq

  @url System.get_env("RABBITMQ_URL", "amqp://guest:guest@localhost:5672")
  defmodule SomethingHappened do
    use Orkestra.Event
    field(:value, :string, required: true)
  end

  @topic Orkestra.MessageBus.topic_for(__MODULE__.SomethingHappened)

  defmodule OkHandler do
    @behaviour Orkestra.MessageBus.Handler

    @impl true
    def handle(%EventEnvelope{event: event}) do
      send(
        :persistent_term.get({Orkestra.MessageBus.RabbitMQTest, :test}),
        {:ok_handler, event.data.value}
      )

      :ok
    end
  end

  defmodule FailingHandler do
    @behaviour Orkestra.MessageBus.Handler

    @impl true
    def handle(%EventEnvelope{event: event}) do
      send(
        :persistent_term.get({Orkestra.MessageBus.RabbitMQTest, :test}),
        {:failing_handler, event.data.value}
      )

      {:error, :intentional_failure}
    end
  end

  setup do
    {:ok, conn} = AMQP.Connection.open(@url)
    {:ok, channel} = AMQP.Channel.open(conn)
    previous = Application.get_env(:orkestra, Bus)
    Application.put_env(:orkestra, Bus, channel_provider: fn -> {:ok, channel} end)
    :persistent_term.put({__MODULE__, :test}, self())

    on_exit(fn ->
      {:ok, conn} = AMQP.Connection.open(@url)
      {:ok, side} = AMQP.Channel.open(conn)

      for queue <- [queue(OkHandler), queue(FailingHandler)],
          do: AMQP.Queue.delete(side, queue)

      AMQP.Queue.purge(side, "orkestra.deadletter.queue")
      AMQP.Connection.close(conn)
      Application.put_env(:orkestra, Bus, previous || [])
      :persistent_term.erase({__MODULE__, :test})
    end)

    start_supervised!(Bus)
    on_exit(fn -> AMQP.Connection.close(conn) end)
    %{channel: channel}
  end

  test "an event reaches its handler" do
    :ok = Bus.subscribe_event(@topic, OkHandler)
    publish("uno")
    assert_receive {:ok_handler, "uno"}, 5_000
  end

  test "a failing handler gets the event max_retries + 1 times, then it is dead-lettered", %{
    channel: channel
  } do
    :ok = Bus.subscribe_event(@topic, FailingHandler, max_retries: 2)
    publish("due")

    for _attempt <- 1..3, do: assert_receive({:failing_handler, "due"}, 5_000)
    refute_receive {:failing_handler, "due"}, 2_000

    assert {:ok, %{message_count: 1}} =
             AMQP.Queue.declare(channel, "orkestra.deadletter.queue", durable: true)
  end

  test "a retry goes to the failing handler only, not to the topic's other subscribers" do
    :ok = Bus.subscribe_event(@topic, OkHandler)
    :ok = Bus.subscribe_event(@topic, FailingHandler, max_retries: 2)
    publish("tre")

    for _attempt <- 1..3, do: assert_receive({:failing_handler, "tre"}, 5_000)
    assert_received {:ok_handler, "tre"}
    refute_receive {:ok_handler, "tre"}, 1_000
  end

  defp publish(value) do
    :ok = Bus.publish(EventEnvelope.wrap(SomethingHappened.new!(%{value: value})))
  end

  defp queue(handler),
    do: "orkestra.evt.#{@topic}.#{handler |> Module.split() |> List.last() |> Macro.underscore()}"
end
