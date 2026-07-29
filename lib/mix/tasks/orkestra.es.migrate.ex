if Code.ensure_loaded?(Snap.Cluster) do
  defmodule Mix.Tasks.Orkestra.Es.Migrate do
    @shortdoc "Reconcile ES aliases with configured schemas (zero-downtime)"
    @moduledoc """
    Reconciles the Elasticsearch alias of every configured `Orkestra.ES.Schema`
    with its current mapping. Missing aliases are created; drifted aliases are
    reindexed zero-downtime via `Snap.Indexes.hotswap/5`; in-sync aliases are
    left untouched.

    ## Configuration

    Schemas are discovered from application config as a list of
    `{SchemaModule, ClusterModule}` pairs:

        config :orkestra, :es_schemas, [
          {MyApp.Search.Product, MyApp.ESCluster}
        ]

    ## Usage

        mix orkestra.es.migrate
        mix orkestra.es.migrate --schema MyApp.Search.Product
        mix orkestra.es.migrate --schema MyApp.Search.Product --culture it
        mix orkestra.es.migrate --dry-run

    ## Options

      * `--schema` — only operate on the given schema module.
      * `--culture` — only operate on the given culture (multi-culture schemas).
      * `--dry-run` — report the action each alias *would* take (using
        `Orkestra.ES.Index.status/3`) without changing anything.

    Each schema × culture prints its outcome (`noop` / `created` / `migrated`,
    or `would_*` under `--dry-run`). The task exits non-zero (via `Mix.raise/1`)
    on the first error.

    ## Consistency window

    A drifted alias is reindexed from a scroll snapshot; writes issued during
    the migration window are not carried over. Coordinate the write path
    externally, as with a projection rebuild.
    """

    use Mix.Task

    alias Orkestra.ES.Index

    @switches [schema: :string, culture: :string, dry_run: :boolean]

    @impl Mix.Task
    def run(args) do
      {opts, _positional, _invalid} = OptionParser.parse(args, strict: @switches)

      Mix.Task.run("app.start")

      pairs = discover(opts)
      culture_filter = culture_filter(opts)
      dry_run? = Keyword.get(opts, :dry_run, false)

      Enum.each(pairs, fn {schema, cluster} ->
        for culture <- cultures_for(schema, culture_filter) do
          if dry_run? do
            dry_run(cluster, schema, culture)
          else
            migrate(cluster, schema, culture)
          end
        end
      end)
    end

    defp migrate(cluster, schema, culture) do
      case Index.migrate(cluster, schema, culture) do
        {:ok, outcome} ->
          Mix.shell().info("#{label(schema, culture)}: #{outcome}")

        {:error, reason} ->
          Mix.raise("migrate failed for #{label(schema, culture)}: #{inspect(reason)}")
      end
    end

    defp dry_run(cluster, schema, culture) do
      case Index.status(cluster, schema, culture) do
        {:ok, %{exists: false}} ->
          Mix.shell().info("#{label(schema, culture)}: would_create")

        {:ok, %{drift?: true}} ->
          Mix.shell().info("#{label(schema, culture)}: would_migrate")

        {:ok, _in_sync} ->
          Mix.shell().info("#{label(schema, culture)}: noop")

        {:error, reason} ->
          Mix.raise("status failed for #{label(schema, culture)}: #{inspect(reason)}")
      end
    end

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
