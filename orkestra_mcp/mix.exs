defmodule OrkestraMcp.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/MontiniSoftware/orkestra"

  def project do
    [
      app: :orkestra_mcp,
      version: @version,
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      escript: escript(),
      package: package(),
      description: "MCP server for scaffolding and introspecting Orkestra CQRS/ES projects",
      source_url: @source_url
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {OrkestraMcp.Application, []}
    ]
  end

  defp escript do
    [main_module: OrkestraMcp.CLI]
  end

  defp deps do
    [
      {:hermes_mcp, "~> 0.14"},
      {:jason, "~> 1.2"}
    ]
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{"GitHub" => @source_url},
      files: ~w(lib mix.exs README.md)
    ]
  end
end
