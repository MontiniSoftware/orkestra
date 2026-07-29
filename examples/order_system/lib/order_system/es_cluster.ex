defmodule OrderSystem.ESCluster do
  @moduledoc """
  Snap cluster for Elasticsearch/OpenSearch connectivity.

  Manages a dedicated Finch HTTP pool for all ES operations.
  Configuration via `config :order_system, OrderSystem.ESCluster`.
  """
  use Snap.Cluster, otp_app: :order_system
end
