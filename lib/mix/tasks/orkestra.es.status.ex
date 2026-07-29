if Code.ensure_loaded?(Snap.Cluster) do
  defmodule Mix.Tasks.Orkestra.Es.Status do
    @shortdoc "Show alias/drift status for configured ES schemas"
    @moduledoc """
    Prints a read-only status table for every configured `Orkestra.ES.Schema`,
    reporting whether each alias exists and whether its deployed mapping has
    drifted from the current schema definition. Makes no changes.

    ## Configuration

    Schemas are discovered from application config as a list of
    `{SchemaModule, ClusterModule}` pairs:

        config :orkestra, :es_schemas, [
          {MyApp.Search.Product, MyApp.ESCluster}
        ]

    ## Usage

        mix orkestra.es.status
        mix orkestra.es.status --schema MyApp.Search.Product
        mix orkestra.es.status --schema MyApp.Search.Product --culture it

    ## Options

      * `--schema` — only report on the given schema module.
      * `--culture` — only report on the given culture (multi-culture schemas).

    The table shows the schema, culture, alias, whether it exists, whether it
    has drifted, and the abbreviated deployed vs. schema mapping hashes.
    """

    use Mix.Task

    alias Orkestra.ES.Index

    @switches [schema: :string, culture: :string]

    @impl Mix.Task
    def run(args) do
      {opts, _positional, _invalid} = OptionParser.parse(args, strict: @switches)

      Mix.Task.run("app.start")

      pairs = discover(opts)
      culture_filter = culture_filter(opts)

      header =
        row(["SCHEMA", "CULTURE", "ALIAS", "EXISTS", "DRIFT?", "CURRENT", "SCHEMA"])

      Mix.shell().info(header)

      Enum.each(pairs, fn {schema, cluster} ->
        for culture <- cultures_for(schema, culture_filter) do
          case Index.status(cluster, schema, culture) do
            {:ok, status} ->
              Mix.shell().info(status_row(schema, culture, status))

            {:error, reason} ->
              Mix.raise("status failed for #{label(schema, culture)}: #{inspect(reason)}")
          end
        end
      end)
    end

    defp status_row(schema, culture, status) do
      row([
        inspect(schema),
        culture_cell(culture),
        status.alias,
        to_string(status.exists),
        to_string(status.drift?),
        abbrev(status.current_hash),
        abbrev(status.schema_hash)
      ])
    end

    defp row(cells), do: Enum.map_join(cells, "  ", &String.pad_trailing(&1, 18))

    defp abbrev(nil), do: "-"
    defp abbrev(hash), do: String.slice(hash, 0, 8)

    defp culture_cell(nil), do: "-"
    defp culture_cell(culture), do: to_string(culture)

    # -- shared discovery helpers ---------------------------------------------

    defp discover(opts) do
      pairs = Application.get_env(:orkestra, :es_schemas, [])

      case Keyword.get(opts, :schema) do
        nil ->
          pairs

        name ->
          target = Module.concat([name])
          Enum.filter(pairs, fn {schema, _cluster} -> schema == target end)
      end
    end

    defp culture_filter(opts) do
      case Keyword.get(opts, :culture) do
        nil -> nil
        value -> String.to_atom(value)
      end
    end

    defp cultures_for(schema, nil) do
      case schema.__es_schema__(:cultures) do
        [] -> [nil]
        list -> list
      end
    end

    defp cultures_for(schema, culture) do
      case schema.__es_schema__(:cultures) do
        [] -> []
        list -> if culture in list, do: [culture], else: []
      end
    end

    defp label(schema, nil), do: inspect(schema)
    defp label(schema, culture), do: "#{inspect(schema)} [#{culture}]"
  end
end
