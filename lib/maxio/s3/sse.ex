defmodule Maxio.S3.SSE do
  @moduledoc """
  Shared S3 SSE request-header handling.

  This module decides S3-visible SSE modes and validates SSE-C request headers.
  Actual at-rest encryption stays in `Maxio.Crypto.SSE`.
  """
  import Plug.Conn, only: [put_resp_header: 3]

  alias Maxio.BucketConfigs
  alias Maxio.Crypto
  alias Maxio.KMS
  alias Maxio.S3.Error

  @target_sse_c_prefix "x-amz-server-side-encryption-customer-"
  @copy_source_sse_c_prefix "x-amz-copy-source-server-side-encryption-customer-"
  @sse_algorithm_header "x-amz-server-side-encryption"
  @kms_key_id_header "x-amz-server-side-encryption-aws-kms-key-id"
  @kms_context_header "x-amz-server-side-encryption-context"
  @bucket_key_enabled_header "x-amz-server-side-encryption-bucket-key-enabled"
  @encrypted_checksum_key "__maxio_dsse_encrypted_checksum"
  @encrypted_object_parts_key "__maxio_dsse_encrypted_object_parts"

  @type target ::
          nil
          | String.t()
          | {:customer, binary(), String.t()}
          | {:kms, String.t(), String.t() | nil, boolean()}
          | {:kms_dsse, String.t(), String.t() | nil}

  @spec resolve_target!(Plug.Conn.req_headers(), String.t()) :: target()
  def resolve_target!(req_headers, bucket) when is_list(req_headers) do
    case parse_customer_headers!(req_headers, @target_sse_c_prefix) do
      {:customer, _raw_key, _key_md5_b64} = customer ->
        cond do
          target_kms_headers?(req_headers) ->
            raise Error.new(:invalid_argument,
                    message: "SSE-C headers cannot be combined with SSE-KMS headers"
                  )

          header(req_headers, "x-amz-server-side-encryption") in [nil, ""] ->
            customer

          true ->
            raise Error.new(:invalid_argument,
                    message: "SSE-C headers cannot be combined with x-amz-server-side-encryption"
                  )
        end

      nil ->
        case header(req_headers, "x-amz-server-side-encryption") do
          "AES256" ->
            reject_target_kms_headers!(req_headers)
            "AES256"

          "aws:kms" ->
            kms_target!(req_headers)

          "aws:kms:dsse" ->
            dsse_kms_target!(req_headers)

          nil ->
            reject_unscoped_target_kms_headers!(req_headers)
            bucket_default_sse(bucket)

          "" ->
            reject_unscoped_target_kms_headers!(req_headers)
            bucket_default_sse(bucket)

          _other ->
            raise Error.new(:invalid_argument,
                    message: "Invalid x-amz-server-side-encryption value"
                  )
        end
    end
  end

  @spec resolve_customer_read!(Plug.Conn.req_headers(), map() | nil, keyword()) ::
          {binary(), String.t()}
  def resolve_customer_read!(req_headers, envelope, opts \\ [])
      when is_list(req_headers) do
    resolve_customer_read_with_prefix!(
      req_headers,
      @target_sse_c_prefix,
      envelope,
      "SSE-C encrypted objects require customer encryption headers",
      opts
    )
  end

  @spec validate_read_headers!(
          Plug.Conn.req_headers(),
          String.t() | nil,
          map() | nil,
          keyword()
        ) :: :ok
  def validate_read_headers!(req_headers, algorithm, envelope, opts \\ [])

  def validate_read_headers!(req_headers, "SSE-C", envelope, opts)
      when is_list(req_headers) do
    resource = Keyword.get(opts, :resource)
    reject_read_algorithm_header!(req_headers, resource)

    reject_target_kms_headers!(
      req_headers,
      "SSE-KMS headers are not valid for GetObject or HeadObject"
    )

    _ = resolve_customer_read!(req_headers, envelope, opts)
    :ok
  end

  def validate_read_headers!(req_headers, _algorithm, _envelope, opts)
      when is_list(req_headers) do
    resource = Keyword.get(opts, :resource)

    cond do
      target_customer_headers?(req_headers) ->
        raise Error.new(:invalid_request,
                message: "SSE-C headers are not valid for this object",
                resource: resource
              )

      target_kms_headers?(req_headers) ->
        raise Error.new(:invalid_request,
                message: "SSE-KMS headers are not valid for GetObject or HeadObject",
                resource: resource
              )

      header_present?(req_headers, @sse_algorithm_header) ->
        raise Error.new(:invalid_request,
                message:
                  "Server-side encryption headers are not valid for GetObject or HeadObject",
                resource: resource
              )

      true ->
        :ok
    end
  end

  @spec resolve_copy_source_customer_read!(Plug.Conn.req_headers(), map() | nil, keyword()) ::
          {binary(), String.t()}
  def resolve_copy_source_customer_read!(req_headers, envelope, opts \\ [])
      when is_list(req_headers) do
    resolve_customer_read_with_prefix!(
      req_headers,
      @copy_source_sse_c_prefix,
      envelope,
      "SSE-C encrypted copy sources require customer encryption headers",
      opts
    )
  end

  @spec copy_source_customer_headers?(Plug.Conn.req_headers()) :: boolean()
  def copy_source_customer_headers?(req_headers) when is_list(req_headers),
    do: customer_headers_present?(req_headers, @copy_source_sse_c_prefix)

  defp resolve_customer_read_with_prefix!(
         req_headers,
         prefix,
         envelope,
         missing_message,
         opts
       ) do
    resource = Keyword.get(opts, :resource)

    case parse_customer_headers!(req_headers, prefix, resource: resource) do
      {:customer, raw_key, key_md5_b64} ->
        if Crypto.SSE.customer_key_matches?(envelope, raw_key) do
          {raw_key, key_md5_b64}
        else
          raise Error.new(:invalid_argument,
                  message: "The provided SSE-C key does not match the object",
                  resource: resource
                )
        end

      nil ->
        raise Error.new(:invalid_argument,
                message: missing_message,
                resource: resource
              )
    end
  end

  @spec reject_target_customer_headers!(Plug.Conn.req_headers(), String.t()) :: :ok
  def reject_target_customer_headers!(req_headers, message) when is_list(req_headers) do
    reject_customer_headers!(req_headers, @target_sse_c_prefix, message)
  end

  @spec reject_target_kms_headers!(Plug.Conn.req_headers(), String.t()) :: :ok
  def reject_target_kms_headers!(
        req_headers,
        message \\ "SSE-KMS headers are not valid for this request"
      )
      when is_list(req_headers) do
    if target_kms_headers?(req_headers) do
      raise Error.new(:invalid_request, message: message)
    end

    :ok
  end

  @spec target_customer_headers?(Plug.Conn.req_headers()) :: boolean()
  def target_customer_headers?(req_headers) when is_list(req_headers),
    do: customer_headers_present?(req_headers, @target_sse_c_prefix)

  @spec target_kms_headers?(Plug.Conn.req_headers()) :: boolean()
  def target_kms_headers?(req_headers) when is_list(req_headers) do
    Enum.any?([@kms_key_id_header, @kms_context_header, @bucket_key_enabled_header], fn name ->
      header_present?(req_headers, name)
    end)
  end

  @spec reject_copy_source_customer_headers!(Plug.Conn.req_headers()) :: :ok
  def reject_copy_source_customer_headers!(req_headers) when is_list(req_headers) do
    reject_customer_headers!(
      req_headers,
      @copy_source_sse_c_prefix,
      "SSE-C copy source decryption is not implemented"
    )
  end

  @spec explicit_target?(Plug.Conn.req_headers()) :: boolean()
  def explicit_target?(req_headers) when is_list(req_headers) do
    case header(req_headers, "x-amz-server-side-encryption") do
      nil ->
        customer_headers_present?(req_headers, @target_sse_c_prefix) or
          target_kms_headers?(req_headers)

      "" ->
        customer_headers_present?(req_headers, @target_sse_c_prefix) or
          target_kms_headers?(req_headers)

      _ ->
        true
    end
  end

  @spec storage_algorithm(target()) :: String.t() | nil
  def storage_algorithm(nil), do: nil
  def storage_algorithm({:customer, _raw_key, _key_md5_b64}), do: "SSE-C"
  def storage_algorithm({:kms, _key_id, _context_b64, _bucket_key_enabled}), do: "aws:kms"
  def storage_algorithm({:kms_dsse, _key_id, _context_b64}), do: "aws:kms:dsse"
  def storage_algorithm(alg), do: alg

  @spec encrypted?(target() | String.t() | nil) :: boolean()
  def encrypted?(nil), do: false
  def encrypted?({:customer, _raw_key, _key_md5_b64}), do: true
  def encrypted?({:kms, _key_id, _context_b64, _bucket_key_enabled}), do: true
  def encrypted?({:kms_dsse, _key_id, _context_b64}), do: true
  def encrypted?("SSE-C"), do: true
  def encrypted?("AES256"), do: true
  def encrypted?("aws:kms"), do: true
  def encrypted?("aws:kms:dsse"), do: true
  def encrypted?(_other), do: false

  @spec customer?(target() | String.t() | nil) :: boolean()
  def customer?({:customer, _raw_key, _key_md5_b64}), do: true
  def customer?("SSE-C"), do: true
  def customer?(_other), do: false

  @spec kms?(target() | String.t() | nil) :: boolean()
  def kms?({:kms, _key_id, _context_b64, _bucket_key_enabled}), do: true
  def kms?({:kms_dsse, _key_id, _context_b64}), do: true
  def kms?("aws:kms"), do: true
  def kms?("aws:kms:dsse"), do: true
  def kms?(_other), do: false

  @spec kms_key_id(target() | map() | nil) :: String.t() | nil
  def kms_key_id({:kms, key_id, _context_b64, _bucket_key_enabled}), do: key_id
  def kms_key_id({:kms_dsse, key_id, _context_b64}), do: key_id

  def kms_key_id(%{} = envelope),
    do: Map.get(envelope, :kms_key_id) || Map.get(envelope, "kms_key_id")

  def kms_key_id(_target), do: nil

  @spec kms_encryption_context(target() | map() | nil) :: String.t() | nil
  def kms_encryption_context({:kms, _key_id, context_b64, _bucket_key_enabled}), do: context_b64
  def kms_encryption_context({:kms_dsse, _key_id, context_b64}), do: context_b64

  def kms_encryption_context(%{} = envelope),
    do:
      Map.get(envelope, :kms_encryption_context_b64) ||
        Map.get(envelope, "kms_encryption_context_b64")

  def kms_encryption_context(_target), do: nil

  @spec kms_bucket_key_enabled?(target() | map() | nil) :: boolean()
  def kms_bucket_key_enabled?({:kms, _key_id, _context_b64, enabled?}), do: enabled?

  def kms_bucket_key_enabled?(%{} = envelope),
    do:
      Map.get(envelope, :bucket_key_enabled) ||
        Map.get(envelope, "bucket_key_enabled") ||
        false

  def kms_bucket_key_enabled?(_target), do: false

  @spec checksum_for_storage(map(), String.t() | nil, map() | nil) :: map()
  def checksum_for_storage(checksum, algorithm, envelope)

  def checksum_for_storage(%{} = checksum, "aws:kms:dsse", %{} = envelope) do
    cond do
      map_size(checksum) == 0 ->
        %{}

      encrypted_checksum?(checksum) ->
        checksum

      true ->
        %{
          @encrypted_checksum_key =>
            Crypto.SSE.encrypt_metadata_with_dsse_kms_key(checksum, envelope, "checksum")
        }
    end
  end

  def checksum_for_storage(%{} = checksum, _algorithm, _envelope), do: checksum
  def checksum_for_storage(_checksum, _algorithm, _envelope), do: %{}

  @spec visible_checksum_metadata(map() | struct() | nil) :: map()
  def visible_checksum_metadata(%{
        sse_algorithm: algorithm,
        sse_envelope: envelope,
        checksum: checksum
      }) do
    visible_checksum_metadata(checksum || %{}, algorithm, envelope)
  end

  def visible_checksum_metadata(%{} = checksum), do: checksum
  def visible_checksum_metadata(_other), do: %{}

  @spec visible_checksum_metadata(map() | nil, String.t() | nil, map() | nil) :: map()
  def visible_checksum_metadata(%{} = checksum, "aws:kms:dsse", %{} = envelope) do
    case encrypted_metadata(checksum, @encrypted_checksum_key) do
      nil -> checksum
      encrypted -> Crypto.SSE.decrypt_metadata_with_dsse_kms_key(encrypted, envelope, "checksum")
    end
  end

  def visible_checksum_metadata(%{} = checksum, _algorithm, _envelope), do: checksum
  def visible_checksum_metadata(_checksum, _algorithm, _envelope), do: %{}

  @spec object_parts_for_storage(map(), String.t() | nil, map() | nil) :: map()
  def object_parts_for_storage(object_parts, algorithm, envelope)

  def object_parts_for_storage(%{} = object_parts, "aws:kms:dsse", %{} = envelope) do
    cond do
      map_size(object_parts) == 0 ->
        %{}

      encrypted_object_parts?(object_parts) ->
        object_parts

      true ->
        %{
          @encrypted_object_parts_key =>
            Crypto.SSE.encrypt_metadata_with_dsse_kms_key(object_parts, envelope, "object_parts")
        }
    end
  end

  def object_parts_for_storage(%{} = object_parts, _algorithm, _envelope), do: object_parts
  def object_parts_for_storage(_object_parts, _algorithm, _envelope), do: %{}

  @spec visible_object_parts(map() | struct() | nil) :: map()
  def visible_object_parts(%{
        sse_algorithm: algorithm,
        sse_envelope: envelope,
        object_parts: object_parts
      }) do
    visible_object_parts(object_parts || %{}, algorithm, envelope)
  end

  def visible_object_parts(%{} = object_parts), do: object_parts
  def visible_object_parts(_other), do: %{}

  @spec visible_object_parts(map() | nil, String.t() | nil, map() | nil) :: map()
  def visible_object_parts(%{} = object_parts, "aws:kms:dsse", %{} = envelope) do
    case encrypted_metadata(object_parts, @encrypted_object_parts_key) do
      nil ->
        object_parts

      encrypted ->
        Crypto.SSE.decrypt_metadata_with_dsse_kms_key(encrypted, envelope, "object_parts")
    end
  end

  def visible_object_parts(%{} = object_parts, _algorithm, _envelope), do: object_parts
  def visible_object_parts(_object_parts, _algorithm, _envelope), do: %{}

  @spec customer_key(target()) :: binary() | nil
  def customer_key({:customer, raw_key, _key_md5_b64}), do: raw_key
  def customer_key(_target), do: nil

  @spec customer_key_md5(target() | map() | nil) :: String.t() | nil
  def customer_key_md5({:customer, _raw_key, key_md5_b64}), do: key_md5_b64

  def customer_key_md5(%{} = envelope),
    do: Map.get(envelope, :customer_key_md5_b64) || Map.get(envelope, "customer_key_md5_b64")

  def customer_key_md5(_target), do: nil

  @spec put_response_header(Plug.Conn.t(), target() | String.t() | nil) :: Plug.Conn.t()
  def put_response_header(conn, nil), do: conn

  def put_response_header(conn, {:customer, _raw_key, key_md5_b64}) do
    put_customer_response_headers(conn, key_md5_b64)
  end

  def put_response_header(conn, {:kms, key_id, _context_b64, bucket_key_enabled}) do
    put_kms_response_headers(conn, key_id, bucket_key_enabled)
  end

  def put_response_header(conn, {:kms_dsse, key_id, _context_b64}) do
    put_dsse_kms_response_headers(conn, key_id)
  end

  def put_response_header(conn, "SSE-C") do
    put_resp_header(conn, "x-amz-server-side-encryption-customer-algorithm", "AES256")
  end

  def put_response_header(conn, "aws:kms") do
    put_kms_response_headers(conn, nil, false)
  end

  def put_response_header(conn, "aws:kms:dsse") do
    put_dsse_kms_response_headers(conn, nil)
  end

  def put_response_header(conn, alg),
    do: put_resp_header(conn, "x-amz-server-side-encryption", alg)

  @spec put_response_header(Plug.Conn.t(), String.t() | nil, map() | nil) :: Plug.Conn.t()
  def put_response_header(conn, "SSE-C", envelope) do
    put_customer_response_headers(conn, customer_key_md5(envelope))
  end

  def put_response_header(conn, "aws:kms", envelope) do
    put_kms_response_headers(conn, kms_key_id(envelope), kms_bucket_key_enabled?(envelope))
  end

  def put_response_header(conn, "aws:kms:dsse", envelope) do
    put_dsse_kms_response_headers(conn, kms_key_id(envelope))
  end

  def put_response_header(conn, alg, _envelope), do: put_response_header(conn, alg)

  defp reject_customer_headers!(req_headers, prefix, message) do
    has_customer_header? =
      customer_headers_present?(req_headers, prefix)

    if has_customer_header? do
      raise Error.new(:not_implemented, message: message)
    end

    :ok
  end

  defp bucket_default_sse(bucket) do
    case BucketConfigs.get(bucket, :encryption) do
      {:ok, %{"algorithm" => "AES256"}} -> "AES256"
      {:ok, %{"algorithm" => "aws:kms"} = cfg} -> bucket_default_kms_target(cfg)
      {:ok, %{"algorithm" => "aws:kms:dsse"} = cfg} -> bucket_default_dsse_kms_target(cfg)
      _ -> nil
    end
  end

  defp bucket_default_kms_target(cfg) do
    key_id =
      case Map.get(cfg, "kms_key_id") do
        key_id when is_binary(key_id) and key_id != "" -> key_id
        _other -> KMS.default_key_id()
      end

    {:kms, key_id, nil, Map.get(cfg, "bucket_key_enabled", false)}
  end

  defp bucket_default_dsse_kms_target(cfg) do
    key_id =
      case Map.get(cfg, "kms_key_id") do
        key_id when is_binary(key_id) and key_id != "" -> key_id
        _other -> KMS.default_key_id()
      end

    {:kms_dsse, key_id, nil}
  end

  defp kms_target!(req_headers) do
    key_id =
      case header(req_headers, @kms_key_id_header) do
        nil -> KMS.default_key_id()
        "" -> KMS.default_key_id()
        value -> value
      end

    context_b64 = normalize_kms_context!(header(req_headers, @kms_context_header))

    bucket_key_enabled =
      parse_bucket_key_enabled!(header(req_headers, @bucket_key_enabled_header))

    {:kms, key_id, context_b64, bucket_key_enabled}
  end

  defp dsse_kms_target!(req_headers) do
    key_id =
      case header(req_headers, @kms_key_id_header) do
        nil -> KMS.default_key_id()
        "" -> KMS.default_key_id()
        value -> value
      end

    context_b64 = normalize_kms_context!(header(req_headers, @kms_context_header))

    if parse_bucket_key_enabled!(header(req_headers, @bucket_key_enabled_header)) do
      raise Error.new(:invalid_argument,
              message: "S3 Bucket Keys are not supported with DSSE-KMS"
            )
    end

    {:kms_dsse, key_id, context_b64}
  end

  defp normalize_kms_context!(nil), do: nil
  defp normalize_kms_context!(""), do: nil

  defp normalize_kms_context!(context_b64) do
    with {:ok, decoded} <- Base.decode64(context_b64),
         {:ok, %{} = _json} <- Jason.decode(decoded) do
      Base.encode64(decoded)
    else
      {:ok, _not_object} ->
        raise Error.new(:invalid_argument,
                message: "x-amz-server-side-encryption-context must decode to a JSON object"
              )

      _other ->
        raise Error.new(:invalid_argument,
                message: "x-amz-server-side-encryption-context must be base64-encoded UTF-8 JSON"
              )
    end
  end

  defp parse_bucket_key_enabled!(nil), do: false
  defp parse_bucket_key_enabled!(""), do: false
  defp parse_bucket_key_enabled!("true"), do: true
  defp parse_bucket_key_enabled!("false"), do: false

  defp parse_bucket_key_enabled!(_other) do
    raise Error.new(:invalid_argument,
            message: "x-amz-server-side-encryption-bucket-key-enabled must be true or false"
          )
  end

  defp reject_unscoped_target_kms_headers!(req_headers) do
    if target_kms_headers?(req_headers) do
      raise Error.new(:invalid_argument,
              message:
                "SSE-KMS key id, encryption context, and bucket-key headers require x-amz-server-side-encryption: aws:kms or aws:kms:dsse"
            )
    end

    :ok
  end

  defp reject_read_algorithm_header!(req_headers, resource) do
    if header_present?(req_headers, @sse_algorithm_header) do
      raise Error.new(:invalid_request,
              message: "Server-side encryption headers are not valid for GetObject or HeadObject",
              resource: resource
            )
    end

    :ok
  end

  defp header_present?(req_headers, name) do
    needle = String.downcase(name)

    Enum.any?(req_headers, fn {header_name, _value} ->
      String.downcase(to_string(header_name)) == needle
    end)
  end

  defp header(req_headers, name) do
    needle = String.downcase(name)
    matches = matching_header_values(req_headers, needle)

    case matches do
      [] ->
        nil

      [value] ->
        normalize_header_value(value)

      _many ->
        raise Error.new(:invalid_argument, message: "Duplicate #{name} header")
    end
  end

  defp customer_headers_present?(req_headers, prefix) do
    Enum.any?(req_headers, fn {name, _value} ->
      String.starts_with?(String.downcase(to_string(name)), prefix)
    end)
  end

  defp encrypted_checksum?(%{} = checksum),
    do: is_map(encrypted_metadata(checksum, @encrypted_checksum_key))

  defp encrypted_object_parts?(%{} = object_parts),
    do: is_map(encrypted_metadata(object_parts, @encrypted_object_parts_key))

  defp encrypted_metadata(%{} = map, key), do: Map.get(map, key)

  defp parse_customer_headers!(req_headers, prefix, opts \\ []) do
    resource = Keyword.get(opts, :resource)

    if customer_headers_present?(req_headers, prefix) do
      algorithm = header(req_headers, prefix <> "algorithm")
      key_b64 = header(req_headers, prefix <> "key")
      key_md5_b64 = header(req_headers, prefix <> "key-md5")

      missing =
        [
          {algorithm, prefix <> "algorithm"},
          {key_b64, prefix <> "key"},
          {key_md5_b64, prefix <> "key-md5"}
        ]
        |> Enum.filter(fn {value, _name} -> value in [nil, ""] end)
        |> Enum.map(fn {_value, name} -> name end)

      if missing != [] do
        raise Error.new(:invalid_argument,
                message: "Missing required SSE-C header(s): #{Enum.join(missing, ", ")}",
                resource: resource
              )
      end

      if algorithm != "AES256" do
        raise Error.new(:invalid_argument,
                message: "Invalid SSE-C algorithm; only AES256 is supported",
                resource: resource
              )
      end

      raw_key = decode_customer_key!(key_b64, resource)
      key_md5 = decode_customer_key_md5!(key_md5_b64, resource)
      expected_md5 = :crypto.hash(:md5, raw_key)

      unless byte_size(key_md5) == byte_size(expected_md5) and
               Plug.Crypto.secure_compare(key_md5, expected_md5) do
        raise Error.new(:bad_digest,
                message: "The SSE-C customer key MD5 does not match the supplied key",
                resource: resource
              )
      end

      {:customer, raw_key, Base.encode64(expected_md5)}
    end
  end

  defp decode_customer_key!(key_b64, resource) do
    case Base.decode64(key_b64) do
      {:ok, raw_key} when byte_size(raw_key) == 32 ->
        raw_key

      {:ok, _wrong_size} ->
        raise Error.new(:invalid_argument,
                message: "SSE-C customer key must decode to 256 bits",
                resource: resource
              )

      :error ->
        raise Error.new(:invalid_argument,
                message: "SSE-C customer key must be valid base64",
                resource: resource
              )
    end
  end

  defp decode_customer_key_md5!(key_md5_b64, resource) do
    case Base.decode64(key_md5_b64) do
      {:ok, key_md5} when byte_size(key_md5) == 16 ->
        key_md5

      {:ok, _wrong_size} ->
        raise Error.new(:bad_digest,
                message: "SSE-C customer key MD5 must decode to 128 bits",
                resource: resource
              )

      :error ->
        raise Error.new(:bad_digest,
                message: "SSE-C customer key MD5 must be valid base64",
                resource: resource
              )
    end
  end

  defp matching_header_values(req_headers, needle) do
    Enum.reduce(req_headers, [], fn {header_name, value}, acc ->
      if String.downcase(to_string(header_name)) == needle, do: [value | acc], else: acc
    end)
    |> Enum.reverse()
  end

  defp normalize_header_value(nil), do: nil

  defp normalize_header_value(value) do
    value
    |> to_string()
    |> String.trim()
  end

  defp put_customer_response_headers(conn, nil) do
    put_resp_header(conn, "x-amz-server-side-encryption-customer-algorithm", "AES256")
  end

  defp put_customer_response_headers(conn, key_md5_b64) do
    conn
    |> put_resp_header("x-amz-server-side-encryption-customer-algorithm", "AES256")
    |> put_resp_header("x-amz-server-side-encryption-customer-key-md5", key_md5_b64)
  end

  defp put_kms_response_headers(conn, key_id, bucket_key_enabled) do
    conn
    |> put_resp_header("x-amz-server-side-encryption", "aws:kms")
    |> maybe_put_kms_key_id(key_id)
    |> maybe_put_bucket_key_enabled(bucket_key_enabled)
  end

  defp put_dsse_kms_response_headers(conn, key_id) do
    conn
    |> put_resp_header("x-amz-server-side-encryption", "aws:kms:dsse")
    |> maybe_put_kms_key_id(key_id)
  end

  defp maybe_put_kms_key_id(conn, key_id) when is_binary(key_id) and key_id != "",
    do: put_resp_header(conn, @kms_key_id_header, key_id)

  defp maybe_put_kms_key_id(conn, _key_id), do: conn

  defp maybe_put_bucket_key_enabled(conn, true),
    do: put_resp_header(conn, @bucket_key_enabled_header, "true")

  defp maybe_put_bucket_key_enabled(conn, _enabled?), do: conn
end
