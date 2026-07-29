if Code.ensure_loaded?(Snap.Cluster) do
  defmodule Mix.Tasks.Orkestra.Es.Setup do
    @shortdoc "Create ES aliases + versioned indexes for configured schemas"
    @moduledoc """
    Sets up the Elasticsearch alias + versioned index for every configured
    `Orkestra.ES.Schema` (idempotent — existing aliases are left untouched).

    ## Configuration

    Schemas are discovered from application config as a list of
    `{SchemaModule, ClusterModule}` pairs:

        config :orkestra, :es_schemas, [
          {MyApp.Search.Product, MyApp.ESCluster},
          {MyApp.Search.Article, MyApp.ESCluster}
        ]

    ## Usage

        mix orkestra.es.setup
        mix orkestra.es.setup --schema MyApp.Search.Product
        mix orkestra.es.setup --schema MyApp.Search.Product --culture it

    ## Options

      * `--schema` — only operate on the given schema module.
      * `--culture` — only operate on the given culture (multi-culture schemas).

    Each schema × culture prints its outcome (`created` / `already_exists`).
    The task exits non-zero (via `Mix.raise/1`) on the first error.
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

      Enum.each(pairs, fn {schema, cluster} ->
        for culture <- cultures_for(schema, culture_filter) do
          case Index.setup(cluster, schema, culture) do
            {:ok, outcome} ->
              Mix.shell().info("#{label(schema, culture)}: #{outcome}")

            {:error, reason} ->
              Mix.raise("setup failed for #{label(schema, culture)}: #{inspect(reason)}")
          end
        end
      end)
    end

    # -- shared discovery helpers ---------------------------------------------

    # Reads the `{SchemaModule, ClusterModule}` pairs from config, optionally
    # filtered by `--schema`.
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

    # Cultures to operate on. `nil` filter → all declared cultures (`[nil]` for
    # mono-culture schemas). A culture filter selects that single culture and
    # excludes mono-culture schemas (which take no culture argument).
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
