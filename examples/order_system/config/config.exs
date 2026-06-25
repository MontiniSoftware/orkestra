import Config

# --- Message Bus ---
config :order_system, :message_bus, Orkestra.MessageBus.PubSub

# --- PubSub ---
config :order_system, OrderSystem.PubSub, name: OrderSystem.PubSub

config :orkestra, :pubsub,
  name: OrderSystem.PubSub,
  adapter: Phoenix.PubSub.PG2

# --- Event Store ---
config :order_system, :event_store, Orkestra.EventStore.InMemory

# --- PostgreSQL Repos ---
# Main repo (for projection checkpoints + dead letters + Postgres read model)
config :order_system, OrderSystem.Repo,
  database: "order_system_dev",
  username: "postgres",
  password: "postgres",
  hostname: System.get_env("POSTGRES_HOST", "localhost"),
  port: String.to_integer(System.get_env("POSTGRES_PORT", "5432")),
  pool_size: 10

# --- Elasticsearch Cluster ---
config :order_system, OrderSystem.ESCluster,
  url: System.get_env("ELASTICSEARCH_URL", "http://localhost:9200"),
  username: System.get_env("ELASTICSEARCH_USERNAME", "elastic"),
  password: System.get_env("ELASTICSEARCH_PASSWORD", "changeme")

# --- Logger ---
config :logger, :console,
  format: "$time [$level] $message $metadata\n",
  metadata: [:orkestra, :projector_name, :event_type]
