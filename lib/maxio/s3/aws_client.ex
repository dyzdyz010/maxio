defmodule Maxio.S3.AWSClient do
  @moduledoc """
  Small SigV4 HTTP client helper for AWS control-plane calls used by bucket
  notification delivery and destination validation.

  This intentionally stays SDK-free. Tests can inject `:http_client`, while the
  default transport uses Req.
  """

  alias Maxio.Auth.SigV4.{Canonical, Signer}

  @algorithm "AWS4-HMAC-SHA256"
  @supported_partitions ~w(aws aws-cn aws-us-gov)

  @spec signed_form_request(atom(), String.t(), String.t(), String.t(), map(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def signed_form_request(method, url, service, region, params, opts) do
    body = URI.encode_query(params)

    signed_request(
      method,
      url,
      service,
      region,
      %{"content-type" => "application/x-www-form-urlencoded"},
      body,
      opts
    )
  end

  @spec signed_json_request(atom(), String.t(), String.t(), String.t(), map(), map(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def signed_json_request(method, url, service, region, headers, payload, opts) do
    body = Jason.encode!(payload)
    signed_request(method, url, service, region, headers, body, opts)
  rescue
    error -> {:error, {:request_build_failed, Exception.message(error)}}
  end

  @spec signed_request(
          atom(),
          String.t(),
          String.t(),
          String.t(),
          map(),
          iodata(),
          keyword()
        ) ::
          {:ok, map()} | {:error, term()}
  def signed_request(method, url, service, region, headers, body, opts) do
    {:ok, signed_request!(method, url, service, region, headers, body, opts)}
  rescue
    error -> {:error, {:request_build_failed, Exception.message(error)}}
  end

  @spec signed_request!(
          atom(),
          String.t(),
          String.t(),
          String.t(),
          map(),
          iodata(),
          keyword()
        ) :: map()
  def signed_request!(method, url, service, region, headers, body, opts) do
    credentials = credentials!(opts)
    uri = URI.parse(url)
    host = host_header(uri)
    now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)
    amz_date = Calendar.strftime(now, "%Y%m%dT%H%M%SZ")
    scope_date = Calendar.strftime(now, "%Y%m%d")
    scope = "#{scope_date}/#{region}/#{service}/aws4_request"
    payload_hash = Signer.hex_sha256(body)

    signing_headers =
      headers
      |> normalize_headers()
      |> Map.put("host", host)
      |> Map.put("x-amz-date", amz_date)
      |> Map.put("x-amz-content-sha256", payload_hash)
      |> maybe_put("x-amz-security-token", credentials.session_token)

    canonical_headers = Map.to_list(signing_headers)

    canonical =
      Canonical.canonical_request(%{
        method: method |> to_string() |> String.upcase(),
        path: URI.decode(uri.path || "/"),
        query: uri.query || "",
        headers: canonical_headers,
        payload_hash: payload_hash
      })

    string_to_sign = Signer.string_to_sign(amz_date, scope, canonical, @algorithm)

    signing_key =
      Signer.derive_signing_key(credentials.secret_access_key, scope_date, region, service)

    signature = Signer.signature(signing_key, string_to_sign)
    signed_headers = Canonical.signed_headers(canonical_headers)

    authorization =
      "#{@algorithm} Credential=#{credentials.access_key_id}/#{scope}," <>
        "SignedHeaders=#{signed_headers},Signature=#{signature}"

    headers =
      signing_headers
      |> Map.put("authorization", authorization)
      |> Map.delete("host")
      |> Map.to_list()

    %{
      method: method,
      url: url,
      headers: headers,
      body: body
    }
  end

  @spec send_request(map(), keyword(), keyword()) :: :ok | {:error, term()}
  def send_request(request, opts, request_opts \\ []) do
    case perform_request(request, opts, request_opts) do
      {:ok, _body} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @spec perform_request(map(), keyword(), keyword()) :: {:ok, term()} | {:error, term()}
  def perform_request(request, opts, request_opts \\ []) do
    success_statuses = Keyword.get(request_opts, :success_statuses, [200])

    case http_client(opts).(request) do
      {:ok, %{status: status, body: body}} ->
        if status_ok?(status, success_statuses) do
          put_response_body(opts, Map.put(request, :response_body, body))
          {:ok, body}
        else
          {:error, {:aws_http_error, status, body}}
        end

      {:error, reason} ->
        {:error, reason}

      other ->
        {:error, {:bad_http_return, other}}
    end
  end

  @spec parse_arn(String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def parse_arn(arn, expected_service) do
    case String.split(arn, ":", parts: 6) do
      ["arn", partition, ^expected_service, region, account, resource]
      when partition != "" and region != "" and account != "" and resource != "" ->
        if supported_partition?(partition) do
          {:ok, %{partition: partition, region: region, account: account, resource: resource}}
        else
          {:error, {:unsupported_arn_partition, partition}}
        end

      ["arn", _partition, service, _region, _account, _resource] ->
        {:error, {:unexpected_destination_service, service, expected_service}}

      _other ->
        {:error, {:invalid_destination_arn, arn}}
    end
  end

  @spec ensure_supported_partition(String.t()) :: :ok | {:error, term()}
  def ensure_supported_partition(partition) do
    if supported_partition?(partition) do
      :ok
    else
      {:error, {:unsupported_arn_partition, partition}}
    end
  end

  @spec supported_partition?(String.t()) :: boolean()
  def supported_partition?(partition), do: partition in @supported_partitions

  @spec endpoint(keyword(), atom(), map()) :: String.t()
  def endpoint(opts, service, %{region: region, partition: partition}) do
    endpoints = Keyword.get(opts, :endpoints, %{})

    endpoint =
      opt(endpoints, service) ||
        Keyword.get(opts, :"#{service}_endpoint") ||
        default_endpoint(service, region, partition)

    endpoint
    |> String.trim_trailing("/")
    |> Kernel.<>("/")
  end

  @spec queue_url(String.t(), map(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def queue_url(arn, arn_parts, opts) do
    queue_urls = Keyword.get(opts, :queue_urls, %{})

    url =
      opt(queue_urls, arn) ||
        "https://sqs.#{arn_parts.region}.#{dns_suffix!(arn_parts.partition)}/#{arn_parts.account}/#{arn_parts.resource}"

    {:ok, url}
  rescue
    error -> {:error, {:queue_url_failed, Exception.message(error)}}
  end

  @spec dns_suffix!(String.t()) :: String.t()
  def dns_suffix!("aws"), do: "amazonaws.com"
  def dns_suffix!("aws-cn"), do: "amazonaws.com.cn"
  def dns_suffix!("aws-us-gov"), do: "amazonaws.com"

  def dns_suffix!(partition) do
    raise ArgumentError, "unsupported AWS partition for notification delivery: #{partition}"
  end

  @spec opt(term(), atom() | String.t()) :: term()
  def opt(value, key) when is_map(value),
    do: Map.get(value, key) || Map.get(value, to_string(key))

  def opt(value, key) when is_list(value), do: Keyword.get(value, key)
  def opt(_value, _key), do: nil

  defp default_endpoint(service, region, partition) do
    host_service =
      case service do
        :eventbridge -> "events"
        other -> Atom.to_string(other)
      end

    "https://#{host_service}.#{region}.#{dns_suffix!(partition)}"
  end

  defp status_ok?(status, statuses) when is_integer(status) do
    Enum.member?(statuses, status)
  end

  defp put_response_body(opts, request) do
    case Keyword.get(opts, :response_sink) do
      fun when is_function(fun, 1) -> fun.(request)
      _other -> :ok
    end
  end

  defp http_client(opts) do
    case Keyword.get(opts, :http_client) do
      fun when is_function(fun, 1) -> fun
      nil -> &req_http_client/1
      other -> fn _request -> {:error, {:invalid_http_client, other}} end
    end
  end

  defp req_http_client(request) do
    request_opts = [
      method: request.method,
      url: request.url,
      headers: request.headers,
      body: request.body
    ]

    request_opts
    |> Req.request()
    |> case do
      {:ok, %Req.Response{status: status, body: body}} -> {:ok, %{status: status, body: body}}
      {:error, reason} -> {:error, reason}
    end
  rescue
    error -> {:error, error}
  end

  defp credentials!(opts) do
    configured = Keyword.get(opts, :credentials, [])

    access_key_id =
      opt(configured, :access_key_id) || opt(opts, :access_key_id) ||
        System.get_env("AWS_ACCESS_KEY_ID")

    secret_access_key =
      opt(configured, :secret_access_key) ||
        opt(opts, :secret_access_key) ||
        System.get_env("AWS_SECRET_ACCESS_KEY")

    session_token =
      opt(configured, :session_token) || opt(opts, :session_token) ||
        System.get_env("AWS_SESSION_TOKEN")

    if blank?(access_key_id) or blank?(secret_access_key) do
      raise ArgumentError,
            "AWS notification delivery requires access_key_id and secret_access_key"
    end

    %{
      access_key_id: access_key_id,
      secret_access_key: secret_access_key,
      session_token: empty_to_nil(session_token)
    }
  end

  defp normalize_headers(headers) do
    Map.new(headers, fn {name, value} ->
      {name |> to_string() |> String.downcase(), to_string(value)}
    end)
  end

  defp host_header(%URI{host: host, port: nil}), do: host
  defp host_header(%URI{host: host, scheme: "https", port: 443}), do: host
  defp host_header(%URI{host: host, scheme: "http", port: 80}), do: host
  defp host_header(%URI{host: host, port: port}), do: "#{host}:#{port}"

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, ""), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?(_value), do: false

  defp empty_to_nil(""), do: nil
  defp empty_to_nil(value), do: value
end
