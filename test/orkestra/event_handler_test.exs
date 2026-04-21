defmodule Orkestra.EventHandlerTest do
  use ExUnit.Case, async: false

  alias Orkestra.{EventEnvelope, MessageBus}
  alias Orkestra.MessageBus.PubSub, as: Bus

  # ── Test events ─────────────────────────────────────────────────

  defmodule TaskCompleted do
    use Orkestra.Event
    field :task_id, :string, required: true
  end

  defmodule TaskFailed do
    use Orkestra.Event
    field :task_id, :string, required: true
    field :reason, :string, required: true
  end

  # ── Test handlers ───────────────────────────────────────────────

  defmodule SingleEventHandler do
    use Orkestra.EventHandler,
      event: Orkestra.EventHandlerTest.TaskCompleted

    @impl true
    def handle_event(event, _metadata) do
      send(Process.whereis(:evt_test), {:single, event.data})
      :ok
    end
  end

  defmodule MultiEventHandler do
    use Orkestra.EventHandler,
      events: [
        Orkestra.EventHandlerTest.TaskCompleted,
        Orkestra.EventHandlerTest.TaskFailed
      ]

    @impl true
    def handle_event(event, _metadata) do
      send(Process.whereis(:evt_test), {:multi, event.type, event.data})
      :ok
    end
  end

  defmodule WildcardHandler do
    use Orkestra.EventHandler,
      topic: "orkestra.event_handler_test.#"

    @impl true
    def handle_event(event, _metadata) do
      send(Process.whereis(:evt_test), {:wildcard, event.type})
      :ok
    end
  end

  defmodule FailingEventHandler do
    use Orkestra.EventHandler,
      event: Orkestra.EventHandlerTest.TaskCompleted,
      max_retries: 1

    @impl true
    def handle_event(_event, _metadata) do
      {:error, :event_processing_failed}
    end
  end

  defmodule CrashingEventHandler do
    use Orkestra.EventHandler,
      event: Orkestra.EventHandlerTest.TaskCompleted

    @impl true
    def handle_event(_event, _metadata) do
      raise "event handler boom"
    end
  end

  # ── Setup ───────────────────────────────────────────────────────

  setup do
    start_supervised!({Bus, []})
    Process.register(self(), :evt_test)
    :ok
  end

  describe "single event subscription" do
    test "handles the subscribed event" do
      start_supervised!(SingleEventHandler)
      Process.sleep(500)

      {:ok, event} = TaskCompleted.new(%{task_id: "t1"})
      env = EventEnvelope.wrap(event)

      assert :ok = Bus.publish(env)
      assert_receive {:single, %{task_id: "t1"}}
    end

    test "does not receive unsubscribed events" do
      start_supervised!(SingleEventHandler)
      Process.sleep(500)

      {:ok, event} = TaskFailed.new(%{task_id: "t2", reason: "oops"})
      env = EventEnvelope.wrap(event)

      Bus.publish(env)
      refute_receive {:single, _}, 100
    end
  end

  describe "multi event subscription" do
    test "handles all subscribed events" do
      start_supervised!(MultiEventHandler)
      Process.sleep(500)

      {:ok, completed} = TaskCompleted.new(%{task_id: "t1"})
      {:ok, failed} = TaskFailed.new(%{task_id: "t2", reason: "boom"})

      Bus.publish(EventEnvelope.wrap(completed))
      Bus.publish(EventEnvelope.wrap(failed))

      assert_receive {:multi, _, %{task_id: "t1"}}
      assert_receive {:multi, _, %{task_id: "t2", reason: "boom"}}
    end
  end

  describe "wildcard subscription" do
    test "receives events matching the pattern" do
      start_supervised!(WildcardHandler)
      Process.sleep(500)

      {:ok, event} = TaskCompleted.new(%{task_id: "t1"})
      Bus.publish(EventEnvelope.wrap(event))

      assert_receive {:wildcard, _}
    end
  end

  describe "error handling" do
    test "returns error from handler" do
      start_supervised!(FailingEventHandler)
      Process.sleep(500)

      {:ok, event} = TaskCompleted.new(%{task_id: "fail"})
      Bus.publish(EventEnvelope.wrap(event))

      # Should not crash — errors are handled internally
      Process.sleep(500)
    end

    test "catches handler crashes" do
      start_supervised!(CrashingEventHandler)
      Process.sleep(500)

      {:ok, event} = TaskCompleted.new(%{task_id: "crash"})
      Bus.publish(EventEnvelope.wrap(event))

      # Should not crash the bus
      Process.sleep(500)
    end

    test "dead-letters after max retries" do
      Phoenix.PubSub.subscribe(Orkestra.PubSub, "orkestra:deadletter")

      start_supervised!(FailingEventHandler)
      Process.sleep(500)

      {:ok, event} = TaskCompleted.new(%{task_id: "die"})
      Bus.publish(EventEnvelope.wrap(event))

      assert_receive {:dead_letter, entry}
      assert entry.handler =~ "FailingEventHandler"
    end
  end
end
