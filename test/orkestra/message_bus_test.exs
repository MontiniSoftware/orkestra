defmodule Orkestra.MessageBusTest do
  use ExUnit.Case, async: true

  alias Orkestra.MessageBus

  describe "topic_for/1 without prefix" do
    test "converts module name to dot-separated topic" do
      assert MessageBus.topic_for(MyApp.Tasks.Commands.StartAssessment) ==
               "my_app.tasks.commands.start_assessment"
    end

    test "handles deeply nested modules" do
      assert MessageBus.topic_for(MyApp.Experts.Architect.Events.AssessmentCompleted) ==
               "my_app.experts.architect.events.assessment_completed"
    end

    test "handles single segment" do
      assert MessageBus.topic_for(Ping) == "ping"
    end
  end

  describe "topic_for/1 with app_prefix" do
    setup do
      original = Application.get_env(:orkestra, Orkestra.MessageBus, [])
      Application.put_env(:orkestra, Orkestra.MessageBus, Keyword.put(original, :app_prefix, MyApp))

      on_exit(fn ->
        Application.put_env(:orkestra, Orkestra.MessageBus, original)
      end)
    end

    test "strips configured prefix" do
      assert MessageBus.topic_for(MyApp.Tasks.Commands.StartAssessment) ==
               "tasks.commands.start_assessment"
    end

    test "leaves non-matching prefix intact" do
      assert MessageBus.topic_for(OtherApp.Orders.PlaceOrder) ==
               "other_app.orders.place_order"
    end

    test "handles single segment after prefix" do
      assert MessageBus.topic_for(MyApp.Ping) == "ping"
    end
  end
end
