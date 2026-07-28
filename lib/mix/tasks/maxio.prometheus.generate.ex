defmodule Mix.Tasks.Maxio.Prometheus.Generate do
  @shortdoc "Generate a MinIO-style Prometheus bearer token"
  @moduledoc """
  Generates a Prometheus bearer token and scrape config for the S3 metrics
  endpoint.

      mix maxio.prometheus.generate --access-key AKIA... --endpoint http://localhost:9000
      mix maxio.prometheus.generate --access-key AKIA... --secret-key SECRET --token-only
      mix maxio.prometheus.generate --access-key AKIA... --type objects --expires-days 30

  If `--secret-key` is omitted, the task starts the app and reads the secret
  through the configured credential store. The token principal must still have
  an identity policy allowing `admin:Prometheus` unless it is the root key.
  """

  use Mix.Task

  alias Maxio.Auth.CredentialStore
  alias Maxio.S3.PrometheusToken

  @switches [
    access_key: :string,
    secret_key: :string,
    endpoint: :string,
    api_version: :string,
    type: :string,
    expires_seconds: :integer,
    expires_days: :integer,
    token_only: :boolean
  ]
  @aliases [a: :access_key, s: :secret_key]

  @impl true
  def run(argv) do
    {opts, rest, invalid} = OptionParser.parse(argv, strict: @switches, aliases: @aliases)

    if rest != [] or invalid != [] do
      unexpected = rest ++ Enum.map(invalid, &elem(&1, 0))
      Mix.raise("unexpected arguments: #{inspect(unexpected)}")
    end

    access_key = Keyword.get(opts, :access_key) || Mix.raise("--access-key required")
    secret_key = secret_key(access_key, opts)
    ttl_seconds = ttl_seconds(opts)

    token =
      PrometheusToken.generate(access_key, secret_key,
        ttl_seconds: ttl_seconds,
        now: DateTime.utc_now()
      )

    if Keyword.get(opts, :token_only, false) do
      IO.puts(token)
    else
      IO.puts(scrape_config(token, opts))
    end
  end

  defp secret_key(access_key, opts) do
    case Keyword.get(opts, :secret_key) do
      secret_key when is_binary(secret_key) ->
        secret_key

      _missing ->
        Mix.Task.run("app.start")

        case CredentialStore.get_secret(access_key) do
          {:ok, %{secret_key: secret_key}} ->
            secret_key

          :error ->
            Mix.raise("access key not found: #{access_key}")

          {:error, reason} ->
            Mix.raise("cannot load secret for #{access_key}: #{inspect(reason)}")
        end
    end
  end

  defp ttl_seconds(opts) do
    cond do
      seconds = Keyword.get(opts, :expires_seconds) ->
        positive_integer!("--expires-seconds", seconds)

      days = Keyword.get(opts, :expires_days) ->
        positive_integer!("--expires-days", days) * 24 * 60 * 60

      true ->
        PrometheusToken.default_ttl_seconds()
    end
  end

  defp positive_integer!(_flag, value) when is_integer(value) and value > 0, do: value

  defp positive_integer!(flag, value),
    do: Mix.raise("#{flag} must be a positive integer: #{inspect(value)}")

  defp scrape_config(token, opts) do
    {scheme, target} =
      opts
      |> Keyword.get(:endpoint, "http://localhost:9000")
      |> parse_endpoint()

    path = metrics_path(opts)

    [
      "scrape_configs:\n",
      "- job_name: maxio-",
      config_type(opts),
      "\n",
      "  bearer_token: ",
      inspect(token),
      "\n",
      "  metrics_path: ",
      path,
      "\n",
      "  scheme: ",
      scheme,
      "\n",
      "  static_configs:\n",
      "  - targets: [",
      inspect(target),
      "]\n"
    ]
    |> IO.iodata_to_binary()
  end

  defp parse_endpoint(endpoint) when is_binary(endpoint) do
    endpoint = String.trim(endpoint)
    endpoint = if String.contains?(endpoint, "://"), do: endpoint, else: "http://" <> endpoint
    uri = URI.parse(endpoint)

    cond do
      uri.scheme not in ["http", "https"] ->
        Mix.raise("--endpoint must use http:// or https://, got #{inspect(endpoint)}")

      is_nil(uri.host) or uri.host == "" ->
        Mix.raise("--endpoint must include host[:port], got #{inspect(endpoint)}")

      not is_nil(uri.userinfo) ->
        Mix.raise("--endpoint must not include userinfo")

      true ->
        {uri.scheme, endpoint_target(uri)}
    end
  end

  defp parse_endpoint(endpoint),
    do: Mix.raise("--endpoint must be a URL or host:port, got #{inspect(endpoint)}")

  defp endpoint_target(%URI{host: host, port: nil}), do: format_host(host)

  defp endpoint_target(%URI{host: host, port: port}),
    do: format_host(host) <> ":" <> Integer.to_string(port)

  defp format_host(host) do
    if String.contains?(host, ":") and not String.starts_with?(host, "[") do
      "[" <> host <> "]"
    else
      host
    end
  end

  defp metrics_path(opts) do
    version = Keyword.get(opts, :api_version, "v3")

    case {version, config_type(opts)} do
      {"v3", "cluster"} ->
        "/minio/metrics/v3/cluster"

      {"v3", "objects"} ->
        "/minio/metrics/v3/cluster/usage/objects"

      {"v3", "buckets"} ->
        "/minio/metrics/v3/cluster/usage/buckets"

      {"v2", "cluster"} ->
        "/minio/v2/metrics/cluster"

      {other_version, other_type} ->
        Mix.raise("unsupported api/type: #{other_version}/#{other_type}")
    end
  end

  defp config_type(opts) do
    opts
    |> Keyword.get(:type, "cluster")
    |> String.downcase()
    |> case do
      "cluster" -> "cluster"
      "objects" -> "objects"
      "usage-objects" -> "objects"
      "buckets" -> "buckets"
      "usage-buckets" -> "buckets"
      other -> Mix.raise("--type must be cluster, objects, or buckets; got #{inspect(other)}")
    end
  end
end
