<!-- generated-by: gsd-doc-writer -->
# Development Guide

This guide covers how to set up, build, and test both projects in the Orkestra repository: the `orkestra` core library and the `orkestra_mcp` escript sub-project.

## Repository Layout

```
orkestra/
├── lib/orkestra/          # Core CQRS/ES library source
├── test/orkestra/         # Core library tests
├── mix.exs                # Root Mix project (orkestra library)
├── mix.lock               # Root dependency lockfile
├── .formatter.exs         # Format config for root project
├── orkestra_mcp/          # MCP server sub-project (separate Mix project)
│   ├── lib/orkestra_mcp/  # MCP server source
│   ├── test/orkestra_mcp/ # MCP server tests
│   ├── mix.exs            # MCP Mix project
│   ├── mix.lock           # MCP dependency lockfile
│   └── .formatter.exs     # Format config for MCP project
└── .github/workflows/     # CI/CD pipelines
```

The two Mix projects are independent — they have separate dependency trees, lockfiles, and build artifacts. Commands must be run from the correct directory for each project.

## Prerequisites

- Elixir `~> 1.18`
- Erlang/OTP `27` (matched by CI)

The CI workflow uses `erlef/setup-beam` with OTP 27 and Elixir 1.18. Install these via [asdf](https://asdf-vm.com/), [mise](https://mise.jdx.dev/), or your system package manager.

## Local Setup

### 1. Clone the repository

```bash
git clone https://github.com/MontiniSoftware/orkestra.git
cd orkestra
```

### 2. Install dependencies for the core library

```bash
mix deps.get
```

### 3. Install dependencies for the MCP sub-project

```bash
cd orkestra_mcp
mix deps.get
cd ..
```

Dependencies for the two projects are fetched and stored independently. `orkestra_mcp/deps/` is separate from the root `deps/`.

## Build Commands

### Core library (`orkestra`)

Run from the repository root:

| Command | Description |
|---|---|
| `mix deps.get` | Fetch dependencies |
| `mix compile` | Compile the library |
| `mix compile --warnings-as-errors` | Compile, treating warnings as errors (matches CI) |
| `mix format` | Format all source files |
| `mix format --check-formatted` | Verify formatting without writing changes |
| `mix docs` | Generate ExDoc HTML documentation (dev only) |
| `mix hex.build` | Build the Hex package artifact |

### MCP sub-project (`orkestra_mcp`)

Run from the `orkestra_mcp/` directory:

| Command | Description |
|---|---|
| `mix deps.get` | Fetch dependencies |
| `mix compile` | Compile the MCP server |
| `mix compile --warnings-as-errors` | Compile, treating warnings as errors (matches CI) |
| `mix format` | Format all source files |
| `mix escript.build` | Build the `orkestra_mcp` escript binary |

The `mix escript.build` command produces an executable named `orkestra_mcp` in the `orkestra_mcp/` directory. The escript entry point is `OrkestraMcp.CLI`.

## Code Style

Both projects use `mix format` (the standard Elixir formatter). No third-party linting tools are configured.

### Root project formatter

Config file: `.formatter.exs`

```elixir
[
  inputs: ["{mix,.formatter}.exs", "{config,lib,test}/**/*.{ex,exs}"]
]
```

### MCP sub-project formatter

Config file: `orkestra_mcp/.formatter.exs`

```elixir
[
  inputs: ["{mix,.formatter}.exs", "{config,lib,test}/**/*.{ex,exs}"]
]
```

Run `mix format` before committing. CI does not currently run a format check step, but keeping code formatted makes diffs easier to review.

## Running Tests

### Core library tests

Run from the repository root:

```bash
mix test
```

Test files are located under `test/orkestra/` and follow the `*_test.exs` naming convention. The test helper is `test/test_helper.exs`.

### MCP sub-project tests

Run from the `orkestra_mcp/` directory:

```bash
cd orkestra_mcp
mix test
```

Test files are located under `orkestra_mcp/test/orkestra_mcp/`. The test helper is `orkestra_mcp/test/test_helper.exs`.

### Running with `MIX_ENV=test`

CI sets `MIX_ENV=test` explicitly for test jobs. For local runs this is the default when calling `mix test`, so no additional setup is needed.

## Building the MCP Escript

```bash
cd orkestra_mcp
mix deps.get
mix escript.build
```

This produces an `orkestra_mcp` executable in the `orkestra_mcp/` directory. Run it directly:

```bash
./orkestra_mcp
```

## CI Workflow

The CI workflow is defined in `.github/workflows/ci.yml`. It runs on every push and on pull requests targeting `main`.

### Jobs

| Job | Working Directory | Commands |
|---|---|---|
| `compile` | repo root | `mix deps.get`, `mix compile --warnings-as-errors` |
| `test` | repo root | `mix deps.get`, `mix test` |
| `compile_mcp` | `orkestra_mcp/` | `mix deps.get`, `mix compile --warnings-as-errors` |
| `test_mcp` | `orkestra_mcp/` | `mix deps.get`, `mix test` |

`test` depends on `compile`, and `test_mcp` depends on `compile_mcp`. The two pipelines are otherwise independent and run in parallel.

Dependencies are cached by `mix.lock` hash using `actions/cache@v4`:
- Root project: caches `deps/` and `_build/`
- MCP sub-project: caches `orkestra_mcp/deps/` and `orkestra_mcp/_build/`

### Release workflow

`.github/workflows/release.yml` is triggered manually via `workflow_dispatch`. It runs CI first, then builds and publishes the Hex package using `mix hex.build` and `mix hex.publish --yes`. A GitHub release is created automatically after a successful publish. It requires the `HEX_API_KEY` secret to be set in the repository.

## Branch Conventions

No branch naming convention is documented in the repository. The main branch is `main`.

## Next Steps

- See `docs/ARCHITECTURE.md` for a breakdown of module boundaries and design decisions.
- See `docs/CONFIGURATION.md` for environment variable and runtime configuration details.
