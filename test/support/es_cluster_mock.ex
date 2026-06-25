if Code.ensure_loaded?(Snap.Cluster) do
  defmodule Orkestra.Test.ESCluster do
    @moduledoc false

    use Snap.Cluster, otp_app: :orkestra
  end
end

if Code.ensure_loaded?(Snap.HTTPClient) do
  Mox.defmock(Snap.MockHTTPClient, for: Snap.HTTPClient)
end
