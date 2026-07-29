if Code.ensure_loaded?(Ecto.Multi) do
  defmodule Orkestra.Projection.Storage.PostgresAdapterTddTest do
    @moduledoc false

    use ExUnit.Case, async: true

    alias Orkestra.Projection.Storage.Postgres

    describe "Storage behaviour conformance" do
      test "Postgres adapter declares @behaviour Orkestra.Projection.Storage" do
        behaviours =
          Postgres.__info__(:attributes) |> Keyword.get_values(:behaviour) |> List.flatten()

        assert Orkestra.Projection.Storage in behaviours
      end
    end

    describe "write/4 contract" do
      test "returns {:ok, %Ecto.Multi{}} when handler returns {:ok, multi}" do
        handler = fn _projector_name, _event, _position ->
          multi =
            Ecto.Multi.new()
            |> Ecto.Multi.run(:read_model_insert, fn _repo, _changes ->
              {:ok, :dummy}
            end)

          {:ok, multi}
        end

        assert {:ok, multi} =
                 Postgres.write("my_projector", %{type: "SomeEvent"}, 0, handler: handler)

        assert is_struct(multi, Ecto.Multi)
      end

      test "all Multi step names from handler are prefixed with :read_model_" do
        handler = fn _projector_name, _event, _position ->
          multi =
            Ecto.Multi.new()
            |> Ecto.Multi.run(:read_model_insert, fn _repo, _changes ->
              {:ok, :ok}
            end)

          {:ok, multi}
        end

        {:ok, multi} = Postgres.write("my_projector", %{type: "SomeEvent"}, 0, handler: handler)
        names = Ecto.Multi.to_list(multi) |> Enum.map(&elem(&1, 0))

        assert Enum.all?(names, fn name ->
                 String.starts_with?(Atom.to_string(name), "read_model_")
               end)
      end

      test "can be appended to a checkpoint Multi without name clash" do
        handler = fn _projector_name, _event, _position ->
          multi =
            Ecto.Multi.new()
            |> Ecto.Multi.run(:read_model_insert, fn _repo, _changes -> {:ok, :ok} end)

          {:ok, multi}
        end

        {:ok, write_multi} =
          Postgres.write("my_projector", %{type: "SomeEvent"}, 0, handler: handler)

        checkpoint_multi =
          Ecto.Multi.new()
          |> Ecto.Multi.run(:checkpoint, fn _repo, _changes -> {:ok, :ok} end)

        # Must NOT raise ArgumentError: duplicate multi key
        assert %Ecto.Multi{} = Ecto.Multi.append(write_multi, checkpoint_multi)
      end

      test "propagates {:error, reason} when handler returns an error" do
        handler = fn _projector_name, _event, _position ->
          {:error, :bad_event}
        end

        assert {:error, :bad_event} =
                 Postgres.write("my_projector", %{type: "SomeEvent"}, 0, handler: handler)
      end
    end

    describe "reset/2 contract" do
      test "returns :ok (unit test — schema module not required for return value)" do
        # We can't call reset/2 without a real DB here; covered in postgres_test.exs
        # This test checks the callback is exported with the right arity.
        # `Code.ensure_loaded?/1` guards against `function_exported?/3` returning
        # false for a not-yet-loaded module in this async test (the module may
        # not have been loaded by another test yet).
        assert Code.ensure_loaded?(Postgres) and function_exported?(Postgres, :reset, 2)
      end
    end
  end
end
