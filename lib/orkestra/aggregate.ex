defmodule Orkestra.Aggregate do
  @moduledoc """
  Behaviour for functional event-sourced aggregates.

  An aggregate is a module with **pure functions only** — no GenServer, no state,
  no I/O. The imperative shell (`Aggregate.Root`) handles all side effects.

  ## Defining an aggregate

      defmodule MyApp.BankAccount do
        @behaviour Orkestra.Aggregate

        @impl true
        def init_state, do: %{status: :new, balance: 0}

        @impl true
        def stream_id(command), do: "bank_account-\#{command.params.account_id}"

        @impl true
        def evolve(state, %AccountOpened{} = e), do: %{state | status: :open, owner: e.data.owner}
        def evolve(state, %MoneyDeposited{} = e), do: %{state | balance: state.balance + e.data.amount}
        def evolve(state, _), do: state

        @impl true
        def decide(%{status: :new}, %OpenAccount{} = cmd) do
          {:ok, [AccountOpened.new!(%{account_id: cmd.params.account_id, owner: cmd.params.owner})]}
        end
        def decide(%{status: :open}, %Deposit{} = cmd) do
          {:ok, [MoneyDeposited.new!(%{amount: cmd.params.amount})]}
        end
        def decide(%{status: :new}, _), do: {:error, :account_not_opened}
      end

  ## Flow

      Command → stream_id(cmd) → load events → fold via evolve/2 → decide(state, cmd) → append events
  """

  @type state :: term()

  @doc "Returns the initial state for a brand-new aggregate."
  @callback init_state() :: state()

  @doc """
  Derives the event stream identifier from a command.
  E.g., `"bank_account-\#{cmd.params.account_id}"`
  """
  @callback stream_id(command :: Orkestra.Command.t()) :: String.t()

  @doc """
  Pure fold function. Given current state and one event, returns the next state.
  This is the left-fold that replays history.
  """
  @callback evolve(state(), event :: Orkestra.Event.t()) :: state()

  @doc """
  Pure decision function. Given current state and a command,
  returns either a list of new events to emit or an error.
  No I/O allowed.
  """
  @callback decide(state(), command :: Orkestra.Command.t()) ::
              {:ok, [Orkestra.Event.t()]} | {:error, term()}

  @doc """
  How many events between snapshots. Return `:never` to disable.
  Override this callback to enable snapshotting.
  """
  @callback snapshot_every() :: pos_integer() | :never

  @optional_callbacks [snapshot_every: 0]
end
