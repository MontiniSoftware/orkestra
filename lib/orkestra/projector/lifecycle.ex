defmodule Orkestra.Projector.Lifecycle do
  @moduledoc """
  Pure functions for projector error classification and retry decisions.

  No I/O, no process state, no GenServer. All functions return plain values
  and are safe to call from any context, including `async: true` ExUnit tests.

  The Phase 2 Projector GenServer calls these functions to decide:
  - How long to wait before the next retry (`next_delay/2`)
  - Whether to retry or park the failing event to dead-letter (`classify/2`)
  - Whether to halt the projector after exhausting retries (`should_halt?/2`)

  ## Configuration

  All three functions accept a `config` map (or use `@default_config`):

      %{
        max_retries: 5,
        backoff_base_ms: 500,
        backoff_cap_ms: 30_000
      }

  Per D-04 in CONTEXT.md, retry count and backoff are configurable per projector.
  D-05 mandates that this module is pure — no I/O.
  """

  import Bitwise, only: [bsl: 2]

  # Max bit-shift for exponential backoff. BEAM integers are arbitrary-precision,
  # so this is purely a defensive clamp: any reasonable config hits `backoff_cap_ms`
  # long before attempt 62, so the cap dominates well before this matters (IN-02,
  # RESEARCH.md Pitfall 5).
  @max_shift 62

  @type config :: %{
          max_retries: non_neg_integer(),
          backoff_base_ms: non_neg_integer(),
          backoff_cap_ms: non_neg_integer()
        }

  @default_config %{
    max_retries: 5,
    backoff_base_ms: 500,
    backoff_cap_ms: 30_000
  }

  @doc """
  Returns the backoff delay in milliseconds for the given `attempt` number (0-indexed).

  Uses integer exponential backoff: `base * 2^attempt`, capped at `backoff_cap_ms`.
  The shift amount is clamped to avoid integer overflow for large attempt values
  (BEAM integers are arbitrary-precision but the cap makes clamping a correctness signal,
  not an overflow guard — per RESEARCH.md Pitfall 5).

  ## Examples

      iex> Lifecycle.next_delay(0, %{backoff_base_ms: 500, backoff_cap_ms: 30_000, max_retries: 5})
      500

      iex> Lifecycle.next_delay(1, %{backoff_base_ms: 500, backoff_cap_ms: 30_000, max_retries: 5})
      1_000
  """
  @spec next_delay(non_neg_integer(), config()) :: non_neg_integer()
  def next_delay(attempt, config \\ @default_config) do
    base = config.backoff_base_ms
    cap = config.backoff_cap_ms
    # Clamp the shift to @max_shift to prevent unbounded BEAM integer growth for
    # large attempts. The cap will be hit long before that with any reasonable
    # config, so this guard is purely defensive (RESEARCH.md Pitfall 5).
    safe_shift = min(attempt, @max_shift)
    min(cap, base * bsl(1, safe_shift))
  end

  @doc """
  Returns `:retry` or `:park` based on the current attempt count vs `max_retries`.

  Returns `:retry` when `attempts < config.max_retries`, `:park` when exhausted
  (attempts >= max_retries). Mirrors the `attempts <= max_retries` model in
  `CommandEnvelope.retryable?/1` but uses strict `<` so the event parks exactly
  when retries are exhausted (D-04).

  ## Examples

      iex> Lifecycle.classify(4, %{max_retries: 5, backoff_base_ms: 500, backoff_cap_ms: 30_000})
      :retry

      iex> Lifecycle.classify(5, %{max_retries: 5, backoff_base_ms: 500, backoff_cap_ms: 30_000})
      :park
  """
  @spec classify(non_neg_integer(), config()) :: :retry | :park
  def classify(attempts, config \\ @default_config) do
    if attempts < config.max_retries, do: :retry, else: :park
  end

  @doc """
  Returns `true` when the projector should halt (attempts exhausted), `false` otherwise.

  The halt decision (ERR-03) is made when `attempts >= config.max_retries`. The
  Phase 2 GenServer calls this after parking the failing event to decide whether to
  stop the projector or continue processing.

  ## Examples

      iex> Lifecycle.should_halt?(5, %{max_retries: 5, backoff_base_ms: 500, backoff_cap_ms: 30_000})
      true

      iex> Lifecycle.should_halt?(4, %{max_retries: 5, backoff_base_ms: 500, backoff_cap_ms: 30_000})
      false
  """
  @spec should_halt?(non_neg_integer(), config()) :: boolean()
  def should_halt?(attempts, config \\ @default_config) do
    attempts >= config.max_retries
  end
end
