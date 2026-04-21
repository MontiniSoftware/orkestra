defmodule Orkestra.CommandHandlerTest do
  use ExUnit.Case, async: false

  alias Orkestra.{CommandEnvelope, MessageBus}
  alias Orkestra.MessageBus.PubSub, as: Bus

  # ── Test command ────────────────────────────────────────────────

  defmodule CreateTask do
    use Orkestra.Command
    param :name, :string, required: true
  end

  # ── Test handlers ───────────────────────────────────────────────

  defmodule SuccessfulHandler do
    use Orkestra.CommandHandler,
      command: Orkestra.CommandHandlerTest.CreateTask

    @impl true
    def execute(command, _metadata) do
      send(Process.whereis(:cmd_test), {:executed, command.params})
      {:ok, %{id: "created"}}
    end
  end

  defmodule FailingHandler do
    use Orkestra.CommandHandler,
      command: Orkestra.CommandHandlerTest.CreateTask

    @impl true
    def execute(_command, _metadata) do
      {:error, :something_went_wrong}
    end
  end

  defmodule CrashingHandler do
    use Orkestra.CommandHandler,
      command: Orkestra.CommandHandlerTest.CreateTask

    @impl true
    def execute(_command, _metadata) do
      raise "handler explosion"
    end
  end

  # ── Setup ───────────────────────────────────────────────────────

  setup do
    start_supervised!({Bus, []})
    Process.register(self(), :cmd_test)
    :ok
  end

  defp wait_for_handler(topic, timeout \\ 2000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_wait_handler(topic, deadline)
  end

  defp do_wait_handler(topic, deadline) do
    if System.monotonic_time(:millisecond) > deadline do
      flunk("No handler registered for #{topic} in time")
    end

    state = GenServer.call(Bus, :state)

    if Map.has_key?(state.commands, topic) do
      :ok
    else
      Process.sleep(50)
      do_wait_handler(topic, deadline)
    end
  end

  describe "auto-subscription and dispatch" do
    test "handler subscribes and processes command" do
      start_supervised!(SuccessfulHandler)
      topic = MessageBus.topic_for(CreateTask)
      wait_for_handler(topic)

      {:ok, cmd} = CreateTask.new(%{name: "test task"}, actor_id: "u1")
      env = CommandEnvelope.wrap(cmd)

      assert :ok = Bus.dispatch(env)
      assert_receive {:executed, %{name: "test task"}}
    end
  end

  describe "error handling" do
    test "returns error from handler" do
      start_supervised!(FailingHandler)
      topic = MessageBus.topic_for(CreateTask)
      wait_for_handler(topic)

      {:ok, cmd} = CreateTask.new(%{name: "fail"})
      env = CommandEnvelope.wrap(cmd)

      assert {:error, :something_went_wrong} = Bus.dispatch(env)
    end

    test "catches handler crashes" do
      start_supervised!(CrashingHandler)
      topic = MessageBus.topic_for(CreateTask)
      wait_for_handler(topic)

      {:ok, cmd} = CreateTask.new(%{name: "crash"})
      env = CommandEnvelope.wrap(cmd)

      assert {:error, {:handler_crash, _}} = Bus.dispatch(env)
    end
  end

  describe "retry integration" do
    test "retries up to max_retries before dead-lettering" do
      Phoenix.PubSub.subscribe(Orkestra.PubSub, "orkestra:deadletter")

      start_supervised!(FailingHandler)
      topic = MessageBus.topic_for(CreateTask)
      wait_for_handler(topic)

      {:ok, cmd} = CreateTask.new(%{name: "retry-me"})
      env = CommandEnvelope.wrap(cmd, max_retries: 2)

      Bus.dispatch(env)

      assert_receive {:dead_letter, entry}
      assert entry.handler =~ "FailingHandler"
    end
  end
end
