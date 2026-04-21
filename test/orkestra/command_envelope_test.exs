defmodule Orkestra.CommandEnvelopeTest do
  use ExUnit.Case, async: true

  alias Orkestra.CommandEnvelope

  defmodule DummyCmd do
    use Orkestra.Command
    param :name, :string, required: true
  end

  setup do
    {:ok, cmd} = DummyCmd.new(%{name: "test"})
    %{cmd: cmd}
  end

  describe "wrap/2" do
    test "creates an envelope with pending status", %{cmd: cmd} do
      env = CommandEnvelope.wrap(cmd)
      assert env.status == :pending
      assert env.command == cmd
      assert env.attempts == 0
      assert env.max_retries == 0
    end

    test "accepts max_retries option", %{cmd: cmd} do
      env = CommandEnvelope.wrap(cmd, max_retries: 3)
      assert env.max_retries == 3
    end
  end

  describe "lifecycle transitions" do
    test "pending → dispatched", %{cmd: cmd} do
      env = cmd |> CommandEnvelope.wrap() |> CommandEnvelope.mark_dispatched()
      assert env.status == :dispatched
      assert env.attempts == 1
      assert %DateTime{} = env.dispatched_at
    end

    test "dispatched → succeeded", %{cmd: cmd} do
      env =
        cmd
        |> CommandEnvelope.wrap()
        |> CommandEnvelope.mark_dispatched()
        |> CommandEnvelope.mark_succeeded(%{ok: true})

      assert env.status == :succeeded
      assert env.result == %{ok: true}
      assert %DateTime{} = env.completed_at
    end

    test "dispatched → failed", %{cmd: cmd} do
      env =
        cmd
        |> CommandEnvelope.wrap()
        |> CommandEnvelope.mark_dispatched()
        |> CommandEnvelope.mark_failed(:boom)

      assert env.status == :failed
      assert env.error == :boom
    end

    test "pending → rejected", %{cmd: cmd} do
      env =
        cmd
        |> CommandEnvelope.wrap()
        |> CommandEnvelope.mark_rejected(:unauthorized)

      assert env.status == :rejected
      assert env.error == :unauthorized
    end
  end

  describe "retryable?/1" do
    test "retryable when failed and attempts <= max_retries", %{cmd: cmd} do
      env =
        cmd
        |> CommandEnvelope.wrap(max_retries: 3)
        |> CommandEnvelope.mark_dispatched()
        |> CommandEnvelope.mark_failed(:oops)

      assert CommandEnvelope.retryable?(env)
    end

    test "not retryable when attempts exceed max_retries", %{cmd: cmd} do
      env =
        cmd
        |> CommandEnvelope.wrap(max_retries: 1)
        |> CommandEnvelope.mark_dispatched()
        |> CommandEnvelope.mark_dispatched()
        |> CommandEnvelope.mark_failed(:oops)

      refute CommandEnvelope.retryable?(env)
    end

    test "not retryable when succeeded", %{cmd: cmd} do
      env =
        cmd
        |> CommandEnvelope.wrap(max_retries: 3)
        |> CommandEnvelope.mark_dispatched()
        |> CommandEnvelope.mark_succeeded(:done)

      refute CommandEnvelope.retryable?(env)
    end

    test "not retryable with zero max_retries", %{cmd: cmd} do
      env =
        cmd
        |> CommandEnvelope.wrap(max_retries: 0)
        |> CommandEnvelope.mark_dispatched()
        |> CommandEnvelope.mark_failed(:oops)

      refute CommandEnvelope.retryable?(env)
    end
  end

  describe "middleware_context" do
    test "put and get context", %{cmd: cmd} do
      env =
        cmd
        |> CommandEnvelope.wrap()
        |> CommandEnvelope.put_context(:auth, %{user_id: "u1"})

      assert CommandEnvelope.get_context(env, :auth) == %{user_id: "u1"}
      assert CommandEnvelope.get_context(env, :missing, :default) == :default
    end
  end

  describe "accessors" do
    test "command_id, command_type, metadata", %{cmd: cmd} do
      env = CommandEnvelope.wrap(cmd)
      assert CommandEnvelope.command_id(env) == cmd.id
      assert CommandEnvelope.command_type(env) == cmd.type
      assert CommandEnvelope.metadata(env) == cmd.metadata
    end
  end
end
