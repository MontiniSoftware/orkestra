defmodule OrkestraMcp.CLI do
  @moduledoc false

  def main(args) do
    {opts, _, _} =
      OptionParser.parse(args, strict: [project_dir: :string])

    project_dir = opts[:project_dir] || File.cwd!()

    Application.put_env(:orkestra_mcp, :project_dir, project_dir)
    {:ok, _} = Application.ensure_all_started(:orkestra_mcp)

    Process.sleep(:infinity)
  end
end
