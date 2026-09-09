defmodule Orkestra.Test.Fixtures do
  @moduledoc """
  Real `Orkestra.Event` / `Orkestra.Command` / `Orkestra.Aggregate` modules used
  by the EventStoreDB integration tests.

  Their whole point is to be **resolvable** modules with declared fields, so that
  `Orkestra.EventStore.EventStoreDB.to_stored_event/1` atomizes the JSON-decoded
  event `data` back to the field atoms — and the aggregate's `evolve/2` and the
  projector handler can read `event.data.field` via atoms exactly as a real host
  app does. A string-keyed `data` (the pre-fix adapter behaviour) makes those
  accesses raise `KeyError`, which is the bug these tests guard.
  """

  defmodule WorkspaceCreated do
    @moduledoc false
    use Orkestra.Event

    field(:workspace_id, :string, required: true)
    field(:name, :string, required: true)
  end

  defmodule MemberInvited do
    @moduledoc false
    use Orkestra.Event

    field(:workspace_id, :string, required: true)
    field(:member_id, :string, required: true)
  end

  defmodule CreateWorkspace do
    @moduledoc false
    use Orkestra.Command

    param(:workspace_id, :string, required: true)
    param(:name, :string, required: true)
  end

  defmodule InviteMember do
    @moduledoc false
    use Orkestra.Command

    param(:workspace_id, :string, required: true)
    param(:member_id, :string, required: true)
  end

  defmodule WorkspaceAggregate do
    @moduledoc false
    @behaviour Orkestra.Aggregate

    alias Orkestra.Test.Fixtures.{
      CreateWorkspace,
      InviteMember,
      MemberInvited,
      WorkspaceCreated
    }

    @impl true
    def init_state, do: %{status: :new, workspace_id: nil, members: []}

    @impl true
    def stream_id(command), do: "orkestra-agg-it-#{command.params.workspace_id}"

    # `evolve/2` reads `event.data.workspace_id` / `event.data.member_id` via
    # ATOM keys. On replay these events are reloaded from real EventStoreDB, so
    # this crashes with KeyError unless the adapter atomized the data keys.
    @impl true
    def evolve(state, %WorkspaceCreated{} = e) do
      %{state | status: :created, workspace_id: e.data.workspace_id}
    end

    def evolve(state, %MemberInvited{} = e) do
      %{state | members: [e.data.member_id | state.members]}
    end

    def evolve(state, _event), do: state

    @impl true
    def decide(%{status: :new}, %CreateWorkspace{} = cmd) do
      {:ok,
       [
         WorkspaceCreated.new!(%{
           workspace_id: cmd.params.workspace_id,
           name: cmd.params.name
         })
       ]}
    end

    def decide(%{status: :new}, %InviteMember{}), do: {:error, :workspace_not_created}

    # The second command depends on state folded from the PRIOR event that was
    # reloaded from EventStoreDB: it reuses `workspace_id` recovered by evolve.
    def decide(%{status: :created, workspace_id: workspace_id}, %InviteMember{} = cmd) do
      {:ok,
       [
         MemberInvited.new!(%{
           workspace_id: workspace_id,
           member_id: cmd.params.member_id
         })
       ]}
    end

    def decide(_state, _command), do: {:error, :invalid_command}

    @impl true
    def snapshot_every, do: :never
  end
end
