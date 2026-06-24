<!-- generated-by: gsd-doc-writer -->
# orkestra_mcp — MCP Server Reference

`orkestra_mcp` is a Model Context Protocol (MCP) server and CLI that gives AI assistants
first-class access to Orkestra CQRS/ES projects. It exposes tools for scaffolding new
domain modules, resources for introspecting an existing project's domain model, and prompts
carrying Orkestra conventions and guided workflows.

The server is built with [Hermes MCP](https://hex.pm/packages/hermes_mcp) and communicates
over standard I/O (`stdio` transport), making it compatible with any MCP-capable client
(Claude Desktop, Claude Code, etc.).

---

## Building and Running

### Prerequisites

- Elixir `~> 1.18`
- Mix (included with Elixir)

### Build the escript

From the `orkestra_mcp/` sub-directory:

```bash
cd orkestra_mcp
mix deps.get
mix escript.build
```

This produces a self-contained executable named `orkestra_mcp` in the `orkestra_mcp/`
directory.

### Run the server

```bash
./orkestra_mcp --project-dir /path/to/your/orkestra/project
```

| Flag | Required | Description |
|---|---|---|
| `--project-dir` | No | Absolute path to the Orkestra project to introspect and generate code into. Defaults to the current working directory if omitted. |

The server starts the OTP application, registers the Hermes server on `stdio`, and then
sleeps indefinitely, waiting for MCP client requests. It does not daemonise — run it as a
background process or let your MCP client manage its lifecycle.

---

## Registering with an MCP Client

Create a `.mcp.json` file at the root of the repository (or in `~/.claude/mcp.json` for
user-wide registration):

```json
{
  "mcpServers": {
    "orkestra": {
      "command": "/absolute/path/to/orkestra_mcp/orkestra_mcp",
      "args": ["--project-dir", "/absolute/path/to/your/orkestra/project"]
    }
  }
}
```

Both paths must be absolute. The `--project-dir` value tells the server which project's
`lib/` tree to scan for domain components and where to write generated files.

---

## Server Module

**`OrkestraMcp.Server`** (`orkestra_mcp/lib/orkestra_mcp/server.ex`)

Declares the Hermes server with the following identity:

| Field | Value |
|---|---|
| Server name | `orkestra-mcp` |
| Version | `0.1.0` |
| Capabilities | `tools`, `resources`, `prompts` |
| Transport | `stdio` (configured at startup in `OrkestraMcp.Application`) |

All tools, resources, and prompts are registered as `component/1` entries inside this
module. Adding a new component requires only a `component(MyModule)` line here; Hermes
handles routing automatically.

---

## Tools

Tools generate Elixir source files inside the target project. Each tool writes the generated
file to disk (creating intermediate directories as needed) and returns the full file path
plus the generated source in the response.

All tools read the target project directory from `Application.get_env(:orkestra_mcp, :project_dir)`,
which is set by the CLI flag at startup.

### `gen_command`

**Module:** `OrkestraMcp.Tools.GenCommand`
**Description:** Generate an Orkestra Command module with typed params.

| Parameter | Type | Required | Description |
|---|---|---|---|
| `module_name` | string | Yes | Fully-qualified module name, e.g. `MyApp.Orders.Commands.PlaceOrder` |
| `params` | string | Yes | JSON array of param objects: `[{"name":"product_id","type":"string","required":true}]` |

Param object keys: `name` (string), `type` (string), `required` (boolean, optional),
`default` (any, optional).

Supported types: `:string`, `:integer`, `:float`, `:boolean`, `:map`, `:list`.

**Example call:**

```json
{
  "module_name": "MyApp.Orders.Commands.PlaceOrder",
  "params": "[{\"name\":\"order_id\",\"type\":\"string\",\"required\":true},{\"name\":\"quantity\",\"type\":\"integer\",\"default\":1}]"
}
```

**Generated output (written to `lib/my_app/orders/commands/place_order.ex`):**

```elixir
defmodule MyApp.Orders.Commands.PlaceOrder do
  use Orkestra.Command

  param :order_id, :string, required: true
  param :quantity, :integer, default: 1
end
```

---

### `gen_event`

**Module:** `OrkestraMcp.Tools.GenEvent`
**Description:** Generate an Orkestra Event module with typed fields.

| Parameter | Type | Required | Description |
|---|---|---|---|
| `module_name` | string | Yes | Fully-qualified module name, e.g. `MyApp.Orders.Events.OrderPlaced` |
| `fields` | string | Yes | JSON array of field objects: `[{"name":"order_id","type":"string","required":true}]` |

Field object keys mirror param objects: `name`, `type`, `required` (optional), `default`
(optional).

**Example call:**

```json
{
  "module_name": "MyApp.Orders.Events.OrderPlaced",
  "fields": "[{\"name\":\"order_id\",\"type\":\"string\",\"required\":true}]"
}
```

---

### `gen_command_handler`

**Module:** `OrkestraMcp.Tools.GenCommandHandler`
**Description:** Generate an Orkestra CommandHandler module bound to a specific Command.

| Parameter | Type | Required | Description |
|---|---|---|---|
| `module_name` | string | Yes | Fully-qualified handler module name, e.g. `MyApp.Orders.Handlers.PlaceOrderHandler` |
| `command_module` | string | Yes | Fully-qualified command module name, e.g. `MyApp.Orders.Commands.PlaceOrder` |

**Generated output:**

```elixir
defmodule MyApp.Orders.Handlers.PlaceOrderHandler do
  use Orkestra.CommandHandler, command: MyApp.Orders.Commands.PlaceOrder

  @impl true
  def execute(command, _metadata) do
    # TODO: implement command handling logic
    :ok
  end
end
```

---

### `gen_event_handler`

**Module:** `OrkestraMcp.Tools.GenEventHandler`
**Description:** Generate an Orkestra EventHandler module with single-event, multi-event,
or topic subscription.

| Parameter | Type | Required | Description |
|---|---|---|---|
| `module_name` | string | Yes | Fully-qualified handler module name, e.g. `MyApp.Orders.Handlers.SendConfirmation` |
| `opts` | string | Yes | JSON object controlling the subscription mode (see below) |

**Subscription modes for the `opts` JSON object:**

| `mode` | Additional key | Example |
|---|---|---|
| `"single"` | `"event"` — one event module name | `{"mode":"single","event":"MyApp.Orders.Events.OrderPlaced"}` |
| `"multi"` | `"events"` — array of event module names | `{"mode":"multi","events":["MyApp.Events.A","MyApp.Events.B"]}` |
| `"topic"` | `"topic"` — wildcard topic string | `{"mode":"topic","topic":"orders.events.*"}` |

**Example call (single-event mode):**

```json
{
  "module_name": "MyApp.Orders.Handlers.SendConfirmation",
  "opts": "{\"mode\":\"single\",\"event\":\"MyApp.Orders.Events.OrderPlaced\"}"
}
```

---

### `gen_aggregate`

**Module:** `OrkestraMcp.Tools.GenAggregate`
**Description:** Generate an Orkestra Aggregate module with `decide`/`evolve` clauses.

| Parameter | Type | Required | Description |
|---|---|---|---|
| `module_name` | string | Yes | Fully-qualified aggregate module name, e.g. `MyApp.Orders.OrderAggregate` |
| `stream_id_field` | string | Yes | The command param used as the stream ID, e.g. `order_id` |
| `commands` | string | Yes | JSON array of command module name strings |
| `events` | string | Yes | JSON array of event module name strings |

Pattern-match clauses are generated for each supplied command (in `decide/2`) and each
event (in `evolve/2`). Passing empty arrays produces a single catch-all clause with a TODO
comment.

**Example call:**

```json
{
  "module_name": "MyApp.Orders.OrderAggregate",
  "stream_id_field": "order_id",
  "commands": "[\"MyApp.Orders.Commands.PlaceOrder\"]",
  "events": "[\"MyApp.Orders.Events.OrderPlaced\"]"
}
```

---

## Resources

Resources expose read-only introspection data about the target project's domain model.
All resources scan the `lib/` directory of the configured project, parsing source files
with `OrkestraMcp.Introspection`.

### `orkestra://commands`

**Module:** `OrkestraMcp.Resources.ListCommands`
**MIME type:** `application/json`
**Description:** Lists all modules using `use Orkestra.Command` found in the project.

Returns a JSON array. Each entry has `module` (string) and `params` (array of param objects
with `name`, `type`, and optionally `opts`).

---

### `orkestra://events`

**Module:** `OrkestraMcp.Resources.ListEvents`
**MIME type:** `application/json`
**Description:** Lists all modules using `use Orkestra.Event` found in the project.

Returns a JSON array. Each entry has `module` (string) and `fields` (array of field objects).

---

### `orkestra://aggregates`

**Module:** `OrkestraMcp.Resources.ListAggregates`
**MIME type:** `application/json`
**Description:** Lists all modules implementing `@behaviour Orkestra.Aggregate`.

Returns a JSON array of objects with a single `module` key.

---

### `orkestra://handlers`

**Module:** `OrkestraMcp.Resources.ListHandlers`
**MIME type:** `application/json`
**Description:** Lists all CommandHandler and EventHandler modules in the project.

Returns a JSON object with two keys:

- `command_handlers` — array of `{module, command}` entries
- `event_handlers` — array of `{module, event | events | topic}` entries (the subscription
  key present depends on how the handler was declared)

---

### `orkestra://domain-map`

**Module:** `OrkestraMcp.Resources.DomainMap`
**MIME type:** `text/plain`
**Description:** Cross-references commands, events, handlers, and aggregates into a
human-readable domain map.

Returns a plain-text report. Each command and event is listed with its associated handlers
indented beneath it. Aggregates are listed at the end. Example output:

```
MyApp.Orders.Commands.PlaceOrder (command)
  -> MyApp.Orders.Handlers.PlaceOrderHandler (command_handler)

MyApp.Orders.Events.OrderPlaced (event)
  -> MyApp.Orders.Handlers.SendConfirmation (event_handler)

MyApp.Orders.OrderAggregate (aggregate)
```

---

## Prompts

Prompts deliver reusable context to the AI model. They are fetched once and injected into
the conversation as a user message.

### `conventions`

**Module:** `OrkestraMcp.Prompts.Conventions`
**Parameters:** none
**Description:** Delivers the full Orkestra CQRS/ES conventions reference as a user message.

Covers: file layout by bounded context, command/event/handler/aggregate authoring rules,
metadata chain (`correlation_id`, `causation_id`), supervision tree setup, MessageBus
topic derivation, and EventStore configuration. Use this prompt at the start of any
Orkestra scaffolding session to prime the model with project conventions.

---

### `new_bounded_context`

**Module:** `OrkestraMcp.Prompts.NewBoundedContext`
**Description:** Delivers a step-by-step guided workflow for adding a new bounded context.

| Parameter | Type | Required | Description |
|---|---|---|---|
| `context_name` | string | Yes | Name of the bounded context, e.g. `Orders`, `Inventory`, `Billing` |
| `app_module` | string | Yes | Top-level application module, e.g. `MyApp` |

The generated workflow walks through 8 steps: create directory structure, define commands,
define events, create command handlers, create event handlers, optionally create an
aggregate, add handlers to the supervision tree, and verify with `mix compile` and the
`orkestra://domain-map` resource.

---

## Internal Helpers

### `OrkestraMcp.Introspection`

(`orkestra_mcp/lib/orkestra_mcp/introspection.ex`)

Scans the `lib/` directory of the target project and parses `.ex` files with regular
expressions to detect Orkestra components.

| Function | Returns |
|---|---|
| `discover/1` | `%{commands, events, command_handlers, event_handlers, aggregates}` |
| `build_domain_map/1` | Plain-text string cross-referencing all component types |

Detection strategy:

- **Commands** — files containing `use Orkestra.Command`; params extracted via `param` macro calls
- **Events** — files containing `use Orkestra.Event`; fields extracted via `field` macro calls
- **CommandHandlers** — files with `use Orkestra.CommandHandler, command: ModuleName`
- **EventHandlers** — files with `use Orkestra.EventHandler` plus one of `event:`, `events:`, or `topic:`
- **Aggregates** — files with `@behaviour Orkestra.Aggregate`

---

### `OrkestraMcp.Generator`

(`orkestra_mcp/lib/orkestra_mcp/generator.ex`)

Produces Elixir source code strings and their corresponding file paths. All functions
return `{source_code, file_path}`.

| Function | Purpose |
|---|---|
| `gen_command/2` | Renders a `use Orkestra.Command` module with `param` declarations |
| `gen_event/2` | Renders a `use Orkestra.Event` module with `field` declarations |
| `gen_command_handler/2` | Renders a `use Orkestra.CommandHandler` module |
| `gen_event_handler/2` | Renders a `use Orkestra.EventHandler` module with mode-aware subscription |
| `gen_aggregate/4` | Renders a full `@behaviour Orkestra.Aggregate` module with pattern-match clauses |
| `write!/3` | Writes source to `project_dir/file_path`, creating parent directories as needed |

---

### `OrkestraMcp.Naming`

(`orkestra_mcp/lib/orkestra_mcp/naming.ex`)

Utility functions for converting between Elixir module names and file paths.

| Function | Example input | Example output |
|---|---|---|
| `module_to_file_path/1` | `"MyApp.Orders.Commands.PlaceOrder"` | `"lib/my_app/orders/commands/place_order.ex"` |
| `infer_app_module/1` | `"/path/to/project"` | `{:ok, "MyApp"}` |

`infer_app_module/1` reads `mix.exs` and extracts the application module name from the
`defmodule ... MixProject` declaration. Returns `{:error, :no_mix_project}` if `mix.exs`
is not found.
