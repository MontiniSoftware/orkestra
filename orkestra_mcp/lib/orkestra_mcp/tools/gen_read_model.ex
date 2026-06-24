defmodule OrkestraMcp.Tools.GenReadModel do
  @moduledoc "Generate an Ecto schema module for a read model with its migration file"

  use Hermes.Server.Component, type: :tool

  schema do
    field(:module_name, :string,
      required: true,
      description: "Full schema module name, e.g. MyApp.Orders.OrderReadModel"
    )

    field(:fields, :string,
      required: true,
      description:
        ~s(JSON array of fields: [{"name":"order_id","type":"binary_id"},{"name":"status","type":"string"}])
    )
  end

  @impl true
  def execute(%{module_name: module_name, fields: fields_json}, _frame) do
    project_dir = Application.get_env(:orkestra_mcp, :project_dir)
    fields = Jason.decode!(fields_json)

    {schema_source, schema_path} = OrkestraMcp.Generator.gen_read_model(module_name, fields)

    {migration_source, migration_path} =
      OrkestraMcp.Generator.gen_read_model_migration(module_name)

    written_schema = OrkestraMcp.Generator.write!(schema_source, project_dir, schema_path)

    written_migration =
      OrkestraMcp.Generator.write!(migration_source, project_dir, migration_path)

    {:ok,
     "Created #{written_schema}\nCreated #{written_migration}\n\n```elixir\n#{schema_source}\n```"}
  end
end
