defmodule Maxio.S3.Checksum do
  @moduledoc """
  S3 upload checksum header validation.

  Supports checksum values carried in ordinary request headers and in verified
  aws-chunked trailing headers.
  """

  import Bitwise
  import Plug.Conn

  alias Maxio.S3.Error

  @type t :: %{
          checks: [check()],
          response_headers: [{String.t(), String.t()}],
          get_trailers: (-> %{String.t() => String.t()}),
          verify!: (-> :ok)
        }

  @type check :: %{
          required(:kind) =>
            {:hash, atom()} | :crc32 | :crc32c | :crc64nvme | :xxhash64 | :xxhash3 | :xxhash128,
          required(:response_header) => String.t() | nil,
          required(:context) => term(),
          optional(:expected) => binary(),
          optional(:trailer_header) => String.t(),
          optional(:actual) => binary()
        }

  @hash_algorithms %{
    "x-amz-checksum-md5" => :md5,
    "x-amz-checksum-sha1" => :sha,
    "x-amz-checksum-sha256" => :sha256,
    "x-amz-checksum-sha512" => :sha512
  }

  @supported_checksum_headers Map.keys(@hash_algorithms) ++
                                [
                                  "x-amz-checksum-crc32",
                                  "x-amz-checksum-crc32c",
                                  "x-amz-checksum-crc64nvme",
                                  "x-amz-checksum-xxhash3",
                                  "x-amz-checksum-xxhash128",
                                  "x-amz-checksum-xxhash64"
                                ]

  @composite_algorithms %{
    "ChecksumCRC32" => {:crc32, 4},
    "ChecksumCRC32C" => {:crc32c, 4},
    "ChecksumMD5" => {:hash, :md5, 16},
    "ChecksumSHA1" => {:hash, :sha, 20},
    "ChecksumSHA256" => {:hash, :sha256, 32},
    "ChecksumSHA512" => {:hash, :sha512, 64},
    "ChecksumXXHASH3" => {:xxhash3, 8},
    "ChecksumXXHASH128" => {:xxhash128, 16},
    "ChecksumXXHASH64" => {:xxhash64, 8}
  }

  @sdk_algorithm_headers %{
    "CRC32" => "x-amz-checksum-crc32",
    "CRC32C" => "x-amz-checksum-crc32c",
    "CRC64NVME" => "x-amz-checksum-crc64nvme",
    "MD5" => "x-amz-checksum-md5",
    "SHA1" => "x-amz-checksum-sha1",
    "SHA256" => "x-amz-checksum-sha256",
    "SHA512" => "x-amz-checksum-sha512",
    "XXHASH3" => "x-amz-checksum-xxhash3",
    "XXHASH128" => "x-amz-checksum-xxhash128",
    "XXHASH64" => "x-amz-checksum-xxhash64"
  }

  @object_metadata_algorithms %{
    "ChecksumCRC32" => "CRC32",
    "ChecksumCRC32C" => "CRC32C",
    "ChecksumCRC64NVME" => "CRC64NVME",
    "ChecksumMD5" => "MD5",
    "ChecksumSHA1" => "SHA1",
    "ChecksumSHA256" => "SHA256",
    "ChecksumSHA512" => "SHA512",
    "ChecksumXXHASH3" => "XXHASH3",
    "ChecksumXXHASH128" => "XXHASH128",
    "ChecksumXXHASH64" => "XXHASH64"
  }

  @composite_multipart_algorithms ~w(CRC32 CRC32C MD5 SHA1 SHA256 SHA512 XXHASH3 XXHASH128 XXHASH64)
  @full_object_multipart_algorithms ~w(CRC32 CRC32C CRC64NVME)
  @complete_modeled_headers %{
    "x-amz-checksum-crc32" => "CRC32",
    "x-amz-checksum-crc32c" => "CRC32C",
    "x-amz-checksum-crc64nvme" => "CRC64NVME",
    "x-amz-checksum-md5" => "MD5",
    "x-amz-checksum-sha1" => "SHA1",
    "x-amz-checksum-sha256" => "SHA256",
    "x-amz-checksum-sha512" => "SHA512",
    "x-amz-checksum-xxhash3" => "XXHASH3",
    "x-amz-checksum-xxhash128" => "XXHASH128",
    "x-amz-checksum-xxhash64" => "XXHASH64"
  }
  @crc32c_table_key {__MODULE__, :crc32c_table}
  @crc64nvme_table_key {__MODULE__, :crc64nvme_table}
  @u64_mask 0xFFFFFFFFFFFFFFFF
  @xxh64_prime1 0x9E3779B185EBCA87
  @xxh64_prime2 0xC2B2AE3D27D4EB4F
  @xxh64_prime3 0x165667B19E3779F9
  @xxh64_prime4 0x85EBCA77C2B2AE63
  @xxh64_prime5 0x27D4EB2F165667C5
  @xxh3_prime32_1 0x9E3779B1
  @xxh3_prime32_2 0x85EBCA77
  @xxh3_prime32_3 0xC2B2AE3D
  @xxh3_prime_mx1 0x165667919E3779F9
  @xxh3_prime_mx2 0x9FB21C651E98DF25
  @xxh3_secret <<0xB8, 0xFE, 0x6C, 0x39, 0x23, 0xA4, 0x4B, 0xBE, 0x7C, 0x01, 0x81, 0x2C, 0xF7,
                 0x21, 0xAD, 0x1C, 0xDE, 0xD4, 0x6D, 0xE9, 0x83, 0x90, 0x97, 0xDB, 0x72, 0x40,
                 0xA4, 0xA4, 0xB7, 0xB3, 0x67, 0x1F, 0xCB, 0x79, 0xE6, 0x4E, 0xCC, 0xC0, 0xE5,
                 0x78, 0x82, 0x5A, 0xD0, 0x7D, 0xCC, 0xFF, 0x72, 0x21, 0xB8, 0x08, 0x46, 0x74,
                 0xF7, 0x43, 0x24, 0x8E, 0xE0, 0x35, 0x90, 0xE6, 0x81, 0x3A, 0x26, 0x4C, 0x3C,
                 0x28, 0x52, 0xBB, 0x91, 0xC3, 0x00, 0xCB, 0x88, 0xD0, 0x65, 0x8B, 0x1B, 0x53,
                 0x2E, 0xA3, 0x71, 0x64, 0x48, 0x97, 0xA2, 0x0D, 0xF9, 0x4E, 0x38, 0x19, 0xEF,
                 0x46, 0xA9, 0xDE, 0xAC, 0xD8, 0xA8, 0xFA, 0x76, 0x3F, 0xE3, 0x9C, 0x34, 0x3F,
                 0xF9, 0xDC, 0xBB, 0xC7, 0xC7, 0x0B, 0x4F, 0x1D, 0x8A, 0x51, 0xE0, 0x4B, 0xCD,
                 0xB4, 0x59, 0x31, 0xC8, 0x9F, 0x7E, 0xC9, 0xD9, 0x78, 0x73, 0x64, 0xEA, 0xC5,
                 0xAC, 0x83, 0x34, 0xD3, 0xEB, 0xC3, 0xC5, 0x81, 0xA0, 0xFF, 0xFA, 0x13, 0x63,
                 0xEB, 0x17, 0x0D, 0xDD, 0x51, 0xB7, 0xF0, 0xDA, 0x49, 0xD3, 0x16, 0x55, 0x26,
                 0x29, 0xD4, 0x68, 0x9E, 0x2B, 0x16, 0xBE, 0x58, 0x7D, 0x47, 0xA1, 0xFC, 0x8F,
                 0xF8, 0xB8, 0xD1, 0x7A, 0xD0, 0x31, 0xCE, 0x45, 0xCB, 0x3A, 0x8F, 0x95, 0x16,
                 0x04, 0x28, 0xAF, 0xD7, 0xFB, 0xCA, 0xBB, 0x4B, 0x40, 0x7E>>
  @xxh3_secret_len 192
  @xxh3_stripe_size 64
  @xxh3_block_size 1024
  @xxh3_large_threshold 240

  @doc "Builds a checksum context from S3 upload request headers and verified trailer getter."
  @spec from_conn!(Plug.Conn.t(), (-> %{String.t() => String.t()})) :: t()
  def from_conn!(conn, get_trailers \\ fn -> %{} end) do
    headers = conn.req_headers
    unsupported = unsupported_header(headers) || unsupported_trailer_header(headers)

    if unsupported do
      raise Error.new(:not_implemented, message: "Unsupported checksum header: #{unsupported}")
    end

    validate_trailer_payload_mode!(conn, headers)
    validate_sdk_algorithm!(headers)

    checks =
      headers
      |> content_md5_check()
      |> Kernel.++(hash_checks(headers))
      |> Kernel.++(crc32_checks(headers))
      |> Kernel.++(crc32c_checks(headers))
      |> Kernel.++(crc64nvme_checks(headers))
      |> Kernel.++(xxhash3_checks(headers))
      |> Kernel.++(xxhash128_checks(headers))
      |> Kernel.++(xxhash64_checks(headers))
      |> Kernel.++(trailer_checks(headers))

    build_context(checks, get_trailers)
  end

  @doc """
  Returns true when the request carries a modeled flexible checksum request.

  A bare `x-amz-trailer` is not enough; the declared trailer must be a modeled
  checksum trailer, or the request must include a modeled checksum value header
  or `x-amz-sdk-checksum-algorithm`.
  """
  @spec flexible_body_checksum_request?(Plug.Conn.t() | [{String.t(), String.t()}]) :: boolean()
  def flexible_body_checksum_request?(%Plug.Conn{} = conn),
    do: flexible_body_checksum_request?(conn.req_headers)

  def flexible_body_checksum_request?(headers) when is_list(headers) do
    not is_nil(header(headers, "x-amz-sdk-checksum-algorithm")) or
      checksum_value_header?(headers) or
      trailer_checksum?(headers)
  end

  @doc "Parses CreateMultipartUpload checksum intent and applies S3's default MPU checksum."
  @spec multipart_upload_intent!([{String.t(), String.t()}]) :: map()
  def multipart_upload_intent!(headers) do
    algorithm = multipart_algorithm(headers)
    checksum_type = multipart_checksum_type(headers)

    cond do
      is_nil(algorithm) and is_nil(checksum_type) ->
        %{checksum_algorithm: "CRC64NVME", checksum_type: "FULL_OBJECT"}

      is_nil(algorithm) ->
        raise Error.new(:invalid_request,
                message: "x-amz-checksum-type requires x-amz-checksum-algorithm"
              )

      algorithm == "CRC64NVME" and checksum_type == "COMPOSITE" ->
        raise Error.new(:invalid_request,
                message:
                  "Checksum algorithm CRC64NVME does not support COMPOSITE multipart checksums"
              )

      algorithm == "CRC64NVME" and is_nil(checksum_type) ->
        %{checksum_algorithm: algorithm, checksum_type: "FULL_OBJECT"}

      checksum_type == "FULL_OBJECT" and algorithm in @full_object_multipart_algorithms ->
        %{checksum_algorithm: algorithm, checksum_type: "FULL_OBJECT"}

      checksum_type == "FULL_OBJECT" ->
        raise Error.new(:invalid_request,
                message:
                  "Checksum algorithm #{algorithm} does not support FULL_OBJECT multipart checksums"
              )

      algorithm in @composite_multipart_algorithms ->
        %{checksum_algorithm: algorithm, checksum_type: checksum_type || "COMPOSITE"}

      true ->
        raise Error.new(:invalid_request,
                message:
                  "Checksum algorithm #{algorithm} does not support COMPOSITE multipart checksums"
              )
    end
  end

  @doc "Adds CreateMultipartUpload checksum response headers when checksum intent exists."
  @spec put_multipart_upload_response_headers(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def put_multipart_upload_response_headers(conn, %{checksum_algorithm: nil}), do: conn

  def put_multipart_upload_response_headers(conn, %{checksum_algorithm: algorithm} = upload) do
    checksum_type =
      Map.get(upload, :checksum_type) || Map.get(upload, "checksum_type") || "COMPOSITE"

    conn
    |> put_resp_header("x-amz-checksum-algorithm", algorithm)
    |> put_resp_header("x-amz-checksum-type", checksum_type)
  end

  @doc "Parses CompleteMultipartUpload checksum headers supported by the full-object MPU path."
  @spec complete_multipart_request!(Plug.Conn.t() | [{String.t(), String.t()}], map()) :: map()
  def complete_multipart_request!(conn_or_headers, trailers \\ %{})

  def complete_multipart_request!(%Plug.Conn{} = conn, trailers) do
    validate_trailer_payload_mode!(conn, conn.req_headers)
    complete_multipart_request!(conn.req_headers, trailers)
  end

  def complete_multipart_request!(headers, trailers) when is_list(headers) and is_map(trailers) do
    cond do
      complete_unsupported_trailer_header(headers) ->
        header = complete_unsupported_trailer_header(headers)

        raise Error.new(:not_implemented,
                message: "CompleteMultipartUpload checksum trailer #{header} is not implemented"
              )

      complete_unsupported_header(headers) ->
        header = complete_unsupported_header(headers)

        raise Error.new(:not_implemented,
                message: "CompleteMultipartUpload checksum header #{header} is not implemented"
              )

      true ->
        checksum_type = multipart_checksum_type(headers)

        checksum_headers =
          complete_modeled_headers(headers) ++ complete_trailer_headers(headers, trailers)

        if length(checksum_headers) > 1 do
          raise Error.new(:invalid_request,
                  message: "Only one CompleteMultipartUpload object checksum header is allowed"
                )
        end

        {algorithm, value} =
          case checksum_headers do
            [{algorithm, value}] -> {algorithm, value}
            [] -> {nil, nil}
          end

        %{
          checksum_algorithm: algorithm,
          checksum_value: value,
          checksum_type: checksum_type,
          object_size: multipart_object_size(headers)
        }
    end
  end

  @doc "Builds a checksum context that computes a part checksum for a CreateMultipartUpload algorithm."
  @spec for_multipart_algorithm!(String.t() | nil) :: t()
  def for_multipart_algorithm!(nil), do: empty_context()

  def for_multipart_algorithm!(algorithm) when is_binary(algorithm) do
    algorithm = normalize_algorithm!(algorithm)
    build_context([check_for_algorithm!(algorithm)], fn -> %{} end)
  end

  @doc "Builds a full-object MPU checksum context, optionally with the Complete header's expected value."
  @spec full_object_multipart_context!(String.t(), map()) :: t()
  def full_object_multipart_context!(algorithm, request \\ %{}) when is_binary(algorithm) do
    algorithm = normalize_algorithm!(algorithm)

    unless full_object_multipart_algorithm?(algorithm) do
      raise Error.new(:not_implemented,
              message: "Multipart FULL_OBJECT checksum algorithm #{algorithm} is not implemented"
            )
    end

    check = check_for_algorithm!(algorithm)

    check =
      case Map.get(request, :checksum_value) || Map.get(request, "checksum_value") do
        nil -> check
        value -> Map.put(check, :expected, decode_base64!(value, expected_size(check.kind)))
      end

    build_context([check], fn -> %{} end)
  end

  @doc "True when Maxio can compute a multipart FULL_OBJECT checksum for the algorithm."
  @spec full_object_multipart_algorithm?(String.t() | nil) :: boolean()
  def full_object_multipart_algorithm?(nil), do: false

  def full_object_multipart_algorithm?(algorithm) when is_binary(algorithm),
    do: normalize_algorithm!(algorithm) in @full_object_multipart_algorithms

  @doc "Ensures UploadPart checksum metadata matches the CreateMultipartUpload algorithm."
  @spec with_multipart_algorithm!(t(), String.t() | nil) :: t()
  def with_multipart_algorithm!(checksum, nil), do: checksum

  def with_multipart_algorithm!(%{checks: checks} = checksum, algorithm)
      when is_binary(algorithm) do
    algorithm = normalize_algorithm!(algorithm)
    expected_header = algorithm_header!(algorithm)
    modeled_headers = modeled_response_headers(checks)

    cond do
      modeled_headers == [] ->
        checks = checks ++ [check_for_algorithm!(algorithm)]

        %{
          checksum
          | checks: checks,
            response_headers: response_headers(checks),
            verify!: verify_fun(checks, checksum.get_trailers)
        }

      modeled_headers == [expected_header] ->
        checksum

      true ->
        raise Error.new(:invalid_request,
                message: "UploadPart checksum algorithm must match CreateMultipartUpload"
              )
    end
  end

  @doc "Returns the durable S3 checksum metadata field for a multipart checksum algorithm."
  @spec multipart_algorithm_field!(String.t()) :: String.t()
  def multipart_algorithm_field!(algorithm) when is_binary(algorithm) do
    algorithm |> normalize_algorithm!() |> algorithm_header!() |> metadata_key()
  end

  @doc "Returns a checksum context that reads verified aws-chunked trailer headers from `get_trailers`."
  @spec with_trailer_getter(t(), (-> %{String.t() => String.t()})) :: t()
  def with_trailer_getter(%{checks: checks} = checksum, get_trailers) do
    %{
      checksum
      | get_trailers: get_trailers,
        verify!: verify_fun(checks, get_trailers)
    }
  end

  defp build_context(checks, get_trailers) do
    %{
      checks: checks,
      get_trailers: get_trailers,
      response_headers: response_headers(checks),
      verify!: verify_fun(checks, get_trailers)
    }
  end

  defp empty_context do
    build_context([], fn -> %{} end)
  end

  @doc "Adds S3's default full-object CRC64NVME checksum when no modeled checksum is supplied."
  @spec default_crc64nvme(t()) :: t()
  def default_crc64nvme(%{checks: checks} = checksum) do
    if Enum.any?(checks, &modeled_response_check?/1) do
      checksum
    else
      check = %{
        response_header: "x-amz-checksum-crc64nvme",
        kind: :crc64nvme,
        context: 0
      }

      checks = checks ++ [check]

      %{
        checksum
        | checks: checks,
          response_headers: response_headers(checks),
          verify!: verify_fun(checks, checksum.get_trailers)
      }
    end
  end

  defp verify_fun(checks, get_trailers) do
    fn ->
      trailers = get_trailers.()
      if checks == [], do: :ok, else: verify!(finalize_checks(checks, trailers))
    end
  end

  defp modeled_response_check?(%{response_header: header}) when is_binary(header),
    do: String.starts_with?(header, "x-amz-checksum-")

  defp modeled_response_check?(_check), do: false

  @doc "Rejects ad-hoc checksum request headers on UploadPartCopy; copied-part checksums come from MPU intent."
  @spec reject_upload_part_headers!(Plug.Conn.t()) :: :ok
  def reject_upload_part_headers!(conn) do
    cond do
      checksum_headers?(conn.req_headers) ->
        raise Error.new(:invalid_request,
                message:
                  "UploadPartCopy checksum request headers are not valid; use CreateMultipartUpload checksum intent"
              )

      trailer_checksum?(conn.req_headers) ->
        raise Error.new(:invalid_request,
                message: "UploadPartCopy checksum trailers are not valid"
              )

      true ->
        :ok
    end
  end

  @doc """
  Parses the optional CopyObject checksum algorithm request.

  CopyObject supports `x-amz-checksum-algorithm` as a request to compute a new
  checksum for the destination object. Algorithm-specific checksum value
  headers, SDK checksum headers, and trailers are rejected because a
  server-side copy request has no client-supplied payload to validate.
  """
  @spec copy_object_algorithm!([{String.t(), String.t()}]) :: String.t() | nil
  def copy_object_algorithm!(headers) do
    cond do
      copy_checksum_value_headers?(headers) ->
        raise Error.new(:invalid_request,
                message:
                  "CopyObject checksum validation headers are not valid; use x-amz-checksum-algorithm"
              )

      trailer_checksum?(headers) ->
        raise Error.new(:invalid_request,
                message: "CopyObject checksum trailers are not valid"
              )

      true ->
        case header(headers, "x-amz-checksum-algorithm") do
          nil -> nil
          raw -> normalize_copy_object_algorithm!(raw)
        end
    end
  end

  @doc "Builds a destination checksum context for a CopyObject algorithm request."
  @spec for_copy_object_algorithm!(String.t()) :: t()
  def for_copy_object_algorithm!(algorithm) when is_binary(algorithm) do
    algorithm = normalize_copy_object_algorithm!(algorithm)
    build_context([check_for_algorithm!(algorithm)], fn -> %{} end)
  end

  @doc """
  Builds a destination checksum context from source object metadata.

  CopyObject without `x-amz-checksum-algorithm` copies the source checksum
  algorithm, but the destination checksum is calculated over the single copied
  object stream. Multipart COMPOSITE source metadata therefore becomes a direct
  FULL_OBJECT checksum on the destination.
  """
  @spec for_copy_object_source_metadata!(map()) :: t() | nil
  def for_copy_object_source_metadata!(metadata) when is_map(metadata) do
    case source_metadata_algorithm!(metadata) do
      nil -> nil
      algorithm -> build_context([check_for_algorithm!(algorithm)], fn -> %{} end)
    end
  end

  @doc "Validates CopyObject checksum request headers for callers that do not need the parsed algorithm."
  @spec reject_copy_object_headers!(Plug.Conn.t()) :: :ok
  def reject_copy_object_headers!(conn) do
    case copy_object_algorithm!(conn.req_headers) do
      nil ->
        :ok

      _algorithm ->
        :ok
    end
  end

  @doc """
  Wraps a chunk stream and returns `{stream, get_context, discard_context}`.

  The returned `get_context` function yields a checksum context after the stream
  has been fully consumed by storage.
  """
  @spec wrap_stream(Enumerable.t(), t()) :: {Enumerable.t(), (-> t()), (-> :ok)}
  def wrap_stream(chunks, %{checks: [], get_trailers: get_trailers} = checksum) do
    get_context = fn ->
      _ = get_trailers.()
      %{checksum | verify!: fn -> :ok end}
    end

    discard = fn ->
      _ = get_trailers.()
      :ok
    end

    {chunks, get_context, discard}
  end

  def wrap_stream(chunks, %{checks: checks, get_trailers: get_trailers} = checksum) do
    {:ok, agent} = Agent.start_link(fn -> checks end)

    stream =
      Stream.map(chunks, fn chunk ->
        chunk = IO.iodata_to_binary(chunk)
        Agent.update(agent, fn acc -> Enum.map(acc, &update_check(&1, chunk)) end)
        chunk
      end)

    get_context = fn ->
      checks = Agent.get(agent, & &1)

      try do
        final = finalize_checks(checks, get_trailers.())

        %{
          checksum
          | response_headers: response_headers(final),
            verify!: fn -> verify!(final) end
        }
      after
        stop_agent(agent)
      end
    end

    {stream, get_context, fn -> stop_agent(agent) end}
  end

  @doc "Adds checksum response headers for validated checksum requests."
  @spec put_response_headers(Plug.Conn.t(), t()) :: Plug.Conn.t()
  def put_response_headers(conn, %{response_headers: headers}) do
    Enum.reduce(headers, conn, fn {name, value}, acc -> put_resp_header(acc, name, value) end)
  end

  @doc "Adds object-level checksum response headers for PutObject."
  @spec put_object_response_headers(Plug.Conn.t(), t()) :: Plug.Conn.t()
  def put_object_response_headers(conn, checksum) do
    conn = put_response_headers(conn, checksum)

    if map_size(response_metadata(checksum.response_headers)) == 0 do
      conn
    else
      put_resp_header(conn, "x-amz-checksum-type", "FULL_OBJECT")
    end
  end

  @doc "Returns object-level checksum metadata suitable for durable S3 metadata."
  @spec object_metadata(t()) :: map()
  def object_metadata(%{response_headers: headers}) do
    values = response_metadata(headers)

    if map_size(values) == 0, do: %{}, else: Map.put(values, "ChecksumType", "FULL_OBJECT")
  end

  @doc "Returns per-part checksum metadata for durable completed multipart metadata."
  @spec part_metadata(t()) :: map()
  def part_metadata(%{response_headers: headers}) do
    response_metadata(headers)
  end

  @doc """
  Returns object-level multipart COMPOSITE checksum metadata from completed parts.

  S3's multipart composite checksum is the same algorithm applied to the
  concatenated raw per-part checksum bytes, base64-encoded and suffixed with
  the part count.
  """
  @spec composite_object_metadata([map()]) :: {:ok, map()} | {:error, :bad_digest}
  def composite_object_metadata(parts) when is_list(parts) do
    checksum_field =
      parts
      |> Enum.flat_map(&part_checksum_fields/1)
      |> Enum.uniq()
      |> case do
        [field] -> field
        _ -> nil
      end

    cond do
      parts == [] ->
        {:ok, %{}}

      is_nil(checksum_field) ->
        {:ok, %{}}

      not Map.has_key?(@composite_algorithms, checksum_field) ->
        {:ok, %{}}

      true ->
        build_composite_metadata(parts, checksum_field)
    end
  end

  defp response_metadata(headers) do
    headers
    |> Enum.map(fn {name, value} -> {metadata_key(name), value} end)
    |> Map.new()
  end

  defp part_checksum_fields(part) do
    part
    |> Map.keys()
    |> Enum.map(&to_string/1)
    |> Enum.filter(fn field ->
      field != "ChecksumType" and String.starts_with?(field, "Checksum")
    end)
  end

  defp build_composite_metadata(parts, checksum_field) do
    algorithm = Map.fetch!(@composite_algorithms, checksum_field)
    digest_size = composite_digest_size(algorithm)

    with {:ok, decoded} <- decode_part_checksums(parts, checksum_field, digest_size) do
      if decoded == [] do
        {:ok, %{}}
      else
        value =
          decoded
          |> IO.iodata_to_binary()
          |> then(&composite_digest(algorithm, &1))
          |> Base.encode64()

        {:ok, %{checksum_field => "#{value}-#{length(parts)}", "ChecksumType" => "COMPOSITE"}}
      end
    end
  end

  defp composite_digest_size({:hash, _algorithm, digest_size}), do: digest_size
  defp composite_digest_size({:crc32, digest_size}), do: digest_size
  defp composite_digest_size({:crc32c, digest_size}), do: digest_size
  defp composite_digest_size({:xxhash3, digest_size}), do: digest_size
  defp composite_digest_size({:xxhash128, digest_size}), do: digest_size
  defp composite_digest_size({:xxhash64, digest_size}), do: digest_size

  defp composite_digest({:hash, algorithm, _digest_size}, bytes),
    do: :crypto.hash(algorithm, bytes)

  defp composite_digest({:crc32, _digest_size}, bytes) do
    bytes
    |> :erlang.crc32()
    |> crc32_final()
  end

  defp composite_digest({:crc32c, _digest_size}, bytes) do
    bytes
    |> crc32c()
    |> crc32_final()
  end

  defp composite_digest({:xxhash3, _digest_size}, bytes) do
    bytes
    |> xxh3()
    |> xxh3_64_final()
  end

  defp composite_digest({:xxhash128, _digest_size}, bytes) do
    bytes
    |> xxh3()
    |> xxh3_128_final()
  end

  defp composite_digest({:xxhash64, _digest_size}, bytes) do
    bytes
    |> xxhash64()
    |> xxhash64_final()
  end

  defp decode_part_checksums(parts, checksum_field, digest_size) do
    Enum.reduce_while(parts, {:ok, []}, fn part, {:ok, acc} ->
      case Map.fetch(part, checksum_field) do
        {:ok, value} when is_binary(value) ->
          case decode_base64_value(value, digest_size) do
            {:ok, decoded} -> {:cont, {:ok, [decoded | acc]}}
            :error -> {:halt, {:error, :bad_digest}}
          end

        _ ->
          {:halt, {:ok, []}}
      end
    end)
    |> case do
      {:ok, decoded} when length(decoded) == length(parts) -> {:ok, Enum.reverse(decoded)}
      {:ok, _incomplete} -> {:ok, []}
      {:error, _reason} = err -> err
    end
  end

  defp content_md5_check(headers) do
    case header(headers, "content-md5") do
      nil ->
        []

      value ->
        [
          %{
            response_header: nil,
            kind: {:hash, :md5},
            expected: decode_base64!(value, 16),
            context: :crypto.hash_init(:md5)
          }
        ]
    end
  end

  defp hash_checks(headers) do
    @hash_algorithms
    |> Enum.flat_map(fn {name, algorithm} ->
      case header(headers, name) do
        nil ->
          []

        value ->
          [
            %{
              response_header: name,
              kind: {:hash, algorithm},
              expected: decode_base64!(value, hash_length(algorithm)),
              context: :crypto.hash_init(algorithm)
            }
          ]
      end
    end)
  end

  defp crc32_checks(headers) do
    case header(headers, "x-amz-checksum-crc32") do
      nil ->
        []

      value ->
        [
          %{
            response_header: "x-amz-checksum-crc32",
            kind: :crc32,
            expected: decode_base64!(value, 4),
            context: 0
          }
        ]
    end
  end

  defp crc32c_checks(headers) do
    case header(headers, "x-amz-checksum-crc32c") do
      nil ->
        []

      value ->
        [
          %{
            response_header: "x-amz-checksum-crc32c",
            kind: :crc32c,
            expected: decode_base64!(value, 4),
            context: 0
          }
        ]
    end
  end

  defp crc64nvme_checks(headers) do
    case header(headers, "x-amz-checksum-crc64nvme") do
      nil ->
        []

      value ->
        [
          %{
            response_header: "x-amz-checksum-crc64nvme",
            kind: :crc64nvme,
            expected: decode_base64!(value, 8),
            context: 0
          }
        ]
    end
  end

  defp xxhash64_checks(headers) do
    case header(headers, "x-amz-checksum-xxhash64") do
      nil ->
        []

      value ->
        [
          %{
            response_header: "x-amz-checksum-xxhash64",
            kind: :xxhash64,
            expected: decode_base64!(value, 8),
            context: xxhash64_context()
          }
        ]
    end
  end

  defp xxhash3_checks(headers) do
    case header(headers, "x-amz-checksum-xxhash3") do
      nil ->
        []

      value ->
        [
          %{
            response_header: "x-amz-checksum-xxhash3",
            kind: :xxhash3,
            expected: decode_base64!(value, 8),
            context: xxh3_context()
          }
        ]
    end
  end

  defp xxhash128_checks(headers) do
    case header(headers, "x-amz-checksum-xxhash128") do
      nil ->
        []

      value ->
        [
          %{
            response_header: "x-amz-checksum-xxhash128",
            kind: :xxhash128,
            expected: decode_base64!(value, 16),
            context: xxh3_context()
          }
        ]
    end
  end

  defp trailer_checks(headers) do
    headers
    |> declared_trailer_names()
    |> Enum.flat_map(fn name ->
      cond do
        Map.has_key?(@hash_algorithms, name) ->
          [
            %{
              response_header: name,
              kind: {:hash, Map.fetch!(@hash_algorithms, name)},
              trailer_header: name,
              context: :crypto.hash_init(Map.fetch!(@hash_algorithms, name))
            }
          ]

        name == "x-amz-checksum-crc32" ->
          [
            %{
              response_header: name,
              kind: :crc32,
              trailer_header: name,
              context: 0
            }
          ]

        name == "x-amz-checksum-crc32c" ->
          [
            %{
              response_header: name,
              kind: :crc32c,
              trailer_header: name,
              context: 0
            }
          ]

        name == "x-amz-checksum-crc64nvme" ->
          [
            %{
              response_header: name,
              kind: :crc64nvme,
              trailer_header: name,
              context: 0
            }
          ]

        name == "x-amz-checksum-xxhash3" ->
          [
            %{
              response_header: name,
              kind: :xxhash3,
              trailer_header: name,
              context: xxh3_context()
            }
          ]

        name == "x-amz-checksum-xxhash128" ->
          [
            %{
              response_header: name,
              kind: :xxhash128,
              trailer_header: name,
              context: xxh3_context()
            }
          ]

        name == "x-amz-checksum-xxhash64" ->
          [
            %{
              response_header: name,
              kind: :xxhash64,
              trailer_header: name,
              context: xxhash64_context()
            }
          ]

        true ->
          []
      end
    end)
  end

  defp update_check(%{kind: {:hash, _algorithm}, context: context} = check, chunk) do
    %{check | context: :crypto.hash_update(context, chunk)}
  end

  defp update_check(%{kind: :crc32, context: crc} = check, chunk) do
    %{check | context: :erlang.crc32(crc, chunk)}
  end

  defp update_check(%{kind: :crc32c, context: crc} = check, chunk) do
    %{check | context: crc32c(crc, chunk)}
  end

  defp update_check(%{kind: :crc64nvme, context: crc} = check, chunk) do
    %{check | context: crc64nvme(crc, chunk)}
  end

  defp update_check(%{kind: :xxhash3, context: context} = check, chunk) do
    %{check | context: xxh3_update(context, chunk)}
  end

  defp update_check(%{kind: :xxhash128, context: context} = check, chunk) do
    %{check | context: xxh3_update(context, chunk)}
  end

  defp update_check(%{kind: :xxhash64, context: context} = check, chunk) do
    %{check | context: xxhash64_update(context, chunk)}
  end

  defp finalize_checks(checks, trailers) do
    Enum.map(checks, fn %{context: context} = check ->
      check
      |> Map.put(:actual, final_value(check.kind, context))
      |> put_expected_from_trailer(trailers)
      |> Map.put(:context, nil)
    end)
  end

  defp put_expected_from_trailer(%{trailer_header: name} = check, trailers) do
    expected_size = expected_size(check.kind)

    case Map.fetch(trailers, name) do
      {:ok, value} -> Map.put(check, :expected, decode_base64!(value, expected_size))
      :error -> raise Error.new(:bad_digest)
    end
  end

  defp put_expected_from_trailer(check, _trailers), do: check

  defp verify!(checks) do
    case Enum.find(checks, fn check ->
           Map.has_key?(check, :expected) and check.actual != check.expected
         end) do
      nil ->
        :ok

      _check ->
        raise Error.new(:bad_digest)
    end
  end

  defp crc32_final(crc), do: <<crc::32>>
  defp crc64_final(crc), do: <<crc::64>>

  defp final_value({:hash, _algorithm}, context), do: :crypto.hash_final(context)
  defp final_value(:crc32, crc), do: crc32_final(crc)
  defp final_value(:crc32c, crc), do: crc32_final(crc)
  defp final_value(:crc64nvme, crc), do: crc64_final(crc)
  defp final_value(:xxhash3, context), do: xxh3_64_final(context)
  defp final_value(:xxhash128, context), do: xxh3_128_final(context)
  defp final_value(:xxhash64, context), do: xxhash64_final(context)

  defp stop_agent(agent) do
    Agent.stop(agent)
  catch
    :exit, _reason -> :ok
  end

  defp hash_length(:md5), do: 16
  defp hash_length(:sha), do: 20
  defp hash_length(:sha256), do: 32
  defp hash_length(:sha512), do: 64

  defp expected_size({:hash, algorithm}), do: hash_length(algorithm)
  defp expected_size(:crc32), do: 4
  defp expected_size(:crc32c), do: 4
  defp expected_size(:crc64nvme), do: 8
  defp expected_size(:xxhash3), do: 8
  defp expected_size(:xxhash128), do: 16
  defp expected_size(:xxhash64), do: 8

  defp decode_base64!(value, expected_size) do
    case decode_base64_value(value, expected_size) do
      {:ok, decoded} -> decoded
      :error -> raise Error.new(:bad_digest)
    end
  end

  defp decode_base64_value(value, expected_size) when is_binary(value) do
    case Base.decode64(String.trim(value)) do
      {:ok, decoded} when byte_size(decoded) == expected_size -> {:ok, decoded}
      {:ok, _decoded} -> :error
      :error -> :error
    end
  end

  defp unsupported_header(headers) do
    Enum.find_value(headers, fn {name, _value} ->
      name = String.downcase(name)

      if String.starts_with?(name, "x-amz-checksum-") and
           name not in @supported_checksum_headers do
        name
      end
    end)
  end

  defp validate_sdk_algorithm!(headers) do
    case header(headers, "x-amz-sdk-checksum-algorithm") do
      nil ->
        :ok

      raw ->
        algorithm = raw |> String.trim() |> String.upcase()

        cond do
          Map.has_key?(@sdk_algorithm_headers, algorithm) ->
            validate_supported_sdk_algorithm!(headers, algorithm)

          true ->
            raise Error.new(:invalid_argument,
                    message: "Invalid x-amz-sdk-checksum-algorithm: #{raw}"
                  )
        end
    end
  end

  defp validate_trailer_payload_mode!(conn, headers) do
    if trailer_checksum?(headers) and not streaming_trailer_payload?(conn) do
      raise Error.new(:invalid_request,
              message: "Checksum trailers require a streaming trailer payload"
            )
    end
  end

  defp streaming_trailer_payload?(conn) do
    conn.assigns[:payload_mode] == :streaming and
      conn.req_headers
      |> header("x-amz-content-sha256")
      |> case do
        value when is_binary(value) -> String.ends_with?(value, "-TRAILER")
        _ -> false
      end
  end

  defp validate_supported_sdk_algorithm!(headers, algorithm) do
    expected_header = Map.fetch!(@sdk_algorithm_headers, algorithm)

    cond do
      header(headers, expected_header) ->
        :ok

      expected_header in declared_trailer_names(headers) ->
        :ok

      checksum_value_header?(headers) ->
        raise Error.new(:bad_digest)

      true ->
        raise Error.new(:invalid_request,
                message:
                  "x-amz-sdk-checksum-algorithm requires a matching checksum header or trailer"
              )
    end
  end

  defp multipart_algorithm(headers) do
    case header(headers, "x-amz-checksum-algorithm") do
      nil -> nil
      raw -> normalize_algorithm!(raw)
    end
  end

  defp multipart_checksum_type(headers) do
    case header(headers, "x-amz-checksum-type") do
      nil ->
        nil

      raw ->
        case raw |> String.trim() |> String.upcase() do
          value when value in ["COMPOSITE", "FULL_OBJECT"] ->
            value

          _ ->
            raise Error.new(:invalid_argument,
                    message: "Invalid x-amz-checksum-type: #{raw}"
                  )
        end
    end
  end

  defp normalize_algorithm!(raw) do
    algorithm = raw |> String.trim() |> String.upcase()

    cond do
      Map.has_key?(@sdk_algorithm_headers, algorithm) ->
        algorithm

      true ->
        raise Error.new(:invalid_argument, message: "Invalid checksum algorithm: #{raw}")
    end
  end

  defp normalize_copy_object_algorithm!(raw) do
    algorithm = raw |> String.trim() |> String.upcase()

    cond do
      Map.has_key?(@sdk_algorithm_headers, algorithm) ->
        algorithm

      true ->
        raise Error.new(:invalid_argument,
                message: "Invalid x-amz-checksum-algorithm: #{raw}"
              )
    end
  end

  defp source_metadata_algorithm!(metadata) do
    fields =
      metadata
      |> Enum.flat_map(fn {field, value} ->
        field = to_string(field)

        if object_checksum_field?(field) and checksum_metadata_value?(value) do
          [field]
        else
          []
        end
      end)
      |> Enum.uniq()

    cond do
      fields == [] and checksum_type_metadata?(metadata) ->
        raise Error.new(:internal_error,
                message: "Source object checksum metadata is inconsistent"
              )

      fields == [] ->
        nil

      unknown_source_metadata_fields(fields) != [] ->
        raise Error.new(:not_implemented,
                message:
                  "CopyObject source checksum metadata is not implemented: " <>
                    Enum.join(unknown_source_metadata_fields(fields), ", ")
              )

      length(fields) == 1 ->
        fields |> hd() |> then(&Map.fetch!(@object_metadata_algorithms, &1))

      true ->
        raise Error.new(:internal_error,
                message: "Source object checksum metadata is inconsistent"
              )
    end
  end

  defp object_checksum_field?("ChecksumType"), do: false

  defp object_checksum_field?(field) when is_binary(field),
    do: String.starts_with?(field, "Checksum")

  defp checksum_metadata_value?(value) when is_binary(value), do: String.trim(value) != ""
  defp checksum_metadata_value?(_value), do: false

  defp checksum_type_metadata?(metadata) do
    Enum.any?(metadata, fn {field, value} ->
      to_string(field) == "ChecksumType" and checksum_metadata_value?(value)
    end)
  end

  # 未建模的 Checksum* 源元数据字段一律走 :not_implemented（绝不静默放行）。
  defp unknown_source_metadata_fields(fields) do
    Enum.reject(fields, &Map.has_key?(@object_metadata_algorithms, &1))
  end

  defp modeled_response_headers(checks) do
    checks
    |> Enum.map(& &1.response_header)
    |> Enum.filter(&modeled_checksum_header?/1)
    |> Enum.uniq()
  end

  defp modeled_checksum_header?(header) when is_binary(header),
    do: String.starts_with?(header, "x-amz-checksum-")

  defp modeled_checksum_header?(_header), do: false

  defp check_for_algorithm!(algorithm) do
    header = algorithm_header!(algorithm)

    %{
      response_header: header,
      kind: kind_for_algorithm!(algorithm),
      context: context_for_algorithm!(algorithm)
    }
  end

  defp algorithm_header!(algorithm), do: Map.fetch!(@sdk_algorithm_headers, algorithm)

  defp kind_for_algorithm!("CRC32"), do: :crc32
  defp kind_for_algorithm!("CRC32C"), do: :crc32c
  defp kind_for_algorithm!("CRC64NVME"), do: :crc64nvme
  defp kind_for_algorithm!("MD5"), do: {:hash, :md5}
  defp kind_for_algorithm!("SHA1"), do: {:hash, :sha}
  defp kind_for_algorithm!("SHA256"), do: {:hash, :sha256}
  defp kind_for_algorithm!("SHA512"), do: {:hash, :sha512}
  defp kind_for_algorithm!("XXHASH3"), do: :xxhash3
  defp kind_for_algorithm!("XXHASH128"), do: :xxhash128
  defp kind_for_algorithm!("XXHASH64"), do: :xxhash64

  defp context_for_algorithm!(algorithm) do
    case kind_for_algorithm!(algorithm) do
      {:hash, hash_algorithm} -> :crypto.hash_init(hash_algorithm)
      :crc32 -> 0
      :crc32c -> 0
      :crc64nvme -> 0
      :xxhash3 -> xxh3_context()
      :xxhash128 -> xxh3_context()
      :xxhash64 -> xxhash64_context()
    end
  end

  defp checksum_headers?(headers) do
    Enum.any?(headers, fn {name, _value} ->
      name = String.downcase(name)

      name == "content-md5" or name == "x-amz-sdk-checksum-algorithm" or
        name == "x-amz-checksum-algorithm" or
        String.starts_with?(name, "x-amz-checksum-")
    end)
  end

  defp checksum_value_header?(headers) do
    Enum.any?(headers, fn {name, _value} ->
      name = String.downcase(name)
      String.starts_with?(name, "x-amz-checksum-") and name != "x-amz-checksum-type"
    end)
  end

  defp copy_checksum_value_headers?(headers) do
    Enum.any?(headers, fn {name, _value} ->
      name = String.downcase(name)

      name == "content-md5" or name == "x-amz-sdk-checksum-algorithm" or
        (String.starts_with?(name, "x-amz-checksum-") and
           name != "x-amz-checksum-algorithm")
    end)
  end

  defp unsupported_trailer_header(headers) do
    Enum.find(declared_trailer_names(headers), fn name ->
      String.starts_with?(name, "x-amz-checksum-") and name not in @supported_checksum_headers
    end)
  end

  defp complete_unsupported_header(headers) do
    headers
    |> Enum.map(fn {name, _value} -> String.downcase(name) end)
    |> Enum.find(fn name ->
      cond do
        name in Map.keys(@complete_modeled_headers) -> false
        name == "x-amz-checksum-type" -> false
        name == "x-amz-mp-object-size" -> false
        name == "content-md5" -> false
        name == "x-amz-sdk-checksum-algorithm" -> true
        name == "x-amz-checksum-algorithm" -> true
        String.starts_with?(name, "x-amz-checksum-") -> true
        true -> false
      end
    end)
  end

  defp complete_unsupported_trailer_header(headers) do
    headers
    |> declared_trailer_names()
    |> Enum.find(fn name ->
      cond do
        Map.has_key?(@complete_modeled_headers, name) -> false
        String.starts_with?(name, "x-amz-checksum-") -> true
        true -> false
      end
    end)
  end

  defp complete_modeled_headers(headers) do
    headers
    |> Enum.map(fn {name, value} -> {String.downcase(name), value} end)
    |> Enum.flat_map(fn {name, value} ->
      case Map.fetch(@complete_modeled_headers, name) do
        {:ok, algorithm} -> [{algorithm, value}]
        :error -> []
      end
    end)
  end

  defp complete_trailer_headers(headers, trailers) do
    headers
    |> declared_trailer_names()
    |> Enum.flat_map(fn name ->
      case Map.fetch(@complete_modeled_headers, name) do
        {:ok, algorithm} ->
          case Map.fetch(trailers, name) do
            {:ok, value} -> [{algorithm, value}]
            :error -> raise Error.new(:bad_digest)
          end

        :error ->
          []
      end
    end)
  end

  defp multipart_object_size(headers) do
    case header(headers, "x-amz-mp-object-size") do
      nil ->
        nil

      raw ->
        case Integer.parse(String.trim(raw)) do
          {size, ""} when size >= 0 ->
            size

          _ ->
            raise Error.new(:invalid_request,
                    message: "Invalid x-amz-mp-object-size: #{raw}"
                  )
        end
    end
  end

  defp trailer_checksum?(headers) do
    Enum.any?(declared_trailer_names(headers), &String.starts_with?(&1, "x-amz-checksum-"))
  end

  defp declared_trailer_names(headers) do
    headers
    |> header("x-amz-trailer")
    |> case do
      nil ->
        []

      trailer ->
        trailer
        |> String.split(",", trim: true)
        |> Enum.map(fn name -> name |> String.trim() |> String.downcase() end)
    end
  end

  defp response_headers(checks) do
    checks
    |> Enum.reject(&is_nil(&1.response_header))
    |> Enum.uniq_by(& &1.response_header)
    |> Enum.flat_map(fn check ->
      case Map.get(check, :actual) || Map.get(check, :expected) do
        nil -> []
        value -> [{check.response_header, Base.encode64(value)}]
      end
    end)
  end

  defp metadata_key("x-amz-checksum-crc32"), do: "ChecksumCRC32"
  defp metadata_key("x-amz-checksum-crc32c"), do: "ChecksumCRC32C"
  defp metadata_key("x-amz-checksum-crc64nvme"), do: "ChecksumCRC64NVME"
  defp metadata_key("x-amz-checksum-md5"), do: "ChecksumMD5"
  defp metadata_key("x-amz-checksum-sha1"), do: "ChecksumSHA1"
  defp metadata_key("x-amz-checksum-sha256"), do: "ChecksumSHA256"
  defp metadata_key("x-amz-checksum-sha512"), do: "ChecksumSHA512"
  defp metadata_key("x-amz-checksum-xxhash3"), do: "ChecksumXXHASH3"
  defp metadata_key("x-amz-checksum-xxhash128"), do: "ChecksumXXHASH128"
  defp metadata_key("x-amz-checksum-xxhash64"), do: "ChecksumXXHASH64"

  defp crc32c(data), do: crc32c(0, data)

  defp crc32c(previous, data) when is_integer(previous) and is_binary(data) do
    table = crc32c_table()

    crc =
      for <<byte <- data>>, reduce: bxor(previous, 0xFFFFFFFF) do
        crc ->
          table_index = band(bxor(crc, byte), 0xFF)
          table_value = elem(table, table_index)
          bxor(bsr(crc, 8), table_value)
      end

    band(bxor(crc, 0xFFFFFFFF), 0xFFFFFFFF)
  end

  defp crc32c_table do
    case :persistent_term.get(@crc32c_table_key, nil) do
      nil ->
        table = 0..255 |> Enum.map(&crc32c_table_entry/1) |> List.to_tuple()
        :persistent_term.put(@crc32c_table_key, table)
        table

      table ->
        table
    end
  end

  defp crc32c_table_entry(byte) do
    Enum.reduce(1..8, byte, fn _bit, crc ->
      if band(crc, 1) == 1 do
        bxor(bsr(crc, 1), 0x82F63B78)
      else
        bsr(crc, 1)
      end
    end)
  end

  defp crc64nvme(previous, data) when is_integer(previous) and is_binary(data) do
    table = crc64nvme_table()

    crc =
      for <<byte <- data>>, reduce: bxor(previous, 0xFFFFFFFFFFFFFFFF) do
        crc ->
          table_index = band(bxor(crc, byte), 0xFF)
          table_value = elem(table, table_index)
          bxor(bsr(crc, 8), table_value)
      end

    band(bxor(crc, 0xFFFFFFFFFFFFFFFF), 0xFFFFFFFFFFFFFFFF)
  end

  defp crc64nvme_table do
    case :persistent_term.get(@crc64nvme_table_key, nil) do
      nil ->
        table = 0..255 |> Enum.map(&crc64nvme_table_entry/1) |> List.to_tuple()
        :persistent_term.put(@crc64nvme_table_key, table)
        table

      table ->
        table
    end
  end

  defp crc64nvme_table_entry(byte) do
    Enum.reduce(1..8, byte, fn _bit, crc ->
      if band(crc, 1) == 1 do
        bxor(bsr(crc, 1), 0x9A6C9329AC4BC9B5)
      else
        bsr(crc, 1)
      end
    end)
  end

  defp xxh3(data) when is_binary(data) do
    xxh3_context()
    |> xxh3_update(data)
  end

  defp xxh3_context do
    %{
      total_len: 0,
      buffer: "",
      last64: "",
      acc: nil
    }
  end

  defp xxh3_update(%{buffer: buffer, total_len: total_len, last64: last64} = context, data)
       when is_binary(data) do
    input = buffer <> data
    total_len = total_len + byte_size(data)
    last64 = xxh3_update_last64(last64, data)

    context = %{context | total_len: total_len, last64: last64}

    if total_len <= @xxh3_large_threshold do
      %{context | buffer: input}
    else
      acc = context.acc || xxh3_initial_acc()
      {acc, remaining} = xxh3_process_large_blocks(acc, input)
      %{context | acc: acc, buffer: remaining}
    end
  end

  defp xxh3_process_large_blocks(acc, data) when byte_size(data) <= @xxh3_block_size,
    do: {acc, data}

  defp xxh3_process_large_blocks(acc, <<block::binary-size(@xxh3_block_size), rest::binary>>) do
    acc =
      acc
      |> xxh3_accumulate_block(block)
      |> xxh3_scramble_acc()

    xxh3_process_large_blocks(acc, rest)
  end

  defp xxh3_64_final(%{total_len: len, buffer: data, last64: last64, acc: acc}) do
    digest =
      cond do
        len <= 16 -> xxh3_64_small(data)
        len <= @xxh3_large_threshold -> xxh3_64_medium(data)
        true -> xxh3_64_large(acc || xxh3_initial_acc(), data, last64, len)
      end

    <<digest::unsigned-integer-size(64)>>
  end

  defp xxh3_128_final(%{total_len: len, buffer: data, last64: last64, acc: acc}) do
    {low, high} =
      cond do
        len <= 16 -> xxh3_128_small(data)
        len <= @xxh3_large_threshold -> xxh3_128_medium(data)
        true -> xxh3_128_large(acc || xxh3_initial_acc(), data, last64, len)
      end

    <<high::unsigned-integer-size(64), low::unsigned-integer-size(64)>>
  end

  defp xxh3_64_small(""), do: xxh64_avalanche(bxor(xxh3_secret64(56), xxh3_secret64(64)))

  defp xxh3_64_small(data) when byte_size(data) <= 3 do
    combined = xxh3_1to3_combined(data)
    value = bxor(bxor(xxh3_secret32(0), xxh3_secret32(4)), combined)
    xxh64_avalanche(value)
  end

  defp xxh3_64_small(data) when byte_size(data) <= 8 do
    len = byte_size(data)
    input_first = read_u32_le(data, 0)
    input_last = read_u32_le(data, len - 4)
    combined = bor(input_last, bsl(input_first, 32))

    value =
      bxor(
        u64(bxor(xxh3_secret64(8), xxh3_secret64(16))),
        combined
      )

    value =
      value
      |> bxor(rotl64(value, 49))
      |> bxor(rotl64(value, 24))
      |> mul64(@xxh3_prime_mx2)

    value =
      value
      |> bxor(add64(bsr(value, 35), len))
      |> mul64(@xxh3_prime_mx2)

    bxor(value, bsr(value, 28)) |> u64()
  end

  defp xxh3_64_small(data) do
    len = byte_size(data)
    input_first = read_u64_le(data, 0)
    input_last = read_u64_le(data, len - 8)

    low = bxor(bxor(xxh3_secret64(24), xxh3_secret64(32)), input_first)
    high = bxor(bxor(xxh3_secret64(40), xxh3_secret64(48)), input_last)
    {mul_low, mul_high} = mul128(low, high)

    len
    |> add64(bswap64(low))
    |> add64(high)
    |> add64(bxor(mul_low, mul_high))
    |> xxh3_avalanche()
  end

  defp xxh3_128_small("") do
    {
      xxh64_avalanche(bxor(xxh3_secret64(64), xxh3_secret64(72))),
      xxh64_avalanche(bxor(xxh3_secret64(80), xxh3_secret64(88)))
    }
  end

  defp xxh3_128_small(data) when byte_size(data) <= 3 do
    combined = xxh3_1to3_combined(data)
    low = bxor(bxor(xxh3_secret32(0), xxh3_secret32(4)), combined)
    high = bxor(bxor(xxh3_secret32(8), xxh3_secret32(12)), rotl32(bswap32(combined), 13))

    {xxh64_avalanche(low), xxh64_avalanche(high)}
  end

  defp xxh3_128_small(data) when byte_size(data) <= 8 do
    len = byte_size(data)
    input_first = read_u32_le(data, 0)
    input_last = read_u32_le(data, len - 4)
    combined = bor(input_first, bsl(input_last, 32))
    value = bxor(add64(bxor(xxh3_secret64(16), xxh3_secret64(24)), 0), combined)
    {low, high} = mul128(value, add64(@xxh64_prime1, bsl(len, 2)))
    high = add64(high, bsl(low, 1))

    low =
      low
      |> bxor(bsr(high, 3))
      |> bxor(bsr(low, 35))
      |> mul64(@xxh3_prime_mx2)
      |> then(&bxor(&1, bsr(&1, 28)))
      |> u64()

    high = xxh3_avalanche(high)

    {low, high}
  end

  defp xxh3_128_small(data) do
    len = byte_size(data)
    input_first = read_u64_le(data, 0)
    input_last = read_u64_le(data, len - 8)

    val1 =
      xxh3_secret64(32)
      |> bxor(xxh3_secret64(40))
      |> bxor(input_first)
      |> bxor(input_last)

    val2 =
      xxh3_secret64(48)
      |> bxor(xxh3_secret64(56))
      |> bxor(input_last)

    {mul_low, mul_high} = mul128(val1, @xxh64_prime1)

    low =
      mul_low
      |> add64(bsl(len - 1, 54))
      |> bxor(
        bswap64(add64(mul_high, add64(val2, mul64(band(val2, 0xFFFFFFFF), @xxh3_prime32_2 - 1))))
      )

    high = add64(mul_high, add64(val2, mul64(band(val2, 0xFFFFFFFF), @xxh3_prime32_2 - 1)))
    {low2, high2} = mul128(low, @xxh64_prime2)
    high = add64(high2, mul64(high, @xxh64_prime2))

    {xxh3_avalanche(low2), xxh3_avalanche(high)}
  end

  defp xxh3_1to3_combined(data) do
    len = byte_size(data)

    data
    |> :binary.at(len - 1)
    |> bor(bsl(len, 8))
    |> bor(bsl(:binary.at(data, 0), 16))
    |> bor(bsl(:binary.at(data, div(len, 2)), 24))
    |> band(0xFFFFFFFF)
  end

  defp xxh3_64_medium(data) do
    len = byte_size(data)
    acc = mul64(len, @xxh64_prime1)

    acc =
      if len <= 128 do
        xxh3_64_medium_17to128(data, acc)
      else
        xxh3_64_medium_129to240(data, acc)
      end

    xxh3_avalanche(acc)
  end

  defp xxh3_64_medium_17to128(data, acc) do
    len = byte_size(data)
    num_rounds = div(len - 1, 32) + 1

    Enum.reduce((num_rounds - 1)..0, acc, fn i, acc ->
      offset_start = i * 16
      offset_end = len - i * 16 - 16

      acc
      |> add64(xxh3_mix_step(data, offset_start, i * 32, 0))
      |> add64(xxh3_mix_step(data, offset_end, i * 32 + 16, 0))
    end)
  end

  defp xxh3_64_medium_129to240(data, acc) do
    len = byte_size(data)
    num_chunks = div(len, 16)

    acc =
      Enum.reduce(0..7, acc, fn i, acc ->
        add64(acc, xxh3_mix_step(data, i * 16, i * 16, 0))
      end)
      |> xxh3_avalanche()

    acc =
      reduce_int_range(8, num_chunks - 1, acc, fn i, acc ->
        add64(acc, xxh3_mix_step(data, i * 16, (i - 8) * 16 + 3, 0))
      end)

    add64(acc, xxh3_mix_step(data, len - 16, 119, 0))
  end

  defp xxh3_128_medium(data) do
    len = byte_size(data)
    acc = {mul64(len, @xxh64_prime1), 0}

    acc =
      if len <= 128 do
        xxh3_128_medium_17to128(data, acc)
      else
        xxh3_128_medium_129to240(data, acc)
      end

    xxh3_128_medium_final(acc, len)
  end

  defp xxh3_128_medium_17to128(data, acc) do
    len = byte_size(data)
    num_rounds = div(len - 1, 32) + 1

    Enum.reduce((num_rounds - 1)..0, acc, fn i, acc ->
      offset_start = i * 16
      offset_end = len - i * 16 - 16
      xxh3_mix_two_chunks(acc, data, offset_start, offset_end, i * 32, 0)
    end)
  end

  defp xxh3_128_medium_129to240(data, {acc0, acc1}) do
    len = byte_size(data)
    num_chunks = div(len, 32)

    {acc0, acc1} =
      Enum.reduce(0..3, {acc0, acc1}, fn i, acc ->
        xxh3_mix_two_chunks(acc, data, i * 32, i * 32 + 16, i * 32, 0)
      end)

    acc = {xxh3_avalanche(acc0), xxh3_avalanche(acc1)}

    acc =
      reduce_int_range(4, num_chunks - 1, acc, fn i, acc ->
        xxh3_mix_two_chunks(acc, data, i * 32, i * 32 + 16, (i - 4) * 32 + 3, 0)
      end)

    xxh3_mix_two_chunks(acc, data, len - 16, len - 32, 103, 0)
  end

  defp xxh3_128_medium_final({acc0, acc1}, len) do
    low = add64(acc0, acc1)

    high =
      acc0
      |> mul64(@xxh64_prime1)
      |> add64(mul64(acc1, @xxh64_prime4))
      |> add64(mul64(len, @xxh64_prime2))

    {xxh3_avalanche(low), u64(-xxh3_avalanche(high))}
  end

  defp xxh3_mix_step(data, offset, secret_offset, seed) do
    data0 = read_u64_le(data, offset)
    data1 = read_u64_le(data, offset + 8)
    secret0 = xxh3_secret64(secret_offset)
    secret1 = xxh3_secret64(secret_offset + 8)
    {low, high} = mul128(bxor(data0, add64(secret0, seed)), bxor(data1, u64(secret1 - seed)))
    bxor(low, high)
  end

  defp xxh3_mix_two_chunks({acc0, acc1}, data, offset1, offset2, secret_offset, seed) do
    data10 = read_u64_le(data, offset1)
    data11 = read_u64_le(data, offset1 + 8)
    data20 = read_u64_le(data, offset2)
    data21 = read_u64_le(data, offset2 + 8)

    acc0 =
      acc0
      |> add64(xxh3_mix_step(data, offset1, secret_offset, seed))
      |> bxor(add64(data20, data21))
      |> u64()

    acc1 =
      acc1
      |> add64(xxh3_mix_step(data, offset2, secret_offset + 16, seed))
      |> bxor(add64(data10, data11))
      |> u64()

    {acc0, acc1}
  end

  defp xxh3_update_last64(previous, data) do
    bytes = previous <> data

    if byte_size(bytes) <= @xxh3_stripe_size do
      bytes
    else
      binary_part(bytes, byte_size(bytes) - @xxh3_stripe_size, @xxh3_stripe_size)
    end
  end

  defp xxh3_64_large(acc, data, last64, total_len) do
    acc
    |> xxh3_last_round(data, last64)
    |> xxh3_merge_accs(mul64(total_len, @xxh64_prime1), 11)
  end

  defp xxh3_128_large(acc, data, last64, total_len) do
    acc = xxh3_last_round(acc, data, last64)

    {
      xxh3_merge_accs(acc, mul64(total_len, @xxh64_prime1), 11),
      xxh3_merge_accs(acc, u64(bnot(mul64(total_len, @xxh64_prime2))), @xxh3_secret_len - 75)
    }
  end

  defp xxh3_initial_acc do
    [
      @xxh3_prime32_3,
      @xxh64_prime1,
      @xxh64_prime2,
      @xxh64_prime3,
      @xxh64_prime4,
      @xxh3_prime32_2,
      @xxh64_prime5,
      @xxh3_prime32_1
    ]
  end

  defp xxh3_accumulate_block(acc, block) do
    Enum.reduce(0..15, acc, fn n, acc ->
      xxh3_accumulate_stripe(acc, block, n * @xxh3_stripe_size, n * 8)
    end)
  end

  defp xxh3_last_round(acc, data, last64) do
    len = byte_size(data)
    n_full_stripes = div(len - 1, @xxh3_stripe_size)

    acc =
      reduce_int_range(0, n_full_stripes - 1, acc, fn n, acc ->
        xxh3_accumulate_stripe(acc, data, n * @xxh3_stripe_size, n * 8)
      end)

    xxh3_accumulate_stripe(acc, last64, 0, @xxh3_secret_len - 71)
  end

  defp xxh3_accumulate_stripe(acc, data, stripe_offset, secret_offset) do
    Enum.reduce(0..7, acc, fn i, acc ->
      stripe = read_u64_le(data, stripe_offset + i * 8)
      secret = xxh3_secret64(secret_offset + i * 8)
      value = bxor(stripe, secret)
      product = band(value, 0xFFFFFFFF) * bsr(value, 32)

      acc
      |> list_update(bxor(i, 1), &add64(&1, stripe))
      |> list_update(i, &add64(&1, product))
    end)
  end

  defp xxh3_scramble_acc(acc) do
    Enum.map(Enum.with_index(acc), fn {value, i} ->
      value
      |> bxor(bsr(value, 47))
      |> bxor(xxh3_secret64(@xxh3_secret_len - @xxh3_stripe_size + i * 8))
      |> mul64(@xxh3_prime32_1)
    end)
  end

  defp xxh3_merge_accs(acc, init, secret_offset) do
    0..3
    |> Enum.reduce(init, fn i, result ->
      left = bxor(Enum.at(acc, i * 2), xxh3_secret64(secret_offset + i * 16))
      right = bxor(Enum.at(acc, i * 2 + 1), xxh3_secret64(secret_offset + i * 16 + 8))
      {low, high} = mul128(left, right)
      add64(result, bxor(low, high))
    end)
    |> xxh3_avalanche()
  end

  defp xxh3_avalanche(value) do
    value = value |> bxor(bsr(value, 37)) |> mul64(@xxh3_prime_mx1)
    value |> bxor(bsr(value, 32)) |> u64()
  end

  defp xxh3_secret32(offset), do: read_u32_le(@xxh3_secret, offset)
  defp xxh3_secret64(offset), do: read_u64_le(@xxh3_secret, offset)

  defp read_u32_le(data, offset) do
    <<value::little-unsigned-integer-size(32)>> = binary_part(data, offset, 4)
    value
  end

  defp read_u64_le(data, offset) do
    <<value::little-unsigned-integer-size(64)>> = binary_part(data, offset, 8)
    value
  end

  defp bswap32(value) do
    <<swapped::unsigned-integer-size(32)>> = <<value::little-unsigned-integer-size(32)>>
    swapped
  end

  defp bswap64(value) do
    <<swapped::unsigned-integer-size(64)>> = <<value::little-unsigned-integer-size(64)>>
    swapped
  end

  defp rotl32(value, shift) do
    value = band(value, 0xFFFFFFFF)
    band(bor(bsl(value, shift), bsr(value, 32 - shift)), 0xFFFFFFFF)
  end

  defp mul128(left, right) do
    product = left * right
    {u64(product), u64(bsr(product, 64))}
  end

  defp reduce_int_range(from, to, acc, fun) when from <= to do
    Enum.reduce(from..to, acc, fun)
  end

  defp reduce_int_range(_from, _to, acc, _fun), do: acc

  defp list_update(list, index, fun) do
    List.update_at(list, index, fun)
  end

  defp xxhash64(data) when is_binary(data) do
    xxhash64_context()
    |> xxhash64_update(data)
  end

  defp xxhash64_context do
    %{
      total_len: 0,
      buffer: "",
      v1: u64(@xxh64_prime1 + @xxh64_prime2),
      v2: @xxh64_prime2,
      v3: 0,
      v4: u64(-@xxh64_prime1)
    }
  end

  defp xxhash64_update(%{buffer: buffer, total_len: total_len} = context, data)
       when is_binary(data) do
    input = buffer <> data

    context =
      %{context | buffer: "", total_len: total_len + byte_size(data)}

    {context, remaining} = xxhash64_process_stripes(context, input)
    %{context | buffer: remaining}
  end

  defp xxhash64_process_stripes(context, data) when byte_size(data) < 32,
    do: {context, data}

  defp xxhash64_process_stripes(context, data) do
    <<d1::little-unsigned-integer-size(64), d2::little-unsigned-integer-size(64),
      d3::little-unsigned-integer-size(64), d4::little-unsigned-integer-size(64), rest::binary>> =
      data

    context =
      %{
        context
        | v1: xxh64_round(context.v1, d1),
          v2: xxh64_round(context.v2, d2),
          v3: xxh64_round(context.v3, d3),
          v4: xxh64_round(context.v4, d4)
      }

    xxhash64_process_stripes(context, rest)
  end

  defp xxhash64_final(context) do
    <<xxh64_digest(context)::unsigned-integer-size(64)>>
  end

  defp xxh64_digest(%{total_len: total_len, buffer: buffer} = context) do
    acc =
      if total_len >= 32 do
        context.v1
        |> rotl64(1)
        |> add64(rotl64(context.v2, 7))
        |> add64(rotl64(context.v3, 12))
        |> add64(rotl64(context.v4, 18))
        |> xxh64_merge_round(context.v1)
        |> xxh64_merge_round(context.v2)
        |> xxh64_merge_round(context.v3)
        |> xxh64_merge_round(context.v4)
      else
        @xxh64_prime5
      end

    acc
    |> add64(total_len)
    |> xxh64_finalize_remaining(buffer)
    |> xxh64_avalanche()
  end

  defp xxh64_finalize_remaining(acc, <<lane::little-unsigned-integer-size(64), rest::binary>>) do
    acc
    |> bxor(xxh64_round(0, lane))
    |> rotl64(27)
    |> mul64(@xxh64_prime1)
    |> add64(@xxh64_prime4)
    |> xxh64_finalize_remaining(rest)
  end

  defp xxh64_finalize_remaining(acc, <<lane::little-unsigned-integer-size(32), rest::binary>>) do
    acc
    |> bxor(mul64(lane, @xxh64_prime1))
    |> rotl64(23)
    |> mul64(@xxh64_prime2)
    |> add64(@xxh64_prime3)
    |> xxh64_finalize_remaining(rest)
  end

  defp xxh64_finalize_remaining(acc, <<byte::unsigned-integer-size(8), rest::binary>>) do
    acc
    |> bxor(mul64(byte, @xxh64_prime5))
    |> rotl64(11)
    |> mul64(@xxh64_prime1)
    |> xxh64_finalize_remaining(rest)
  end

  defp xxh64_finalize_remaining(acc, ""), do: acc

  defp xxh64_round(acc, input) do
    acc
    |> add64(mul64(input, @xxh64_prime2))
    |> rotl64(31)
    |> mul64(@xxh64_prime1)
  end

  defp xxh64_merge_round(acc, value) do
    acc
    |> bxor(xxh64_round(0, value))
    |> mul64(@xxh64_prime1)
    |> add64(@xxh64_prime4)
  end

  defp xxh64_avalanche(acc) do
    acc = acc |> bxor(bsr(acc, 33)) |> mul64(@xxh64_prime2)
    acc = acc |> bxor(bsr(acc, 29)) |> mul64(@xxh64_prime3)
    acc |> bxor(bsr(acc, 32)) |> u64()
  end

  defp rotl64(value, shift), do: u64(bor(bsl(value, shift), bsr(value, 64 - shift)))
  defp add64(left, right), do: u64(left + right)
  defp mul64(left, right), do: u64(left * right)
  defp u64(value), do: band(value, @u64_mask)

  defp header(headers, name) do
    headers
    |> Enum.find_value(fn {k, v} ->
      if String.downcase(k) == name, do: v
    end)
  end
end
