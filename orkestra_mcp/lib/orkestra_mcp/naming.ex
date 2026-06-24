defmodule OrkestraMcp.Naming do
  @moduledoc false

  @doc """
  Converts a fully-qualified module name to a file path.

      iex> OrkestraMcp.Naming.module_to_file_path("MyApp.Orders.Commands.PlaceOrder")
      "lib/my_app/orders/commands/place_order.ex"
  """
  def module_to_file_path(module_name) do
    parts =
      module_name
      |> String.split(".")
      |> Enum.map(&Macro.underscore/1)

    Path.join(["lib" | parts]) <> ".ex"
  end

  @doc """
  Converts a module name to a pluralised table name.

      iex> OrkestraMcp.Naming.module_to_table_name("MyApp.Orders.OrderReadModel")
      "order_read_models"
  """
  def module_to_table_name(module_name) do
    module_name
    |> String.split(".")
    |> List.last()
    |> Macro.underscore()
    |> Kernel.<>("s")
  end

  @doc """
  Infers the top-level application module from a project's mix.exs.

      iex> OrkestraMcp.Naming.infer_app_module("/path/to/project")
      {:ok, "MyApp"}
  """
  def infer_app_module(project_dir) do
    mix_path = Path.join(project_dir, "mix.exs")

    case File.read(mix_path) do
      {:ok, content} ->
        case Regex.run(~r/defmodule\s+([\w.]+)\.MixProject/, content) do
          [_, module_name] -> {:ok, module_name}
          nil -> {:error, :no_mix_project}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end
end
