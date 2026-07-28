defmodule MaxioWeb.ConsoleDirectMultipartUploadForm do
  @moduledoc """
  Validates Console browser-direct multipart upload advanced fields.

  The browser only receives short-lived presigned S3 requests. This module keeps
  the accepted S3 semantics explicit so direct-upload URLs cannot gain arbitrary
  object headers after they have been signed.
  """

  alias Maxio.Metadata
  alias Maxio.S3.{Checksum, Error, StorageClass}
  alias Maxio.Tags

  @max_field_value_size 4_096
  @content_md5_bytes 16
  @sse_customer_key_bytes 32
  @system_header_fields [
    {"cache_control", "cache-control"},
    {"content_disposition", "content-disposition"},
    {"content_encoding", "content-encoding"},
    {"expires", "expires"}
  ]
  @sse_algorithm_options [
    {"None", ""},
    {"AES256", "AES256"},
    {"aws:kms", "aws:kms"},
    {"aws:kms:dsse", "aws:kms:dsse"}
  ]
  @checksum_algorithm_options [
    {"Default", ""},
    {"CRC32", "CRC32"},
    {"CRC32C", "CRC32C"},
    {"CRC64NVME", "CRC64NVME"},
    {"SHA1", "SHA1"},
    {"SHA256", "SHA256"}
  ]
  @checksum_type_options [
    {"Default", ""},
    {"FULL_OBJECT", "FULL_OBJECT"},
    {"COMPOSITE", "COMPOSITE"}
  ]

  @type parsed :: %{
          required(:create_headers) => [{String.t(), String.t()}],
          required(:request_headers) => [{String.t(), String.t()}],
          required(:request_payer) => boolean(),
          required(:sse_customer_key_required) => boolean()
        }

  @spec storage_class_options() :: [{String.t(), String.t()}]
  def storage_class_options do
    [{"Default", ""} | Enum.map(StorageClass.valid_values(), &{&1, &1})]
  end

  @spec sse_algorithm_options() :: [{String.t(), String.t()}]
  def sse_algorithm_options, do: @sse_algorithm_options

  @spec checksum_algorithm_options() :: [{String.t(), String.t()}]
  def checksum_algorithm_options, do: @checksum_algorithm_options

  @spec checksum_type_options() :: [{String.t(), String.t()}]
  def checksum_type_options, do: @checksum_type_options

  @spec parse(map(), String.t()) :: {:ok, parsed()} | {:error, atom()}
  def parse(params, content_type) when is_map(params) and is_binary(content_type) do
    with {:ok, headers} <- add_system_headers([{"content-type", content_type}], params),
         {:ok, headers} <- add_storage_class(headers, params),
         {:ok, headers} <- add_metadata(headers, params),
         {:ok, headers} <- add_tagging(headers, params),
         {:ok, headers} <- add_sse(headers, params),
         {:ok, headers} <- add_checksum(headers, params),
         {:ok, sse_customer_headers} <- sse_customer_headers(params),
         {:ok, request_payer} <- parse_request_payer(Map.get(params, "request_payer")) do
      request_payer_headers =
        if request_payer, do: [{"x-amz-request-payer", "requester"}], else: []

      request_headers = request_payer_headers ++ sse_customer_headers

      {:ok,
       %{
         create_headers: headers ++ request_payer_headers,
         request_headers: request_headers,
         request_payer: request_payer,
         sse_customer_key_required: sse_customer_headers != []
       }}
    end
  end

  def parse(_params, _content_type), do: {:error, :invalid_field}

  @spec sse_customer_headers(map()) :: {:ok, [{String.t(), String.t()}]} | {:error, :invalid_sse}
  def sse_customer_headers(params) when is_map(params) do
    with {:ok, customer_key} <- optional_string(Map.get(params, "sse_customer_key")),
         {:ok, customer_key_md5} <- optional_string(Map.get(params, "sse_customer_key_md5")) do
      cond do
        customer_key == "" and customer_key_md5 == "" ->
          {:ok, []}

        customer_key == "" ->
          {:error, :invalid_sse}

        true ->
          customer_headers(customer_key, customer_key_md5)
      end
    else
      {:error, :invalid_field} -> {:error, :invalid_sse}
    end
  end

  def sse_customer_headers(_params), do: {:error, :invalid_sse}

  defp add_system_headers(headers, params) do
    Enum.reduce_while(@system_header_fields, {:ok, headers}, fn {param, header}, {:ok, acc} ->
      with {:ok, value} <- optional_string(Map.get(params, param)),
           :ok <- validate_optional_plain_value(value) do
        case value do
          "" -> {:cont, {:ok, acc}}
          value -> {:cont, {:ok, acc ++ [{header, value}]}}
        end
      else
        _error -> {:halt, {:error, :invalid_field}}
      end
    end)
  end

  defp add_storage_class(headers, params) do
    with {:ok, raw} <- optional_string(Map.get(params, "storage_class")) do
      case raw do
        "" ->
          {:ok, headers}

        raw ->
          storage_class = StorageClass.parse!(raw)
          {:ok, headers ++ [{"x-amz-storage-class", storage_class}]}
      end
    else
      {:error, :invalid_field} -> {:error, :invalid_storage_class}
    end
  rescue
    _error in [Error] -> {:error, :invalid_storage_class}
  end

  defp add_metadata(headers, params) do
    with {:ok, raw} <- optional_string(Map.get(params, "metadata")) do
      case raw do
        "" ->
          {:ok, headers}

        raw ->
          with {:ok, metadata_headers} <- raw_metadata(raw),
               :ok <- validate_metadata_headers(metadata_headers) do
            {:ok, headers ++ metadata_headers}
          else
            _error -> {:error, :invalid_metadata}
          end
      end
    else
      {:error, :invalid_field} -> {:error, :invalid_metadata}
    end
  end

  defp raw_metadata(raw) do
    raw
    |> String.split(~r/\r?\n/, trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.reduce_while({:ok, [], MapSet.new()}, fn line, {:ok, acc, seen} ->
      with {:ok, name, value} <- raw_metadata_line(line),
           :ok <- validate_metadata_name(name),
           :ok <- validate_plain_value(value),
           false <- MapSet.member?(seen, name) do
        {:cont, {:ok, acc ++ [{"x-amz-meta-" <> name, value}], MapSet.put(seen, name)}}
      else
        true -> {:halt, {:error, :invalid_metadata}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, metadata_headers, _seen} -> {:ok, metadata_headers}
      {:error, reason} -> {:error, reason}
    end
  end

  defp raw_metadata_line(line) do
    case String.split(line, "=", parts: 2) do
      [raw_name, raw_value] ->
        with {:ok, name} <- normalize_metadata_name(raw_name) do
          value = String.trim(raw_value)

          if value == "" do
            {:error, :invalid_metadata}
          else
            {:ok, name, value}
          end
        end

      _other ->
        {:error, :invalid_metadata}
    end
  end

  defp normalize_metadata_name(raw_name) do
    with {:ok, raw_name} <- required_string(raw_name) do
      name = String.downcase(raw_name)

      cond do
        String.starts_with?(name, "x-amz-meta-") ->
          {:ok, String.replace_prefix(name, "x-amz-meta-", "")}

        String.starts_with?(name, "x-amz-") or String.starts_with?(name, "x-minio-") ->
          {:error, :invalid_metadata}

        true ->
          {:ok, name}
      end
    else
      {:error, :invalid_field} -> {:error, :invalid_metadata}
    end
  end

  defp validate_metadata_name(name) do
    cond do
      name == "" ->
        {:error, :invalid_metadata}

      String.contains?(name, ["\0", "\r", "\n", "\"", ":"]) ->
        {:error, :invalid_metadata}

      not Regex.match?(~r/^[!#$%&'*+\-.^_`|~0-9a-z]+$/, name) ->
        {:error, :invalid_metadata}

      true ->
        :ok
    end
  end

  defp validate_metadata_headers(metadata_headers) do
    Metadata.validate_headers!(metadata_headers)
  rescue
    _error in [Error] -> {:error, :invalid_metadata}
  end

  defp add_tagging(headers, params) do
    with {:ok, raw} <- optional_string(Map.get(params, "tagging")) do
      case raw do
        "" ->
          {:ok, headers}

        raw ->
          with {:ok, tags} <- raw_tags(raw),
               :ok <- Tags.validate(tags, :object) do
            {:ok, headers ++ [{"x-amz-tagging", tagging_header(tags)}]}
          else
            _error -> {:error, :invalid_tag}
          end
      end
    else
      {:error, :invalid_field} -> {:error, :invalid_tag}
    end
  end

  defp raw_tags(raw) do
    tags =
      raw
      |> String.split(~r/\r?\n/, trim: true)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.map(fn line ->
        case String.split(line, "=", parts: 2) do
          [key, value] -> {String.trim(key), String.trim(value)}
          [key] -> {String.trim(key), ""}
        end
      end)

    {:ok, tags}
  end

  defp tagging_header(tags) do
    tags
    |> Enum.map(fn {key, value} ->
      URI.encode_www_form(key) <> "=" <> URI.encode_www_form(value)
    end)
    |> Enum.join("&")
  end

  defp add_sse(headers, params) do
    with {:ok, algorithm} <- optional_string(Map.get(params, "sse_algorithm")),
         {:ok, key_id} <- optional_string(Map.get(params, "sse_kms_key_id")),
         {:ok, context} <- optional_string(Map.get(params, "sse_context")),
         {:ok, customer_key} <- optional_string(Map.get(params, "sse_customer_key")),
         {:ok, customer_key_md5} <- optional_string(Map.get(params, "sse_customer_key_md5")),
         {:ok, bucket_key_enabled} <- truthy(Map.get(params, "sse_bucket_key")) do
      cond do
        customer_key != "" or customer_key_md5 != "" ->
          add_sse_customer(
            headers,
            algorithm,
            key_id,
            context,
            bucket_key_enabled,
            customer_key,
            customer_key_md5
          )

        algorithm == "" and key_id == "" and context == "" and not bucket_key_enabled ->
          {:ok, headers}

        algorithm == "" ->
          {:error, :invalid_sse}

        algorithm not in ["AES256", "aws:kms", "aws:kms:dsse"] ->
          {:error, :invalid_sse}

        algorithm == "AES256" and (key_id != "" or context != "" or bucket_key_enabled) ->
          {:error, :invalid_sse}

        algorithm == "aws:kms:dsse" and bucket_key_enabled ->
          {:error, :invalid_sse}

        key_id != "" and validate_plain_value(key_id) != :ok ->
          {:error, :invalid_sse}

        context != "" and validate_plain_value(context) != :ok ->
          {:error, :invalid_sse}

        context != "" and validate_kms_context(context) != :ok ->
          {:error, :invalid_sse}

        true ->
          headers =
            headers
            |> Kernel.++([{"x-amz-server-side-encryption", algorithm}])
            |> maybe_put_header("x-amz-server-side-encryption-aws-kms-key-id", key_id)
            |> maybe_put_header("x-amz-server-side-encryption-context", context)

          headers =
            if bucket_key_enabled do
              headers ++ [{"x-amz-server-side-encryption-bucket-key-enabled", "true"}]
            else
              headers
            end

          {:ok, headers}
      end
    else
      {:error, :invalid_field} -> {:error, :invalid_sse}
    end
  end

  defp add_sse_customer(
         headers,
         algorithm,
         key_id,
         context,
         bucket_key_enabled,
         customer_key,
         customer_key_md5
       ) do
    with true <- algorithm == "" and key_id == "" and context == "" and not bucket_key_enabled,
         {:ok, customer_headers} <- customer_headers(customer_key, customer_key_md5) do
      {:ok, headers ++ customer_headers}
    else
      _error -> {:error, :invalid_sse}
    end
  end

  defp customer_headers(customer_key, customer_key_md5) do
    with :ok <- validate_plain_value(customer_key),
         :ok <- validate_plain_value(customer_key_md5),
         {:ok, raw_key} <- decode_base64_bytes(customer_key, @sse_customer_key_bytes),
         {:ok, key_md5_b64} <- validate_customer_key_md5(raw_key, customer_key_md5) do
      {:ok,
       [
         {"x-amz-server-side-encryption-customer-algorithm", "AES256"},
         {"x-amz-server-side-encryption-customer-key", Base.encode64(raw_key)},
         {"x-amz-server-side-encryption-customer-key-md5", key_md5_b64}
       ]}
    else
      _error -> {:error, :invalid_sse}
    end
  end

  defp add_checksum(headers, params) do
    with {:ok, algorithm} <- optional_string(Map.get(params, "checksum_algorithm")),
         {:ok, checksum_type} <- optional_string(Map.get(params, "checksum_type")) do
      algorithm = String.upcase(algorithm)
      checksum_type = String.upcase(checksum_type)

      cond do
        algorithm == "" and checksum_type == "" ->
          {:ok, headers}

        algorithm == "" ->
          {:error, :invalid_checksum}

        not Enum.any?(@checksum_algorithm_options, fn {_label, value} -> value == algorithm end) ->
          {:error, :invalid_checksum}

        checksum_type not in ["", "FULL_OBJECT", "COMPOSITE"] ->
          {:error, :invalid_checksum}

        true ->
          checksum_headers =
            [{"x-amz-checksum-algorithm", algorithm}]
            |> maybe_put_header("x-amz-checksum-type", checksum_type)

          _ = Checksum.multipart_upload_intent!(checksum_headers)
          {:ok, headers ++ checksum_headers}
      end
    else
      {:error, :invalid_field} -> {:error, :invalid_checksum}
    end
  rescue
    _error in [Error] -> {:error, :invalid_checksum}
  end

  defp parse_request_payer(value) when value in [true, "true", "on", "1", "requester"],
    do: {:ok, true}

  defp parse_request_payer(value) when value in [false, nil, "", "false", "0"],
    do: {:ok, false}

  defp parse_request_payer(_value), do: {:error, :invalid_request_payer}

  defp maybe_put_header(headers, _name, ""), do: headers
  defp maybe_put_header(headers, name, value), do: headers ++ [{name, value}]

  defp validate_kms_context(context) do
    with {:ok, decoded} <- Base.decode64(context),
         {:ok, %{} = _json} <- Jason.decode(decoded) do
      :ok
    else
      _other -> {:error, :invalid_context}
    end
  end

  defp decode_base64_bytes(value, bytes) do
    case Base.decode64(value) do
      {:ok, decoded} when byte_size(decoded) == bytes -> {:ok, decoded}
      _other -> {:error, :invalid_base64}
    end
  end

  defp validate_customer_key_md5(raw_key, "") do
    {:ok, :crypto.hash(:md5, raw_key) |> Base.encode64()}
  end

  defp validate_customer_key_md5(raw_key, key_md5_b64) do
    with {:ok, provided_md5} <- decode_base64_bytes(key_md5_b64, @content_md5_bytes) do
      expected_md5 = :crypto.hash(:md5, raw_key)

      if Plug.Crypto.secure_compare(provided_md5, expected_md5) do
        {:ok, Base.encode64(expected_md5)}
      else
        {:error, :invalid_customer_key_md5}
      end
    end
  end

  defp validate_plain_value(value) do
    cond do
      byte_size(value) > @max_field_value_size -> {:error, :too_large}
      String.contains?(value, ["\0", "\r", "\n"]) -> {:error, :control_character}
      true -> :ok
    end
  end

  defp validate_optional_plain_value(""), do: :ok
  defp validate_optional_plain_value(value), do: validate_plain_value(value)

  defp truthy(value) when value in [true, "true", "on", "1", "requester"], do: {:ok, true}
  defp truthy(value) when value in [false, nil, "", "false", "0"], do: {:ok, false}
  defp truthy(_value), do: {:error, :invalid_field}

  defp optional_string(value) do
    case string_field(value) do
      {:ok, value} -> {:ok, value}
      :error -> {:error, :invalid_field}
    end
  end

  defp required_string(value) do
    case string_field(value) do
      {:ok, ""} -> {:error, :invalid_field}
      {:ok, value} -> {:ok, value}
      :error -> {:error, :invalid_field}
    end
  end

  defp string_field(value) when is_binary(value), do: {:ok, String.trim(value)}
  defp string_field(nil), do: {:ok, ""}
  defp string_field(_value), do: :error
end
