defmodule Orkestra.EventTest do
  use ExUnit.Case, async: true

  defmodule TaskCompleted do
    use Orkestra.Event

    field :task_id, :string, required: true
    field :status, :string, required: true
    field :result, :map, default: %{}
    field :cost_usd, :float, default: 0.0
  end

  defmodule MinimalEvent do
    use Orkestra.Event

    field :message, :string, required: true
  end

  defmodule DummyCmd do
    use Orkestra.Command
    param :name, :string, required: true
  end

  describe "new/2" do
    test "creates an event with required fields" do
      assert {:ok, event} = TaskCompleted.new(%{task_id: "t1", status: "success"})
      assert event.data.task_id == "t1"
      assert event.data.status == "success"
      assert event.data.result == %{}
      assert event.data.cost_usd == 0.0
    end

    test "generates a unique id" do
      {:ok, e1} = MinimalEvent.new(%{message: "a"})
      {:ok, e2} = MinimalEvent.new(%{message: "b"})
      assert e1.id != e2.id
    end

    test "sets the type from module name" do
      {:ok, event} = MinimalEvent.new(%{message: "x"})
      assert event.type == "Orkestra.EventTest.MinimalEvent"
    end

    test "sets occurred_at" do
      {:ok, event} = MinimalEvent.new(%{message: "x"})
      assert %DateTime{} = event.occurred_at
    end

    test "attaches metadata" do
      {:ok, event} = MinimalEvent.new(%{message: "x"}, actor_id: "u1")
      assert event.metadata.actor_id == "u1"
    end

    test "overrides defaults" do
      {:ok, event} = TaskCompleted.new(%{task_id: "t1", status: "ok", cost_usd: 1.5})
      assert event.data.cost_usd == 1.5
    end

    test "accepts string keys" do
      {:ok, event} = MinimalEvent.new(%{"message" => "hello"})
      assert event.data.message == "hello"
    end

    test "fails on missing required fields" do
      assert {:error, {:missing_fields, [:task_id, :status]}} = TaskCompleted.new(%{})
    end

    test "fails on nil required field" do
      assert {:error, {:missing_fields, [:message]}} = MinimalEvent.new(%{message: nil})
    end
  end

  describe "new!/2" do
    test "returns event on success" do
      event = MinimalEvent.new!(%{message: "ok"})
      assert event.data.message == "ok"
    end

    test "raises on failure" do
      assert_raise RuntimeError, ~r/creation failed/, fn ->
        MinimalEvent.new!(%{})
      end
    end
  end

  describe "from_command/2" do
    test "preserves correlation_id and sets causation_id" do
      {:ok, cmd} = DummyCmd.new(%{name: "x"}, correlation_id: "corr-root")
      {:ok, event} = TaskCompleted.from_command(cmd, %{task_id: "t1", status: "ok"})

      assert event.metadata.correlation_id == "corr-root"
      assert event.metadata.causation_id == cmd.id
    end

    test "preserves actor from command" do
      {:ok, cmd} = DummyCmd.new(%{name: "x"}, actor_id: "u1", actor_type: :user)
      {:ok, event} = TaskCompleted.from_command(cmd, %{task_id: "t1", status: "ok"})

      assert event.metadata.actor_id == "u1"
      assert event.metadata.actor_type == :user
    end
  end

  describe "from_event/2" do
    test "chains causation through events" do
      {:ok, cmd} = DummyCmd.new(%{name: "x"}, correlation_id: "chain")
      {:ok, e1} = MinimalEvent.from_command(cmd, %{message: "first"})
      {:ok, e2} = MinimalEvent.from_event(e1, %{message: "second"})

      assert e2.metadata.correlation_id == "chain"
      assert e2.metadata.causation_id == e1.id
      assert e1.metadata.causation_id == cmd.id
    end
  end

  describe "field_definitions/0" do
    test "returns all field definitions" do
      defs = TaskCompleted.field_definitions()
      assert length(defs) == 4

      {name, type, opts} = Enum.find(defs, fn {n, _, _} -> n == :task_id end)
      assert name == :task_id
      assert type == :string
      assert opts[:required] == true
    end
  end
end
