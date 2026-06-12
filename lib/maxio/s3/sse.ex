defmodule Maxio.S3.SSE do
  @moduledoc """
  Shared S3 SSE request-header handling.

  This module only decides the S3-visible algorithm and rejects unsupported
  customer/KMS modes. Actual at-rest encryption stays in `Maxio.Crypto.SSE`.
  """
  import Plug.Conn, only: [put_resp_header: 3]

  alias Maxio.BucketConfigs
  alias Maxio.S3.Error

  @target_sse_c_prefix "x-amz-server-side-encryption-customer-"
  @copy_source_sse_c_prefix "x-amz-copy-source-server-side-encryption-customer-"

  @spec resolve_target!(Plug.Conn.req_headers(), String.t()) :: String.t() | nil
  def resolve_target!(req_headers, bucket) when is_list(req_headers) do
    reject_customer_headers!(
      req_headers,
      @target_sse_c_prefix,
      "SSE-C (customer-provided keys) not implemented"
    )

    case header(req_headers, "x-amz-server-side-encryption") do
      "AES256" ->
        "AES256"

      alg when alg in ["aws:kms", "aws:kms:dsse"] ->
        raise Error.new(:not_implemented,
                message: "Only SSE-S3 (AES256) is supported; #{alg} not implemented"
              )

      nil ->
        bucket_default_sse(bucket)

      "" ->
        bucket_default_sse(bucket)

      _other ->
        raise Error.new(:invalid_argument, message: "Invalid x-amz-server-side-encryption value")
    end
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
      nil -> false
      "" -> false
      _ -> true
    end
  end

  @spec put_response_header(Plug.Conn.t(), String.t() | nil) :: Plug.Conn.t()
  def put_response_header(conn, nil), do: conn

  def put_response_header(conn, alg),
    do: put_resp_header(conn, "x-amz-server-side-encryption", alg)

  defp reject_customer_headers!(req_headers, prefix, message) do
    has_customer_header? =
      Enum.any?(req_headers, fn {name, value} ->
        String.starts_with?(String.downcase(to_string(name)), prefix) and value not in [nil, ""]
      end)

    if has_customer_header? do
      raise Error.new(:not_implemented, message: message)
    end

    :ok
  end

  defp bucket_default_sse(bucket) do
    case BucketConfigs.get(bucket, :encryption) do
      {:ok, %{"algorithm" => "AES256"}} -> "AES256"
      _ -> nil
    end
  end

  defp header(req_headers, name) do
    needle = String.downcase(name)

    Enum.find_value(req_headers, fn {header_name, value} ->
      if String.downcase(to_string(header_name)) == needle, do: value, else: nil
    end)
  end
end
