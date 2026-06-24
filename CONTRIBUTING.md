<!-- generated-by: gsd-doc-writer -->
# Contributing to Orkestra

Thank you for your interest in contributing to Orkestra. This document covers what you need to know
to get your changes merged.

## Development setup

See [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md) for the full local setup guide and available Mix
commands. See [docs/GETTING-STARTED.md](docs/GETTING-STARTED.md) for prerequisites and first-run
instructions.

The short version:

```bash
git clone https://github.com/MontiniSoftware/orkestra.git
cd orkestra
mix deps.get
```

**Runtime requirements:**

- Elixir `~> 1.18`
- Erlang/OTP `27`

The `.tool-versions` file in the repository root currently pins only Node.js (`22.0.0`); it does
not contain Elixir or Erlang/OTP entries. Install Elixir `~> 1.18` (and a matching Erlang/OTP
release) separately using your version manager of choice — [asdf](https://asdf-vm.com/) with the
`asdf-elixir` and `asdf-erlang` plugins is one option. The required Elixir version is declared in
`mix.exs` (`elixir: ~> 1.18`).

## Coding standards

Orkestra uses the standard Elixir formatter. Before opening a pull request, run:

```bash
mix format
```

The formatter is configured in `.formatter.exs` and covers all files under `lib/`, `test/`, and
`config/`. CI does not currently enforce a format check step as a blocking gate, but reviewers will
ask for formatted code before merging.

## Running tests

Run the full test suite before submitting changes:

```bash
mix test
```

CI runs `mix compile --warnings-as-errors` in addition to `mix test`, so ensure your changes
compile without warnings. See [docs/TESTING.md](docs/TESTING.md) for details on the test structure
and how to run targeted subsets.

If you are modifying `orkestra_mcp/`, run its test suite separately:

```bash
cd orkestra_mcp
mix deps.get
mix test
```

## Commit message convention

This repository uses [Conventional Commits](https://www.conventionalcommits.org/) prefixes:

| Prefix | When to use |
|--------|-------------|
| `feat:` | A new feature or behaviour |
| `fix:` | A bug fix |
| `chore:` | Build changes, dependency updates, project maintenance |
| `docs:` | Documentation-only changes |
| `test:` | Adding or updating tests without changing production code |
| `refactor:` | Code restructuring without behaviour change |

Keep the subject line short (72 characters or fewer) and written in the imperative mood, for example
`fix: handle nil command in dispatcher` rather than `Fixed nil command`.

## PR workflow

1. Fork the repository and create a branch from `main` using a descriptive name, for example
   `feat/rabbitmq-adapter` or `fix/command-dispatch-race`.
2. Make your changes, keeping commits focused. Each commit should pass `mix test` on its own.
3. Run `mix format` and `mix test` locally before pushing.
4. Open a pull request against `main`. Fill in the description with what changed and why.
5. CI will run the following checks automatically:
   - `mix compile --warnings-as-errors` (root project and `orkestra_mcp/`)
   - `mix test` (root project and `orkestra_mcp/`)
6. Address reviewer feedback. Prefer adding new commits over force-pushing during review so the diff
   is easy to follow; you can squash before merge if requested.

There are no PR or issue templates in `.github/` at present — just include a clear description of
the problem and the solution.

## Reporting issues

Open an issue on [GitHub Issues](https://github.com/MontiniSoftware/orkestra/issues). Include:

- A minimal reproducible example
- Expected behaviour and actual behaviour
- Elixir and OTP versions (`elixir --version`)
- Any relevant error output or stack traces

## License

By contributing you agree that your contributions will be licensed under the [MIT License](LICENSE).
