defmodule Orkestra.Projector.LifecycleTest do
  use ExUnit.Case, async: true

  alias Orkestra.Projector.Lifecycle

  describe "next_delay/2" do
    test "attempt 0 returns backoff_base_ms" do
      config = %{backoff_base_ms: 500, backoff_cap_ms: 30_000, max_retries: 5}
      assert Lifecycle.next_delay(0, config) == 500
    end

    test "attempt 1 returns backoff_base_ms * 2" do
      config = %{backoff_base_ms: 500, backoff_cap_ms: 30_000, max_retries: 5}
      assert Lifecycle.next_delay(1, config) == 1_000
    end

    test "attempt 2 returns backoff_base_ms * 4" do
      config = %{backoff_base_ms: 500, backoff_cap_ms: 30_000, max_retries: 5}
      assert Lifecycle.next_delay(2, config) == 2_000
    end

    test "caps at backoff_cap_ms for large attempt numbers" do
      config = %{backoff_base_ms: 500, backoff_cap_ms: 30_000, max_retries: 5}
      assert Lifecycle.next_delay(20, config) == 30_000
    end

    test "does not overflow for very large attempt numbers (> 62)" do
      config = %{backoff_base_ms: 500, backoff_cap_ms: 30_000, max_retries: 5}
      # attempt 100 would overflow without guard
      assert Lifecycle.next_delay(100, config) == 30_000
    end

    test "uses default config when called with arity 1" do
      # With default config (base 500ms), attempt 0 returns 500
      assert Lifecycle.next_delay(0) == 500
    end
  end

  describe "classify/2" do
    test "returns :retry when attempts is 0 and max_retries is 5" do
      config = %{max_retries: 5, backoff_base_ms: 500, backoff_cap_ms: 30_000}
      assert Lifecycle.classify(0, config) == :retry
    end

    test "returns :retry when attempts < max_retries" do
      config = %{max_retries: 5, backoff_base_ms: 500, backoff_cap_ms: 30_000}
      assert Lifecycle.classify(4, config) == :retry
    end

    test "returns :park when attempts == max_retries" do
      config = %{max_retries: 5, backoff_base_ms: 500, backoff_cap_ms: 30_000}
      assert Lifecycle.classify(5, config) == :park
    end

    test "returns :park when attempts > max_retries" do
      config = %{max_retries: 5, backoff_base_ms: 500, backoff_cap_ms: 30_000}
      assert Lifecycle.classify(6, config) == :park
    end

    test "uses default config when called with arity 1" do
      # With default max_retries 5, attempt 0 should be :retry
      assert Lifecycle.classify(0) == :retry
    end
  end

  describe "should_halt?/2" do
    test "returns false when attempts < max_retries" do
      config = %{max_retries: 5, backoff_base_ms: 500, backoff_cap_ms: 30_000}
      assert Lifecycle.should_halt?(4, config) == false
    end

    test "returns true when attempts == max_retries" do
      config = %{max_retries: 5, backoff_base_ms: 500, backoff_cap_ms: 30_000}
      assert Lifecycle.should_halt?(5, config) == true
    end

    test "returns true when attempts > max_retries" do
      config = %{max_retries: 5, backoff_base_ms: 500, backoff_cap_ms: 30_000}
      assert Lifecycle.should_halt?(10, config) == true
    end

    test "returns false when attempts is 0 and max_retries is positive" do
      config = %{max_retries: 5, backoff_base_ms: 500, backoff_cap_ms: 30_000}
      assert Lifecycle.should_halt?(0, config) == false
    end

    test "uses default config when called with arity 1" do
      # With default max_retries 5, attempt 0 should not halt
      assert Lifecycle.should_halt?(0) == false
    end
  end
end
