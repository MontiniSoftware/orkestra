defmodule Orkestra.MessageBus.PubSubTest do
  use ExUnit.Case, async: false

  alias Orkestra.{CommandEnvelope, EventEnvelope, MessageBus}
  alias Orkestra.MessageBus.PubSub, as: Bus

  # ── Test commands & events ──────────────────────────────────────

  defmodule DoSomething do
    use Orkestra.Command
    param :value, :string, required: true
  end

  defmodule SomethingHappened do
    use Orkestra.Event
    field :value, :string, required: true
  end

  # ── Test handlers ───────────────────────────────────────────────

  defmodule SuccessHandler do
    @behaviour Orkestra.MessageBus.Handler

    @impl true
    def handle(envelope) do
      send(Process.whereis(:test_process), {:handled, envelope})
      :ok
    end
  end

  defmodule FailHandler do
    @behaviour Orkestra.MessageBus.Handler

    @impl true
    def handle(_envelope) do
      {:error, :intentional_failure}
    end
  end

  defmodule CrashHandler do
    @behaviour Orkestra.MessageBus.Handler

    @impl true
    def handle(_envelope) do
      raise "boom"
    end
  end

  defmodule CountingHandler do
    @behaviour Orkestra.MessageBus.Handler

    @impl true
    def handle(_envelope) do
      count = Process.get(:attempt_count, 0) + 1
      Process.put(:attempt_count, count)
      send(Process.whereis(:test_process), {:attempt, count})

      if count < 3 do
        {:error, :not_yet}
      else
        :ok
      end
    end
  end

  # ── Setup ───────────────────────────────────────────────────────

  setup do
    # Start a fresh PubSub bus for each test
    start_supervised!({Bus, []})
    Process.register(self(), :test_process)
    :ok
  end

  # ── Command tests ───────────────────────────────────────────────

  describe "dispatch/1 commands" do
    test "dispatches to registered handler" do
      topic = MessageBus.topic_for(DoSomething)
      Bus.subscribe_command(topic, SuccessHandler)

      {:ok, cmd} = DoSomething.new(%{value: "hello"})
      env = CommandEnvelope.wrap(cmd)

      assert :ok = Bus.dispatch(env)
      assert_receive {:handled, received_env}
      assert received_env.command.params.value == "hello"
    end

    test "returns error when no handler registered" do
      {:ok, cmd} = DoSomething.new(%{value: "orphan"})
      env = CommandEnvelope.wrap(cmd)

      assert {:error, {:no_handler, _}} = Bus.dispatch(env)
    end

    test "returns error when handler fails" do
      topic = MessageBus.topic_for(DoSomething)
      Bus.subscribe_command(topic, FailHandler)

      {:ok, cmd} = DoSomething.new(%{value: "fail"})
      env = CommandEnvelope.wrap(cmd)

      assert {:error, :intentional_failure} = Bus.dispatch(env)
    end

    test "catches handler exceptions" do
      topic = MessageBus.topic_for(DoSomething)
      Bus.subscribe_command(topic, CrashHandler)

      {:ok, cmd} = DoSomething.new(%{value: "crash"})
      env = CommandEnvelope.wrap(cmd)

      assert {:error, {:handler_exception, _}} = Bus.dispatch(env)
    end

    test "retries on failure up to max_retries" do
      topic = MessageBus.topic_for(DoSomething)
      Bus.subscribe_command(topic, CountingHandler)

      {:ok, cmd} = DoSomething.new(%{value: "retry"})
      env = CommandEnvelope.wrap(cmd, max_retries: 5)

      assert :ok = Bus.dispatch(env)

      # Should have received 3 attempts (fails at 1,2 then succeeds at 3)
      assert_receive {:attempt, 1}
      assert_receive {:attempt, 2}
      assert_receive {:attempt, 3}
    end
  end

  # ── Event tests ─────────────────────────────────────────────────

  describe "publish/1 events" do
    test "delivers to all registered handlers" do
      topic = MessageBus.topic_for(SomethingHappened)
      Bus.subscribe_event(topic, SuccessHandler)

      {:ok, event} = SomethingHappened.new(%{value: "broadcast"})
      env = EventEnvelope.wrap(event)

      assert :ok = Bus.publish(env)
      assert_receive {:handled, received_env}
      assert received_env.event.data.value == "broadcast"
    end

    test "delivers to wildcard subscribers" do
      topic = MessageBus.topic_for(SomethingHappened)
      # Wildcard: match on prefix with #
      prefix = topic |> String.split(".") |> Enum.take(3) |> Enum.join(".")
      Bus.subscribe_event("#{prefix}.#", SuccessHandler)

      # Also register on exact topic to verify both fire
      Bus.subscribe_event(topic, SuccessHandler)

      {:ok, event} = SomethingHappened.new(%{value: "wild"})
      env = EventEnvelope.wrap(event)

      assert :ok = Bus.publish(env)

      # Should receive from both exact and wildcard
      assert_receive {:handled, _}
      assert_receive {:handled, _}
    end
  end

  # ── Dead letter tests ───────────────────────────────────────────

  describe "dead letter" do
    test "sends to dead letter after exhausting retries" do
      Phoenix.PubSub.subscribe(Orkestra.PubSub, "orkestra:deadletter")

      topic = MessageBus.topic_for(DoSomething)
      Bus.subscribe_command(topic, FailHandler)

      {:ok, cmd} = DoSomething.new(%{value: "die"})
      env = CommandEnvelope.wrap(cmd, max_retries: 1)

      Bus.dispatch(env)

      assert_receive {:dead_letter, entry}
      assert entry.handler =~ "FailHandler"
    end
  end
end
