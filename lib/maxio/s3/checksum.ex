defmodule Maxio.S3.Checksum do
  @moduledoc """
  S3 upload checksum header validation.

  Supports checksum values carried in ordinary request headers. aws-chunked
  trailing checksums are intentionally handled in a later slice because they
  require BodyReader to expose verified trailing headers.
  """

  import Plug.Conn

  alias Maxio.S3.Error

  @type t :: %{
          checks: [check()],
          response_headers: [{String.t(), String.t()}],
          verify!: (-> :ok)
        }

  @type check :: %{
          required(:kind) => {:hash, atom()} | :crc32,
          required(:response_header) => String.t() | nil,
          required(:expected) => binary(),
          required(:context) => term(),
          optional(:actual) => binary()
        }

  @hash_algorithms %{
    "x-amz-checksum-md5" => :md5,
    "x-amz-checksum-sha1" => :sha,
    "x-amz-checksum-sha256" => :sha256
  }

  @supported_checksum_headers Map.keys(@hash_algorithms) ++ ["x-amz-checksum-crc32"]

  @sdk_algorithm_headers %{
    "CRC32" => "x-amz-checksum-crc32",
    "MD5" => "x-amz-checksum-md5",
    "SHA1" => "x-amz-checksum-sha1",
    "SHA256" => "x-amz-checksum-sha256"
  }

  @unsupported_sdk_algorithms ~w(CRC32C CRC64NVME SHA512 XXHASH3 XXHASH64 XXHASH128)

  @doc "Builds a checksum context from S3 upload request headers."
  @spec from_conn!(Plug.Conn.t()) :: t()
  def from_conn!(conn) do
    headers = conn.req_headers
    unsupported = unsupported_header(headers)

    if unsupported do
      raise Error.new(:not_implemented, message: "Unsupported checksum header: #{unsupported}")
    end

    if trailer_checksum?(headers) do
      raise Error.new(:not_implemented, message: "Checksum trailers are not implemented")
    end

    validate_sdk_algorithm!(headers)

    checks =
      headers
      |> content_md5_check()
      |> Kernel.++(hash_checks(headers))
      |> Kernel.++(crc32_checks(headers))

    %{
      checks: checks,
      response_headers: response_headers(checks),
      verify!: fn -> :ok end
    }
  end

  @doc "Rejects checksum headers on UploadPartCopy until copy checksum validation is implemented."
  @spec reject_upload_part_headers!(Plug.Conn.t()) :: :ok
  def reject_upload_part_headers!(conn) do
    cond do
      checksum_headers?(conn.req_headers) ->
        raise Error.new(:not_implemented,
                message: "UploadPartCopy checksum validation is not implemented"
              )

      trailer_checksum?(conn.req_headers) ->
        raise Error.new(:not_implemented,
                message: "UploadPartCopy checksum trailers are not implemented"
              )

      true ->
        :ok
    end
  end

  @doc """
  Wraps a chunk stream and returns `{stream, get_context, discard_context}`.

  The returned `get_context` function yields a checksum context after the stream
  has been fully consumed by storage.
  """
  @spec wrap_stream(Enumerable.t(), t()) :: {Enumerable.t(), (-> t()), (-> :ok)}
  def wrap_stream(chunks, %{checks: []} = checksum),
    do: {chunks, fn -> checksum end, fn -> :ok end}

  def wrap_stream(chunks, %{checks: checks} = checksum) do
    {:ok, agent} = Agent.start_link(fn -> checks end)

    stream =
      Stream.map(chunks, fn chunk ->
        chunk = IO.iodata_to_binary(chunk)
        Agent.update(agent, fn acc -> Enum.map(acc, &update_check(&1, chunk)) end)
        chunk
      end)

    get_context = fn ->
      final = agent |> Agent.get(& &1) |> finalize_checks()
      stop_agent(agent)

      %{
        checksum
        | response_headers: response_headers(final),
          verify!: fn -> verify!(final) end
      }
    end

    {stream, get_context, fn -> stop_agent(agent) end}
  end

  @doc "Adds checksum response headers for validated checksum requests."
  @spec put_response_headers(Plug.Conn.t(), t()) :: Plug.Conn.t()
  def put_response_headers(conn, %{response_headers: headers}) do
    Enum.reduce(headers, conn, fn {name, value}, acc -> put_resp_header(acc, name, value) end)
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

  defp update_check(%{kind: {:hash, _algorithm}, context: context} = check, chunk) do
    %{check | context: :crypto.hash_update(context, chunk)}
  end

  defp update_check(%{kind: :crc32, context: crc} = check, chunk) do
    %{check | context: :erlang.crc32(crc, chunk)}
  end

  defp finalize_checks(checks) do
    Enum.map(checks, fn %{context: context} = check ->
      check
      |> Map.put(:actual, final_value(check.kind, context))
      |> Map.put(:context, nil)
    end)
  end

  defp verify!(checks) do
    case Enum.find(checks, fn check -> check.actual != check.expected end) do
      nil ->
        :ok

      _check ->
        raise Error.new(:bad_digest)
    end
  end

  defp crc32_final(crc), do: <<crc::32>>

  defp final_value({:hash, _algorithm}, context), do: :crypto.hash_final(context)
  defp final_value(:crc32, crc), do: crc32_final(crc)

  defp stop_agent(agent) do
    Agent.stop(agent)
  catch
    :exit, _reason -> :ok
  end

  defp hash_length(:md5), do: 16
  defp hash_length(:sha), do: 20
  defp hash_length(:sha256), do: 32

  defp decode_base64!(value, expected_size) do
    case Base.decode64(String.trim(value)) do
      {:ok, decoded} when byte_size(decoded) == expected_size ->
        decoded

      {:ok, _decoded} ->
        raise Error.new(:bad_digest)

      :error ->
        raise Error.new(:bad_digest)
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

          algorithm in @unsupported_sdk_algorithms ->
            raise Error.new(:not_implemented,
                    message: "Unsupported checksum algorithm: #{algorithm}"
                  )

          true ->
            raise Error.new(:invalid_argument,
                    message: "Invalid x-amz-sdk-checksum-algorithm: #{raw}"
                  )
        end
    end
  end

  defp validate_supported_sdk_algorithm!(headers, algorithm) do
    expected_header = Map.fetch!(@sdk_algorithm_headers, algorithm)

    cond do
      header(headers, expected_header) ->
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

  defp checksum_headers?(headers) do
    Enum.any?(headers, fn {name, _value} ->
      name = String.downcase(name)

      name == "content-md5" or name == "x-amz-sdk-checksum-algorithm" or
        String.starts_with?(name, "x-amz-checksum-")
    end)
  end

  defp checksum_value_header?(headers) do
    Enum.any?(headers, fn {name, _value} ->
      name = String.downcase(name)
      String.starts_with?(name, "x-amz-checksum-") and name != "x-amz-checksum-type"
    end)
  end

  defp trailer_checksum?(headers) do
    headers
    |> header("x-amz-trailer")
    |> case do
      nil ->
        false

      trailer ->
        trailer
        |> String.split(",", trim: true)
        |> Enum.any?(fn name ->
          String.starts_with?(String.downcase(String.trim(name)), "x-amz-checksum-")
        end)
    end
  end

  defp response_headers(checks) do
    checks
    |> Enum.reject(&is_nil(&1.response_header))
    |> Enum.map(fn check ->
      {check.response_header, Base.encode64(Map.get(check, :actual, check.expected))}
    end)
  end

  defp header(headers, name) do
    headers
    |> Enum.find_value(fn {k, v} ->
      if String.downcase(k) == name, do: v
    end)
  end
end
