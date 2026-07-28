defmodule Maxio.Console.DirectMultipartUpload.Cors do
  @moduledoc """
  CORS helper for Console browser-direct multipart uploads.

  The helper owns only the Maxio-managed rule identified by `rule_id/0`. It
  never deletes or rewrites user rules, and it refuses to silently exceed S3's
  100-rule bucket CORS limit.
  """

  alias Maxio.{BucketConfigs, Cors}
  alias Maxio.S3.Error
  alias Maxio.S3.Handlers.Cors, as: S3Cors

  @rule_id "maxio-console-direct-multipart"
  @methods ~w(POST PUT GET DELETE)
  @allowed_headers ~w(
    content-type
    content-md5
    cache-control
    content-disposition
    content-encoding
    expires
    x-amz-*
  )
  @post_headers ~w(
    content-type
    content-md5
    cache-control
    content-disposition
    content-encoding
    expires
    x-amz-storage-class
    x-amz-meta-maxio
    x-amz-tagging
    x-amz-server-side-encryption
    x-amz-server-side-encryption-aws-kms-key-id
    x-amz-server-side-encryption-context
    x-amz-server-side-encryption-bucket-key-enabled
    x-amz-checksum-algorithm
    x-amz-checksum-type
    x-amz-request-payer
    x-amz-mp-object-size
  )
  @method_headers %{
    "POST" => @post_headers,
    "PUT" => ~w(content-type x-amz-request-payer),
    "GET" => ~w(x-amz-request-payer),
    "DELETE" => ~w(x-amz-request-payer)
  }
  @max_rules 100
  @max_age_seconds 3000

  @type ensure_status :: :updated | :unchanged
  @type error_reason ::
          :invalid_origin
          | :invalid_cors_configuration
          | :cors_rule_limit
          | :store_failed

  @spec rule_id() :: String.t()
  def rule_id, do: @rule_id

  @spec rule(String.t()) :: {:ok, map()} | {:error, :invalid_origin}
  def rule(origin) do
    with {:ok, origin} <- normalize_origin(origin) do
      {:ok,
       %{
         "id" => @rule_id,
         "allowed_origins" => [origin],
         "allowed_methods" => @methods,
         "allowed_headers" => @allowed_headers,
         "expose_headers" => ["ETag"],
         "max_age_seconds" => @max_age_seconds
       }}
    end
  end

  @spec rule!(String.t()) :: map()
  def rule!(origin) do
    case rule(origin) do
      {:ok, rule} -> rule
      {:error, reason} -> raise ArgumentError, "invalid direct multipart CORS origin: #{reason}"
    end
  end

  @spec configured?(String.t() | [map()], String.t()) :: boolean()
  def configured?(bucket, origin) when is_binary(bucket) do
    case current_rules(bucket) do
      {:ok, rules} -> configured?(rules, origin)
      {:error, _reason} -> false
    end
  end

  def configured?(rules, origin) when is_list(rules) do
    with {:ok, origin} <- normalize_origin(origin) do
      Enum.all?(@methods, fn method ->
        preflight_exposes_etag?(rules, origin, method) and
          actual_exposes_etag?(rules, origin, method)
      end)
    else
      {:error, _reason} -> false
    end
  end

  def configured?(_rules, _origin), do: false

  @spec merge([map()], String.t()) :: {:ok, [map()]} | {:error, error_reason()}
  def merge(rules, origin) when is_list(rules) do
    with {:ok, origin} <- normalize_origin(origin),
         :ok <- validate_existing_rules(rules) do
      if configured?(rules, origin) do
        {:ok, rules}
      else
        upsert_owned_rule(rules, origin)
      end
    end
  end

  def merge(_rules, _origin), do: {:error, :invalid_cors_configuration}

  @spec ensure_bucket_rule(String.t(), String.t()) ::
          {:ok, [map()], ensure_status()} | {:error, error_reason()}
  def ensure_bucket_rule(bucket, origin) when is_binary(bucket) do
    with {:ok, rules} <- current_rules(bucket),
         {:ok, merged} <- merge(rules, origin) do
      if merged == rules do
        {:ok, merged, :unchanged}
      else
        case BucketConfigs.put(bucket, :cors, merged) do
          :ok -> {:ok, merged, :updated}
          {:error, _reason} -> {:error, :store_failed}
        end
      end
    end
  end

  def ensure_bucket_rule(_bucket, _origin), do: {:error, :invalid_origin}

  defp current_rules(bucket) do
    case BucketConfigs.get(bucket, :cors) do
      :none -> {:ok, []}
      {:ok, rules} when is_list(rules) -> {:ok, rules}
      {:ok, _other} -> {:error, :invalid_cors_configuration}
    end
  end

  defp upsert_owned_rule(rules, origin) do
    existing_owned? = Enum.any?(rules, &owned_rule?/1)
    user_rules = Enum.reject(rules, &owned_rule?/1)

    cond do
      not existing_owned? and length(rules) >= @max_rules ->
        {:error, :cors_rule_limit}

      true ->
        merged = [rule!(origin) | user_rules]

        with :ok <- validate_config(merged) do
          {:ok, merged}
        end
    end
  end

  defp owned_rule?(%{"id" => @rule_id}), do: true
  defp owned_rule?(_rule), do: false

  defp preflight_exposes_etag?(rules, origin, method) do
    headers = Map.fetch!(@method_headers, method)

    case Cors.match_preflight(rules, origin, method, headers) do
      {:ok, rule} -> exposes_etag?(rule)
      :no_match -> false
    end
  end

  defp actual_exposes_etag?(rules, origin, method) do
    case Cors.match_actual(rules, origin, method) do
      {:ok, rule} -> exposes_etag?(rule)
      :no_match -> false
    end
  end

  defp exposes_etag?(rule) do
    rule
    |> Map.get("expose_headers", [])
    |> Enum.any?(&(String.downcase(&1) == "etag"))
  end

  defp validate_config(rules) do
    S3Cors.validate!(rules)
  rescue
    Error -> {:error, :invalid_cors_configuration}
  end

  defp validate_existing_rules([]), do: :ok
  defp validate_existing_rules(rules), do: validate_config(rules)

  defp normalize_origin(origin) when is_binary(origin) do
    origin = String.trim(origin)

    with %URI{
           scheme: scheme,
           host: host,
           port: port,
           path: path,
           query: nil,
           fragment: nil,
           userinfo: nil
         }
         when scheme in ["http", "https"] and is_binary(host) and host != "" and
                path in [nil, ""] <- URI.parse(origin) do
      {:ok, scheme <> "://" <> origin_host(host) <> origin_port(scheme, port)}
    else
      _other -> {:error, :invalid_origin}
    end
  end

  defp normalize_origin(_origin), do: {:error, :invalid_origin}

  defp origin_host(host) do
    if String.contains?(host, ":") do
      "[" <> host <> "]"
    else
      host
    end
  end

  defp origin_port("http", port) when port in [nil, 80], do: ""
  defp origin_port("https", port) when port in [nil, 443], do: ""
  defp origin_port(_scheme, port) when is_integer(port), do: ":" <> Integer.to_string(port)
  defp origin_port(_scheme, _port), do: ""
end
