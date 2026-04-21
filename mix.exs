defmodule Orkestra.MixProject do
  use Mix.Project

  def project do
    [
      app: :orkestra,
      version: "0.1.0",
      elixir: "~> 1.15",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description: "CQRS/ES toolkit for Elixir with pluggable message bus and event store"
    ]
  end

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp deps do
    [
      {:jason, "~> 1.2"},
      {:phoenix_pubsub, "~> 2.0"},
      {:amqp, "~> 4.1", optional: true},
      {:opentelemetry_api, "~> 1.5"},
      {:opentelemetry_process_propagator, "~> 0.3", optional: true},
      {:spear, "~> 1.4", optional: true}
    ]
  end
end
