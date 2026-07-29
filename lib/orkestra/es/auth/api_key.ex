if Code.ensure_loaded?(Snap.Cluster) do
  defmodule Orkestra.ES.Auth.ApiKey do
    @moduledoc """
    `Snap.Auth` implementation for Elasticsearch/OpenSearch API key authentication.

    API keys are the recommended authentication method for Elasticsearch 8.x and
    OpenSearch 2.x in production environments. They offer fine-grained index-level
    permissions and can be revoked without changing cluster credentials.

    ## Configuration

    Configure the cluster module to use this auth provider:

        config :my_app, MyApp.ESCluster,
          url: "https://my-cluster.es.io:9200",
          auth: Orkestra.ES.Auth.ApiKey,
          api_key: Base.encode64("my-key-id:my-api-key-value")

    The `:api_key` config value **must be the already base64-encoded combined
    string** (`Base.encode64("id:api_key_value")`). Do not pass the raw id or
    api_key_value strings separately.

    ## Security Notes

    - Never commit API key values to source control.
    - Use runtime configuration (e.g., `System.fetch_env!/1`) or a secrets
      manager to inject credentials at startup.
    - Create ES/OpenSearch API keys with the minimum required permissions
      (typically write-only to the specific projection index, not cluster admin).
    - In production, always use `https://` URLs — never plain `http://`.

    ## Header Format

    The resulting HTTP header is:

        Authorization: ApiKey <base64-encoded-id:api_key>

    This matches the format required by the Elasticsearch REST API and the
    compatible OpenSearch API.
    """

    @behaviour Snap.Auth

    @impl Snap.Auth
    @doc """
    Signs a request by injecting the `Authorization: ApiKey <encoded>` header.

    Reads the `:api_key` value from `config`. If present and is a binary string,
    prepends `{"Authorization", "ApiKey " <> encoded_key}` to `headers`.
    If absent or `nil`, returns the request unchanged.

    Returns `{:ok, {method, url, updated_headers, body}}`.
    """
    def sign(config, method, url, headers, body) do
      case Keyword.fetch(config, :api_key) do
        {:ok, encoded_key} when is_binary(encoded_key) ->
          auth_header = {"Authorization", "ApiKey " <> encoded_key}
          {:ok, {method, url, [auth_header | headers], body}}

        _ ->
          {:ok, {method, url, headers, body}}
      end
    end
  end
end
