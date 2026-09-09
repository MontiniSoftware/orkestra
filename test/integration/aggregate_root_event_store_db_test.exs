defmodule Orkestra.Aggregate.RootEventStoreDBIntegrationTest do
  @moduledoc """
  Acceptance test: `Orkestra.Aggregate.Root` driving a real aggregate against a
  *real* EventStoreDB (docker `eventstore/eventstore:24.10.0`, insecure, :2113).

  Proves the aggregate replay contract the connection-free tests cannot: a
  second command on an existing stream must **load + fold prior events from
  EventStoreDB** and depend on their data. Because `evolve/2` reads
  `event.data.workspace_id` via atom keys, this is exactly the host-app crash
  path — before the adapter normalized the JSON-decoded (string-keyed) `data`
  back to the event struct's field atoms, the fold raised
  `(KeyError) key :workspace_id not found` on the reloaded event.

  Tagged `:integration`; run with `mix test --only integration`.
  """

  use ExUnit.Case, async: false

  @moduletag :integration

  alias Orkestra.Aggregate.Root
  alias Orkestra.EventStore.EventStoreDB

  alias Orkestra.Test.Fixtures.{
    CreateWorkspace,
    InviteMember,
    MemberInvited,
    WorkspaceAggregate,
    WorkspaceCreated
  }

  @conn Orkestra.EventStore.EventStoreDB.Connection

  setup_all do
    start_supervised!(
      {Spear.Connection, name: @conn, connection_string: "esdb://localhost:2113?tls=false"}
    )

    wait_ready(@conn, 40)
    :ok
  end

  # Point Root's `EventStore.impl()` at the real EventStoreDB adapter for the
  # duration of each test, restoring the previous config afterwards.
  setup do
    prev = Application.get_env(:orkestra, Orkestra.EventStore, [])
    Application.put_env(:orkestra, Orkestra.EventStore, Keyword.put(prev, :adapter, EventStoreDB))
    on_exit(fn -> Application.put_env(:orkestra, Orkestra.EventStore, prev) end)

    {:ok, workspace_id: "it-#{Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)}"}
  end

  test "a second command reloads+folds the prior event from EventStoreDB and depends on it",
       %{workspace_id: workspace_id} do
    {:ok, create} = CreateWorkspace.new(%{workspace_id: workspace_id, name: "Acme"})

    # First write: the emitted event struct already carries atom-keyed data.
    assert {:ok, [%WorkspaceCreated{} = created], state1} =
             Root.execute(WorkspaceAggregate, create, publish: false)

    assert created.data.workspace_id == workspace_id
    assert state1.status == :created
    assert state1.workspace_id == workspace_id

    {:ok, invite} = InviteMember.new(%{workspace_id: workspace_id, member_id: "m-1"})

    # Second write: Root LOADS the WorkspaceCreated event back from real
    # EventStoreDB and folds it via evolve/2, which reads
    # `event.data.workspace_id` (atom). This is the path that crashed pre-fix.
    assert {:ok, [%MemberInvited{} = invited], state2} =
             Root.execute(WorkspaceAggregate, invite, publish: false)

    # decide/2 used the workspace_id recovered from the reloaded event's data.
    assert invited.data.workspace_id == workspace_id
    assert invited.data.member_id == "m-1"
    assert state2.status == :created
    assert state2.workspace_id == workspace_id
    assert "m-1" in state2.members
  end

  test "inviting before the workspace exists is rejected (empty-stream load path)",
       %{workspace_id: workspace_id} do
    {:ok, invite} = InviteMember.new(%{workspace_id: workspace_id, member_id: "m-9"})

    assert {:error, :workspace_not_created} =
             Root.execute(WorkspaceAggregate, invite, publish: false)
  end

  defp wait_ready(_conn, 0), do: flunk("EventStoreDB connection never became ready")

  defp wait_ready(conn, attempts) do
    probe = Spear.Event.new("ReadinessProbe", %{})

    case Spear.append([probe], conn, "orkestra-agg-it-readiness", expect: :any) do
      :ok ->
        :ok

      _ ->
        Process.sleep(250)
        wait_ready(conn, attempts - 1)
    end
  end
end
