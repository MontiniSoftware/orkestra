defmodule Orkestra.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/MontiniSoftware/orkestra"

  def project do
    [
      app: :orkestra,
      version: @version,
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases(),
      package: package(),
      description: "CQRS/ES toolkit for Elixir with pluggable message bus and event store",
      source_url: @source_url,
      docs: docs()
    ]
  end

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  def cli do
    [preferred_envs: ["test.integration": :test]]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:jason, "~> 1.2"},
      {:phoenix_pubsub, "~> 2.0"},
      {:amqp, "~> 4.1", optional: true},
      {:ecto, "~> 3.12", optional: true},
      {:ecto_sql, "~> 3.12", optional: true},
      {:opentelemetry_api, "~> 1.5"},
      {:opentelemetry_process_propagator, "~> 0.3", optional: true},
      {:postgrex, "~> 0.18", optional: true},
      {:spear, "~> 1.4", optional: true},
      {:snap, "~> 0.16", optional: true},
      {:finch, "~> 0.17", optional: true},
      {:mox, "~> 1.0", only: :test},
      {:ex_doc, "~> 0.35", only: :dev, runtime: false}
    ]
  end

  # `test.integration` runs the integration suite (tagged @moduletag :integration,
  # excluded by default in test/test_helper.exs) against the services from
  # docker-compose.es.yml. The ES URL is read from ELASTICSEARCH_URL (default
  # http://localhost:9200); Postgres from DATABASE_URL. Bring the stack up with
  # `docker compose -f docker-compose.es.yml up -d --wait` first.
  defp aliases do
    [
      "test.integration": ["test --only integration"]
    ]
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{"GitHub" => @source_url},
      files: ~w(lib mix.exs README.md LICENSE)
    ]
  end

  defp docs do
    [
      main: "readme",
      extras: ["README.md"],
      source_ref: "v#{@version}"
    ]
  end
end
