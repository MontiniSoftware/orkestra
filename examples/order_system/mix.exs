defmodule OrderSystem.MixProject do
  use Mix.Project

  def project do
    [
      app: :order_system,
      version: "0.1.0",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {OrderSystem.Application, []}
    ]
  end

  defp deps do
    [
      # Orkestra — CQRS/ES library (path dep for example; use {:orkestra, "~> 0.1"} in real projects)
      {:orkestra, path: "../.."},

      # PostgreSQL (for checkpoints + Postgres read model)
      {:ecto_sql, "~> 3.12"},
      {:postgrex, "~> 0.18"},

      # Elasticsearch (for ES read model)
      {:snap, "~> 0.16"},
      {:finch, "~> 0.17"},

      # PubSub (in-process message bus)
      {:phoenix_pubsub, "~> 2.0"},

      # JSON
      {:jason, "~> 1.2"},

      # OpenTelemetry
      {:opentelemetry_api, "~> 1.5"},

      # Spear (needed to compile Orkestra's optional EventStoreDB adapter)
      {:spear, "~> 1.4"}
    ]
  end

  defp aliases do
    [
      setup: ["deps.get", "ecto.setup"],
      "ecto.setup": ["ecto.create", "ecto.migrate"],
      "ecto.reset": ["ecto.drop", "ecto.setup"],
      seed: ["run priv/seeds.exs"]
    ]
  end
end
