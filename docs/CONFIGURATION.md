<!-- generated-by: gsd-doc-writer -->
# Configuration

This document covers all configuration options for the `orkestra` library and the `orkestra_mcp` MCP server.

---

## Table of Contents

- [Runtime Toolchain](#runtime-toolchain)
- [Orkestra Library — mix.exs](#orkestra-library--mixexs)
  - [Core Dependencies](#core-dependencies)
  - [Optional Dependencies](#optional-dependencies)
- [Adapter Selection]
(#adapter-selection)
  - [EventStore Adapter](#eventstore-adapter)
  - [MessageBus Adapter](#messagebus-adapter)
- [EventStore Adapter Configuration](#eventstore-adapter-configuration)
  - [InMemory Adapter](#inmemory-adapter)
  - [EventStoreDB Adapter](#eventstoredb-adapter)
- [MessageBus Adapter Configuration](#messagebus-adapter-configuration)
  - [PubSub Adapter](#pubsub-adapter)
  - [RabbitMQ Adapter](#rabbitmq-adapter)
- [Telemetry and Logging](#telemetry-and-logging)
- [orkestra_mcp — MCP Server](#orkestra_mcp--mcp-server)
  - [mix.exs Settings](#mixexs-settings)
  - [Application Config](#application-config)
  - [CLI Flag](#cli-flag)
- [MCP Client Registration (.mcp.json)](#mcp-client-registration-mcpjson)
- [Code Formatter](#code-formatter)

---

## Runtime Toolchain

The project pins tool versions via `.tool-versions` (managed by [asdf](https://asdf-vm.com/)):

| Tool   | Version |
|--------|---------|
| nodejs | 22.0.0  |

Elixir and Erlang versions are not pinned in `.tool-versions`; the project requires Elixir `~> 1.18` (declared in both `mix.exs` files).

---

## Orkestra Library — mix.exs

File: `mix.exs`

```
app:     :orkestra
version: "0.1.0"
elixir:  "~> 1.18"
```

### Core Dependencies

These are always included:

| Dependency | Version | Purpose |
|---|---|---|
| `jason` | `~> 1.2` | JSON encoding/decoding |
| `phoenix_pubsub` | `~> 2.0` | PubSub message bus adapter |
| `opentelemetry_api` | `~> 1.5` | Distributed tracing (spans, context) |

### Optional Dependencies

These are included only when you enable the corresponding adapter:

| Dependency | Version | When needed |
|---|---|---|
| `amqp` | `~> 4.1` | `MessageBus.RabbitMQ` adapter |
| `spear` | `~> 1.4` | `EventStore.EventStoreDB` adapter |
| `opentelemetry_process_propagator` | `~> 0.3` | Trace context propagation across AMQP messages |
| `snap` | `~> 0.2.0` | `Orkestra.ES` (standalone read models or projector backend) |
| `finch` | `~> 0.21.0` | HTTP transport for `snap` (optional; needed in some environments) |

Add the optional dep to your `mix.exs` `deps` list when you select the corresponding adapter.

---

## Adapter Selection

Orkestra resolves adapters at runtime from application config. Both adapters default to their in-process implementations so no config is required for development or test.

### EventStore Adapter

```elixir
# config/config.exs
config :ultimus, Orkestra.EventStore,
  adapter: Orkestra.EventStore.InMemory   # default
```

| Value | Description |
|---|---|
| `Orkestra.EventStore.InMemory` | Agent-backed, in-process. Default. No external services needed. |
| `Orkestra.EventStore.EventStoreDB` | gRPC client via Spear. Requires a running EventStoreDB instance. |

> **Note:** The application key is `:ultimus` (not `:orkestra`) for the EventStore config. This matches the `Application.get_env(:ultimus, Orkestra.EventStore, [])` call in `event_store.ex`.

### MessageBus Adapter

```elixir
# config/config.exs
config :orkestra, Orkestra.MessageBus,
  adapter: Orkestra.MessageBus.PubSub,   # default
  app_prefix: MyApp                       # optional — strips module prefix from topic names
```

| Value | Description |
|---|---|
| `Orkestra.MessageBus.PubSub` | In-process via Phoenix.PubSub. Default. Suitable for single-node and tests. |
| `Orkestra.MessageBus.RabbitMQ` | Distributed via RabbitMQ. Suitable for multi-node production deployments. |

The `app_prefix` option strips your application module prefix when deriving topic names. For example, with `app_prefix: MyApp`, the module `MyApp.Tasks.Commands.StartAssessment` becomes the topic `"tasks.commands.start_assessment"`.

---

## EventStore Adapter Configuration

### InMemory Adapter

No additional configuration is required. The `Orkestra.EventStore.InMemory` process must be started in your supervision tree:

```elixir
# In your Application.start/2
children = [
  Orkestra.EventStore.InMemory,
  # ...
]
```

To reset all stored events between tests:

```elixir
Orkestra.EventStore.InMemory.reset!()
```

### EventStoreDB Adapter

Requires the `spear` optional dependency and a running EventStoreDB instance.

```elixir
# config/config.exs (or config/runtime.exs for env-var driven setup)
config :ultimus, Orkestra.EventStore.EventStoreDB,
  connection_string: "esdb://localhost:2113?tls=false"
```

Add `Spear.Connection` to your supervision tree:

```elixir
children = [
  {Spear.Connection,
   name: Orkestra.EventStore.EventStoreDB.Connection,
   connection_string: Application.fetch_env!(:ultimus, Orkestra.EventStore.EventStoreDB)[:connection_string]},
  # ...
]
```

<!-- VERIFY: EventStoreDB connection string format and TLS/authentication options beyond the example shown in the source -->

---

## MessageBus Adapter Configuration

### PubSub Adapter

Requires a `Phoenix.PubSub` instance. Configure which PubSub name the adapter uses:

```elixir
config :orkestra, Orkestra.MessageBus.PubSub,
  pubsub: MyApp.PubSub   # default: Orkestra.PubSub
```

Start the adapter and your PubSub in your supervision tree:

```elixir
children = [
  {Phoenix.PubSub, name: MyApp.PubSub},
  Orkestra.MessageBus.PubSub,
  # ...
]
```

If `pubsub` is not configured, the adapter looks for `Orkestra.PubSub` by default.

**Dead letter behaviour:** Failed handlers (after retries are exhausted) broadcast to the `"orkestra:deadletter"` Phoenix.PubSub topic. Subscribe to that topic to capture dead-lettered messages.

### RabbitMQ Adapter

Requires the `amqp` optional dependency (and `opentelemetry_process_propagator` for trace propagation across nodes).

```elixir
config :orkestra, Orkestra.MessageBus.RabbitMQ,
  channel_provider: fn -> MyApp.RabbitMQ.Connection.channel() end
```

The `channel_provider` key is required. It must be a zero-arity function that returns `{:ok, channel}` or `{:error, reason}`.

Add the adapter to your supervision tree:

```elixir
children = [
  {Orkestra.MessageBus.RabbitMQ, []},
  # ...
]
```

**Exchange topology declared automatically at startup:**

| Exchange | Type | Purpose |
|---|---|---|
| `orkestra.commands` | topic, durable | Command dispatch (point-to-point) |
| `orkestra.events` | topic, durable | Event broadcast (fan-out per handler) |
| `orkestra.deadletter` | topic, durable | Dead-letter exchange for failed messages |

**Queue naming conventions:**

- Commands: `"orkestra.cmd.{topic}"` — shared queue, competing consumers
- Events: `"orkestra.evt.{topic}.{handler_name}"` — dedicated queue per handler

**Default retry behaviour:** 3 retries per message (`@default_max_retries 3`). After exhausting retries, messages are rejected to the DLX without requeue.

<!-- VERIFY: RabbitMQ connection URL and authentication configuration — the source delegates entirely to the caller-supplied channel_provider function, so connection string format depends on the AMQP library and your connection manager -->

---

## Telemetry and Logging

Orkestra uses `opentelemetry_api` for distributed tracing. No configuration is required beyond having an OpenTelemetry SDK installed in your application. The library emits spans for:

- `"orkestra.command.dispatch"` — command dispatch via PubSub
- `"orkestra.event.publish"` — event publish via PubSub
- `"orkestra.rabbitmq.publish"` — message publish via RabbitMQ
- `"orkestra.rabbitmq.consume"` — message consumption via RabbitMQ
- `"orkestra.retry"` — handler retry attempts

For structured logging, call `Orkestra.Telemetry.set_logger_metadata/1` at the start of handler execution to inject correlation ID, causation ID, actor info, and OTel trace/span IDs into Logger metadata.

<!-- VERIFY: If a specific OpenTelemetry SDK (e.g., opentelemetry) or exporter is required/recommended for production use -->

---

## Orkestra.ES — Elasticsearch/OpenSearch

Orkestra.ES builds read models on Elasticsearch/OpenSearch with declarative schemas, auto-generated repositories, and index lifecycle management. See [`docs/ELASTICSEARCH.md`](ELASTICSEARCH.md) for the complete guide.

### Dependencies

Add `snap` (the Elasticsearch HTTP client) and optionally `finch` (HTTP transport):

```elixir
def deps do
  [
    {:orkestra, "~> 0.1.0"},
    {:snap, "~> 0.2.0"},           # Required for ES
    {:finch, "~> 0.21.0"}          # Optional HTTP transport
  ]
end
```

### Schema Discovery and Lifecycle Tasks

Configure schemas for index lifecycle management (setup, status, migrate):

```elixir
# config/config.exs
config :orkestra, :es_schemas, [
  {MyApp.Search.Product, MyApp.ESCluster},
  {MyApp.Search.Article, MyApp.ESCluster}
]
```

The three mix tasks discover schemas from this config:

| Task | Purpose |
|------|---------|
| `mix orkestra.es.setup` | Create aliases and versioned indexes (idempotent) |
| `mix orkestra.es.status` | Show alias existence and drift status (read-only) |
| `mix orkestra.es.migrate` | Reconcile aliases with current schemas; zero-downtime reindex if drifted |

Options for all three tasks:
- `--schema MyApp.Search.Product` — only operate on a single schema
- `--culture :it` — only operate on a single culture (multi-culture schemas only)
- `--dry-run` — report actions without applying them (migrate only)

### Cluster Configuration

Define a `Snap.Cluster` module pointing to your Elasticsearch or OpenSearch instance:

```elixir
# lib/my_app/es_cluster.ex
defmodule MyApp.ESCluster do
  use Snap.Cluster,
    url: System.fetch_env!("ELASTICSEARCH_URL"),    # e.g., "http://localhost:9200"
    auth: Orkestra.ES.Auth.ApiKey,                  # or Snap.Auth.Basic
    api_key: System.fetch_env!("ELASTICSEARCH_API_KEY")
end

# In your app supervision tree
children = [
  {MyApp.ESCluster, []}
]
```

### Using Elasticsearch with Projections

A projector can use `Orkestra.ES.Schema` as the read-model backend:

```elixir
defmodule MyApp.OrderESProjector do
  use Orkestra.Projector,
    backend: :elasticsearch,
    repo: MyApp.OrderProjection.Repo,       # Checkpoint repo (Postgres)
    cluster: MyApp.ESCluster,
    schema: MyApp.Search.Order,             # ES read-model schema
    culture: :it,                           # For multi-culture schemas
    event_store: Orkestra.EventStore.InMemory

  project_es MyApp.Events.OrderPlaced, fn event, _position ->
    {:ok, %MyApp.Search.Order{
      order_id: event.data.order_id,
      status: "placed"
    }}
  end
end
```

For details, see the "Using with projections" section in [`docs/ELASTICSEARCH.md`](ELASTICSEARCH.md).

---

## orkestra_mcp — MCP Server

### mix.exs Settings

File: `orkestra_mcp/mix.exs`

```
app:     :orkestra_mcp
version: "0.1.0"
elixir:  "~> 1.18"
```

| Dependency | Version | Purpose |
|---|---|---|
| `hermes_mcp` | `~> 0.14` | MCP server framework (stdio transport) |
| `jason` | `~> 1.2` | JSON encoding/decoding |

The project also declares an escript with `main_module: OrkestraMcp.CLI`, producing a self-contained binary.

### Application Config

File: `orkestra_mcp/config/config.exs`

```elixir
# Logger: MCP stdio requires clean stdout — all log output goes to stderr
config :logger, :default_handler,
  config: %{type: :standard_error}

config :logger, level: :warning

# In test env: skip starting the MCP server process
if config_env() == :test do
  config :orkestra_mcp, start_server: false
end
```

The `:start_server` key controls whether `OrkestraMcp.Application` starts the `OrkestraMcp.Server` and `Hermes.Server.Registry` children. Defaults to `true` in all environments except test.

### CLI Flag

When running `orkestra_mcp` as an escript binary, pass `--project-dir` to set the target Orkestra project directory:

```bash
./orkestra_mcp --project-dir /path/to/your/project
```

If `--project-dir` is omitted, it defaults to the current working directory (`File.cwd!()`). The value is stored in application env under `{:orkestra_mcp, :project_dir}`.

---

## MCP Client Registration (.mcp.json)

The `.mcp.json` file at the project root registers the `orkestra_mcp` binary as an MCP server for MCP-compatible clients (such as Claude Desktop):

```json
{
  "mcpServers": {
    "orkestra": {
      "command": "/data/progetti/orkestra/orkestra_mcp/orkestra_mcp",
      "args": ["--project-dir", "/data/progetti/orkestra"]
    }
  }
}
```

**Fields:**

| Field | Description |
|---|---|
| `command` | Absolute path to the compiled `orkestra_mcp` escript binary |
| `args` | CLI arguments passed to the binary; `--project-dir` points to the Orkestra project to introspect |

Adjust `command` and `--project-dir` to match the actual paths on your machine. The paths shown in the committed `.mcp.json` are machine-specific and must be updated before use.

---

## Code Formatter

Both projects use the standard Mix formatter with the same input glob pattern.

Root project (`/.formatter.exs`):

```elixir
[
  inputs: ["{mix,.formatter}.exs", "{config,lib,test}/**/*.{ex,exs}"]
]
```

MCP server (`/orkestra_mcp/.formatter.exs`):

```elixir
[
  inputs: ["{mix,.formatter}.exs", "{config,lib,test}/**/*.{ex,exs}"]
]
```

Run the formatter with:

```bash
mix format
```
