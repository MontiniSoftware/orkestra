if Code.ensure_loaded?(Snap.Cluster) do
  # ---------------------------------------------------------------------------
  # Inline schemas used to exercise Mix task discovery / filtering / dry-run.
  # ---------------------------------------------------------------------------
  defmodule Mix.Tasks.Orkestra.Es.TasksTest.Alpha do
    @moduledoc false

    use Orkestra.ES.Schema,
      index: "alpha_tt",
      cultures: [:it, :en],
      default_culture: :it

    schema do
      field(:id, :keyword, primary_key: true)
      field(:name, :text)
    end
  end

  defmodule Mix.Tasks.Orkestra.Es.TasksTest.Beta do
    @moduledoc false

    use Orkestra.ES.Schema,
      index: "beta_tt",
      cultures: [:it, :en],
      default_culture: :it

    schema do
      field(:id, :keyword, primary_key: true)
      field(:name, :text)
    end
  end

  defmodule Mix.Tasks.Orkestra.Es.TasksTest.Solo do
    @moduledoc false

    use Orkestra.ES.Schema, index: "solo_tt"

    schema do
      field(:id, :keyword, primary_key: true)
    end
  end

  defmodule Mix.Tasks.Orkestra.Es.TasksTest do
    @moduledoc false

    use ExUnit.Case, async: false

    @moduletag :elasticsearch

    import Mox

    alias Mix.Tasks.Orkestra.Es.TasksTest.Alpha
    alias Mix.Tasks.Orkestra.Es.TasksTest.Beta
    alias Mix.Tasks.Orkestra.Es.TasksTest.Solo

    @cluster Orkestra.Test.ESCluster

    setup :verify_on_exit!

    setup do
      previous_shell = Mix.shell()
      Mix.shell(Mix.Shell.Process)

      Application.put_env(:orkestra, :es_schemas, [
        {Alpha, @cluster},
        {Beta, @cluster},
        {Solo, @cluster}
      ])

      on_exit(fn ->
        Mix.shell(previous_shell)
        Application.delete_env(:orkestra, :es_schemas)
      end)

      :ok
    end

    # Every alias resolves to a 404 (absent) — the read-only dry-run / status
    # path never mutates anything, so this covers discovery + filtering.
    defp stub_all_absent do
      Mox.stub(Snap.MockHTTPClient, :request, fn _cluster, :get, url, _headers, _body, _opts ->
        body =
          Jason.encode!(%{
            "error" => %{"type" => "index_not_found_exception"},
            "status" => 404
          })

        {:ok, %Snap.HTTPClient.Response{status: 404, headers: [], body: body}}
      end)
    end

    # Drains all buffered `Mix.Shell.Process` info messages into a single string.
    defp drain_output(acc \\ []) do
      receive do
        {:mix_shell, :info, [line]} -> drain_output([line | acc])
      after
        0 -> acc |> Enum.reverse() |> Enum.join("\n")
      end
    end

    # -------------------------------------------------------------------------
    # Dry-run migrate — discovery across every configured schema × culture
    # -------------------------------------------------------------------------

    describe "orkestra.es.migrate --dry-run" do
      test "reports would_create for every configured schema and culture" do
        stub_all_absent()

        Mix.Tasks.Orkestra.Es.Migrate.run(["--dry-run"])

        output = drain_output()

        assert output =~ "Alpha [it]: would_create"
        assert output =~ "Alpha [en]: would_create"
        assert output =~ "Beta [it]: would_create"
        assert output =~ "Beta [en]: would_create"
        # Mono-culture schema has no culture suffix.
        assert output =~ "TasksTest.Solo: would_create"
      end

      test "the --schema flag narrows discovery to a single schema" do
        stub_all_absent()

        Mix.Tasks.Orkestra.Es.Migrate.run([
          "--dry-run",
          "--schema",
          "Mix.Tasks.Orkestra.Es.TasksTest.Alpha"
        ])

        output = drain_output()

        assert output =~ "Alpha [it]: would_create"
        assert output =~ "Alpha [en]: would_create"
        refute output =~ "Beta"
        refute output =~ "Solo"
      end

      test "the --culture flag narrows to one culture and excludes mono-culture schemas" do
        stub_all_absent()

        Mix.Tasks.Orkestra.Es.Migrate.run(["--dry-run", "--culture", "it"])

        output = drain_output()

        assert output =~ "Alpha [it]: would_create"
        assert output =~ "Beta [it]: would_create"
        refute output =~ "[en]"
        # Mono-culture schema takes no culture argument, so it is skipped.
        refute output =~ "Solo"
      end

      test "reports would_migrate when the deployed mapping has drifted" do
        Mox.stub(Snap.MockHTTPClient, :request, fn _cluster, :get, _url, _headers, _body, _opts ->
          body =
            Jason.encode!(%{
              "some_index-1" => %{
                "mappings" => %{"_meta" => %{"orkestra_schema_hash" => "stale"}}
              }
            })

          {:ok, %Snap.HTTPClient.Response{status: 200, headers: [], body: body}}
        end)

        Mix.Tasks.Orkestra.Es.Migrate.run([
          "--dry-run",
          "--schema",
          "Mix.Tasks.Orkestra.Es.TasksTest.Alpha",
          "--culture",
          "it"
        ])

        output = drain_output()
        assert output =~ "Alpha [it]: would_migrate"
      end
    end

    # -------------------------------------------------------------------------
    # Status table
    # -------------------------------------------------------------------------

    describe "orkestra.es.status" do
      test "prints a header and one row per filtered schema × culture" do
        stub_all_absent()

        Mix.Tasks.Orkestra.Es.Status.run([
          "--schema",
          "Mix.Tasks.Orkestra.Es.TasksTest.Alpha",
          "--culture",
          "it"
        ])

        output = drain_output()

        assert output =~ "SCHEMA"
        assert output =~ "DRIFT?"
        assert output =~ "alpha_tt_it"
        refute output =~ "Beta"
        refute output =~ "alpha_tt_en"
      end
    end
  end
end
