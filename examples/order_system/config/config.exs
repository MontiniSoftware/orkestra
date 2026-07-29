import Config

# --- Ecto Repos ---
config :order_system, ecto_repos: [OrderSystem.Repo]

# --- Message Bus ---
# Orkestra's PubSub bus reads its Phoenix.PubSub name from this config
config :orkestra, Orkestra.MessageBus.PubSub, pubsub: OrderSystem.PubSub

# Topic derivation: strip the app prefix from module names
config :orkestra, Orkestra.MessageBus, app_prefix: OrderSystem

# --- Event Store ---
# Using InMemory for this example (replace with EventStoreDB in production)

# --- PostgreSQL Repo ---
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

# --- Elasticsearch Schemas ---
# Registers ES schemas with their cluster so the `mix orkestra.es.*` lifecycle
# tasks (setup/status/migrate) can discover and provision the read-model indexes.
config :orkestra, :es_schemas, [{OrderSystem.Search.Order, OrderSystem.ESCluster}]

# --- Logger ---
config :logger, :console,
  format: "$time [$level] $message $metadata\n",
  metadata: [:orkestra, :projector_name, :event_type]
