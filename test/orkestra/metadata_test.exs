defmodule Orkestra.MetadataTest do
  use ExUnit.Case, async: true

  alias Orkestra.Metadata

  describe "new/1" do
    test "generates a correlation_id" do
      meta = Metadata.new()
      assert is_binary(meta.correlation_id)
      assert String.length(meta.correlation_id) > 0
    end

    test "sets issued_at to now" do
      meta = Metadata.new()
      assert %DateTime{} = meta.issued_at
      assert DateTime.diff(DateTime.utc_now(), meta.issued_at) < 2
    end

    test "accepts actor_id and actor_type" do
      meta = Metadata.new(actor_id: "user_42", actor_type: :user, source: "web")
      assert meta.actor_id == "user_42"
      assert meta.actor_type == :user
      assert meta.source == "web"
    end

    test "defaults actor_type to :system" do
      meta = Metadata.new()
      assert meta.actor_type == :system
    end

    test "accepts an explicit correlation_id" do
      meta = Metadata.new(correlation_id: "my-corr-id")
      assert meta.correlation_id == "my-corr-id"
    end
  end

  describe "derive/2" do
    test "preserves correlation_id from parent" do
      parent = Metadata.new(correlation_id: "root-corr")
      child = Metadata.derive(parent, "cmd_123")

      assert child.correlation_id == "root-corr"
    end

    test "sets causation_id to the given id" do
      parent = Metadata.new()
      child = Metadata.derive(parent, "cause_abc")

      assert child.causation_id == "cause_abc"
    end

    test "preserves actor_id and actor_type" do
      parent = Metadata.new(actor_id: "u1", actor_type: :user, source: "api")
      child = Metadata.derive(parent, "x")

      assert child.actor_id == "u1"
      assert child.actor_type == :user
      assert child.source == "api"
    end

    test "sets a fresh issued_at" do
      parent = Metadata.new()
      Process.sleep(10)
      child = Metadata.derive(parent, "x")

      assert DateTime.compare(child.issued_at, parent.issued_at) in [:gt, :eq]
    end
  end
end
