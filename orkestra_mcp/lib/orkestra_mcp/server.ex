defmodule OrkestraMcp.Server do
  @moduledoc false

  use Hermes.Server,
    name: "orkestra-mcp",
    version: "0.1.0",
    capabilities: [:tools, :resources, :prompts]

  # Tools
  component(OrkestraMcp.Tools.GenCommand)
  component(OrkestraMcp.Tools.GenEvent)
  component(OrkestraMcp.Tools.GenCommandHandler)
  component(OrkestraMcp.Tools.GenEventHandler)
  component(OrkestraMcp.Tools.GenAggregate)

  # Resources
  component(OrkestraMcp.Resources.ListCommands)
  component(OrkestraMcp.Resources.ListEvents)
  component(OrkestraMcp.Resources.ListHandlers)
  component(OrkestraMcp.Resources.ListAggregates)
  component(OrkestraMcp.Resources.DomainMap)

  # Prompts
  component(OrkestraMcp.Prompts.Conventions)
  component(OrkestraMcp.Prompts.NewBoundedContext)
end
