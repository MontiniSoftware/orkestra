defmodule Orkestra.EventEnvelopeTest do
  use ExUnit.Case, async: true

  alias Orkestra.EventEnvelope

  defmodule DummyEvent do
    use Orkestra.Event
    field :value, :string, required: true
  end

  setup do
    {:ok, event} = DummyEvent.new(%{value: "test"})
    %{event: event}
  end

  describe "wrap/1" do
    test "creates envelope with pending status", %{event: event} do
      env = EventEnvelope.wrap(event)
      assert env.status == :pending
      assert env.event == event
      assert env.handlers == %{}
    end
  end

  describe "mark_published/1" do
    test "transitions to published", %{event: event} do
      env = event |> EventEnvelope.wrap() |> EventEnvelope.mark_published()
      assert env.status == :published
      assert %DateTime{} = env.published_at
    end
  end

  describe "handler tracking" do
    test "register handlers", %{event: event} do
      env =
        event
        |> EventEnvelope.wrap()
        |> EventEnvelope.register_handler("ReportGen")
        |> EventEnvelope.register_handler("Notify")

      assert env.handlers == %{"ReportGen" => :pending, "Notify" => :pending}
    end

    test "all handlers succeed → :handled", %{event: event} do
      env =
        event
        |> EventEnvelope.wrap()
        |> EventEnvelope.mark_published()
        |> EventEnvelope.register_handler("A")
        |> EventEnvelope.register_handler("B")
        |> EventEnvelope.mark_handler_succeeded("A")
        |> EventEnvelope.mark_handler_succeeded("B")

      assert env.status == :handled
      assert EventEnvelope.all_handled?(env)
    end

    test "one fails → :partially_handled", %{event: event} do
      env =
        event
        |> EventEnvelope.wrap()
        |> EventEnvelope.mark_published()
        |> EventEnvelope.register_handler("A")
        |> EventEnvelope.register_handler("B")
        |> EventEnvelope.mark_handler_succeeded("A")
        |> EventEnvelope.mark_handler_failed("B")

      assert env.status == :partially_handled
      assert EventEnvelope.all_handled?(env)
    end

    test "all fail → :failed", %{event: event} do
      env =
        event
        |> EventEnvelope.wrap()
        |> EventEnvelope.mark_published()
        |> EventEnvelope.register_handler("A")
        |> EventEnvelope.register_handler("B")
        |> EventEnvelope.mark_handler_failed("A")
        |> EventEnvelope.mark_handler_failed("B")

      assert env.status == :failed
      assert EventEnvelope.all_handled?(env)
    end

    test "skipped counts as handled", %{event: event} do
      env =
        event
        |> EventEnvelope.wrap()
        |> EventEnvelope.mark_published()
        |> EventEnvelope.register_handler("A")
        |> EventEnvelope.register_handler("B")
        |> EventEnvelope.mark_handler_succeeded("A")
        |> EventEnvelope.mark_handler_skipped("B")

      assert env.status == :handled
      assert EventEnvelope.all_handled?(env)
    end

    test "processing does not count as handled", %{event: event} do
      env =
        event
        |> EventEnvelope.wrap()
        |> EventEnvelope.mark_published()
        |> EventEnvelope.register_handler("A")
        |> EventEnvelope.mark_handler_processing("A")

      refute EventEnvelope.all_handled?(env)
    end

    test "no handlers → all_handled? is true", %{event: event} do
      env = EventEnvelope.wrap(event)
      assert EventEnvelope.all_handled?(env)
    end
  end

  describe "accessors" do
    test "event_id, event_type, metadata", %{event: event} do
      env = EventEnvelope.wrap(event)
      assert EventEnvelope.event_id(env) == event.id
      assert EventEnvelope.event_type(env) == event.type
      assert EventEnvelope.metadata(env) == event.metadata
    end
  end
end
