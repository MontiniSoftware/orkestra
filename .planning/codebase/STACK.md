# Technology Stack

**Analysis Date:** 2026-06-24

## Languages

**Primary:**
- Elixir 1.18+ - Core CQRS/ES library (`lib/orkestra/`) and MCP server/CLI (`orkestra_mcp/`)

**Secondary:**
- Node.js 22.0.0 - Development tooling only (not runtime dependency)

## Runtime

**Environment:**
- Erlang/OTP (compatible with Elixir 1.18, typically OTP 27+)

**Package Manager:**
- Mix (Elixir's package manager)
- Lockfile: `mix.lock` (orkestra), `orkestra_mcp/mix.lock` (MCP subproject)

## Frameworks

**Core:**
- Phoenix.PubSub 2.2.0 - In-process message bus for dev/test (single-node)

**Runtime Support:**
- Hermes.MCP 0.14.1 - MCP (Model Context Protocol) server framework for `orkestra_mcp/`

**Build/Dev:**
- ExDoc 0.40.1 - Documentation generation (dev-only, runtime: false)

## Key Dependencies

**Critical:**
- Jason 1.4.4 - JSON encoding/decoding for serialization across message bus and event store
- OpenTelemetry API 1.5.0 - Observability instrumentation (tracing spans, context propagation)

**Infrastructure:**
- AMQP 4.1.0 - Optional, RabbitMQ adapter for distributed message bus via amqp_client 4.2.1
- Spear 1.4.1 - Optional, EventStoreDB adapter via gRPC with event_store_db_gpb_protobufs 2.4.0
- OpenTelemetry Process Propagator 0.3.0 - Optional, trace context propagation across Erlang processes

**HTTP/Network:**
- Finch 0.21.0 - HTTP client for hermes_mcp
- Mint 1.7.1 - HTTP/2 transport layer
- Gun 2.2+ - Optional, alternative HTTP transport for hermes_mcp
- Connection 1.1.0 - Connection pooling for Spear

**Serialization & Protocol Buffers:**
- GPB 4.21.7 - Protocol buffer compiler for EventStoreDB gRPC communication
- HPAX 1.0.3 - HTTP/2 RFC-compliant priority encoding

**RabbitMQ Internals (transitive):**
- amqp_client 4.2.1 - RabbitMQ Erlang client
- rabbit_common 4.2.1 - RabbitMQ common libraries
- credentials_obfuscation 3.5.0 - RabbitMQ credential handling
- Ranch 2.2.0 - TCP/socket abstraction
- Recon 2.5.6 - RabbitMQ introspection
- Thoas 1.2.1 - JSON encoder (RabbitMQ dep)

**Telemetry:**
- Telemetry 1.4.1 - Metrics and events (used by hermes_mcp)

**MCP Internals:**
- Peri 0.6.2 - Schema/API introspection for hermes_mcp (with optional Ecto support)
- MIME 2.0.7 - HTTP content-type handling

## Configuration

**Environment:**
- Configuration via `config/config.exs` per Elixir environment (dev, test, prod)
- orkestra_mcp forces MCP stdio (clean stdout for protocol), routes logs to stderr at `:warning` level
- Optional runtime configuration for:
  - Message bus adapter (PubSub vs RabbitMQ)
  - Event store adapter (InMemory vs EventStoreDB)
  - Trace context propagation backend

**Build:**
- `mix.exs` for orkestra (library)
- `orkestra_mcp/mix.exs` for MCP server and CLI escript
- `.formatter.exs` for code formatting (covers `lib/`, `test/`, `config/`)

## Platform Requirements

**Development:**
- Elixir 1.18+ (required by both mix.exs files)
- Erlang/OTP 27+ (inferred from Elixir 1.18 compatibility)
- Optional: RabbitMQ 3.8+ for AMQP testing
- Optional: EventStoreDB 24+ for gRPC adapter testing
- Node.js 22.0.0 (dev tooling only)

**Production:**
- Erlang/OTP runtime
- Optional: RabbitMQ 3.8+ (for distributed deployments)
- Optional: EventStoreDB 24+ (for event persistence with optimistic concurrency)

---

*Stack analysis: 2026-06-24*
