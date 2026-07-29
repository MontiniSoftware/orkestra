if Code.ensure_loaded?(Snap.Cluster) do
  defmodule Orkestra.Test.ESCluster do
    @moduledoc false

    use Snap.Cluster, otp_app: :orkestra
  end

  # A lightweight HTTP adapter that:
  # - returns :skip from child_spec/1 (no process to supervise)
  # - delegates request/6 to Snap.MockHTTPClient (the Mox mock)
  #
  # This avoids the Mox inter-process ownership problem: Snap.Cluster.Supervisor
  # calls child_spec/1 in a spawned process that does not own the Mox mock.
  # By implementing child_spec/1 directly here (not via Mox), the supervisor
  # can start cleanly without needing Mox allowances.
  defmodule Orkestra.Test.ESHTTPAdapter do
    @moduledoc false

    @behaviour Snap.HTTPClient

    @impl Snap.HTTPClient
    def child_spec(_config), do: :skip

    @impl Snap.HTTPClient
    def request(cluster, method, url, headers, body, opts) do
      Snap.MockHTTPClient.request(cluster, method, url, headers, body, opts)
    end
  end
end

if Code.ensure_loaded?(Snap.HTTPClient) do
  Mox.defmock(Snap.MockHTTPClient, for: Snap.HTTPClient)
end
