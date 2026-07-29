if Code.ensure_loaded?(Snap.Cluster) do
  defmodule Orkestra.ES.Auth.ApiKeyTest do
    @moduledoc false

    use ExUnit.Case, async: true

    alias Orkestra.ES.Auth.ApiKey

    describe "sign/5" do
      # Test 1: aggiunge l'header Authorization: ApiKey quando :api_key è presente
      test "adds Authorization: ApiKey header when :api_key config is present" do
        encoded_key = "dGVzdDprZXk="
        config = [api_key: encoded_key]

        {:ok, {method, url, headers, body}} =
          ApiKey.sign(config, "GET", "http://localhost:9200/", [], "")

        assert method == "GET"
        assert url == "http://localhost:9200/"
        assert body == ""

        assert {"Authorization", "ApiKey " <> ^encoded_key} =
                 Enum.find(headers, fn {k, _} -> k == "Authorization" end)
      end

      # Test 2: passa invariato quando :api_key non è presente
      test "passes through unchanged when :api_key config is absent" do
        config = []
        original_headers = [{"Content-Type", "application/json"}]

        {:ok, {method, url, headers, body}} =
          ApiKey.sign(config, "POST", "http://localhost:9200/_search", original_headers, "{}")

        assert method == "POST"
        assert url == "http://localhost:9200/_search"
        assert headers == original_headers
        assert body == "{}"
        refute Enum.any?(headers, fn {k, _} -> k == "Authorization" end)
      end

      # Test 3: passa invariato quando :api_key è nil
      test "passes through unchanged when :api_key is nil" do
        config = [api_key: nil]
        original_headers = []

        {:ok, {method, url, headers, body}} =
          ApiKey.sign(config, "GET", "http://localhost:9200/", original_headers, "")

        assert method == "GET"
        assert url == "http://localhost:9200/"
        assert headers == original_headers
        assert body == ""
        refute Enum.any?(headers, fn {k, _} -> k == "Authorization" end)
      end

      # Test 4: preserva gli header esistenti quando aggiunge Authorization
      test "prepends Authorization header to existing headers" do
        config = [api_key: "dGVzdDprZXk="]
        existing_headers = [{"Content-Type", "application/json"}, {"X-Custom", "value"}]

        {:ok, {_method, _url, headers, _body}} =
          ApiKey.sign(config, "PUT", "http://localhost:9200/idx/_doc/1", existing_headers, "{}")

        auth_header = Enum.find(headers, fn {k, _} -> k == "Authorization" end)
        assert auth_header == {"Authorization", "ApiKey dGVzdDprZXk="}

        # Gli header originali devono essere ancora presenti
        assert {"Content-Type", "application/json"} in headers
        assert {"X-Custom", "value"} in headers
      end
    end

    # Test 5 (contratto behaviour): Orkestra.ES.Auth.ApiKey dichiara @behaviour Snap.Auth
    describe "behaviour contract" do
      test "Orkestra.ES.Auth.ApiKey declares @behaviour Snap.Auth" do
        behaviours =
          ApiKey.__info__(:attributes)
          |> Keyword.get_values(:behaviour)
          |> List.flatten()

        assert Snap.Auth in behaviours
      end
    end

    # Test 6 (ADPT-03 Basic Auth): Snap.Auth.Plain aggiunge Authorization: Basic
    describe "Snap.Auth.Plain (ADPT-03 Basic Auth coverage)" do
      test "Snap.Auth.Plain.sign/5 adds Authorization: Basic header when username+password provided" do
        config = [username: "elastic", password: "changeme"]

        {:ok, {method, url, headers, body}} =
          Snap.Auth.Plain.sign(config, "GET", "http://localhost:9200/", [], "")

        assert method == "GET"
        assert url == "http://localhost:9200/"
        assert body == ""

        auth_header = Enum.find(headers, fn {k, _} -> k == "Authorization" end)
        assert {_key, auth_value} = auth_header
        assert String.starts_with?(auth_value, "Basic ")
      end
    end
  end
end
