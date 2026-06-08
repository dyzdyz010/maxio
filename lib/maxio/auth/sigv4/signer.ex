defmodule Maxio.Auth.SigV4.Signer do
  @moduledoc """
  SigV4 StringToSign + signing key HMAC 链 + 最终签名（OTP :crypto，无外部依赖）。
  中间 HMAC 结果是原始 32 字节二进制（绝不 hex 化），只有最终签名 hex 小写。
  签名比对用 Plug.Crypto.secure_compare/2（常数时间，防时序侧信道）。
  """

  @doc "hex(SHA256(data))，小写。"
  @spec hex_sha256(iodata()) :: String.t()
  def hex_sha256(data) do
    :crypto.hash(:sha256, data) |> Base.encode16(case: :lower)
  end

  @doc "StringToSign：algorithm ⏎ amz_date ⏎ scope ⏎ hex(SHA256(canonical_request))，无尾换行。"
  @spec string_to_sign(String.t(), String.t(), String.t(), String.t()) :: String.t()
  def string_to_sign(amz_date, scope, canonical_request, algorithm) do
    Enum.join([algorithm, amz_date, scope, hex_sha256(canonical_request)], "\n")
  end

  @doc """
  推导 signing key（HMAC-SHA256 链）：
    kDate=HMAC("AWS4"+secret, yyyymmdd) → kRegion=HMAC(kDate, region)
    → kService=HMAC(kRegion, service) → kSigning=HMAC(kService, "aws4_request")
  返回原始二进制。
  """
  @spec derive_signing_key(String.t(), String.t(), String.t(), String.t()) :: binary()
  def derive_signing_key(secret, scope_date, region, service) do
    k_date = hmac("AWS4" <> secret, scope_date)
    k_region = hmac(k_date, region)
    k_service = hmac(k_region, service)
    hmac(k_service, "aws4_request")
  end

  @doc "最终签名 = hex(HMAC(signing_key, string_to_sign))，小写。"
  @spec signature(binary(), String.t()) :: String.t()
  def signature(signing_key, string_to_sign) do
    hmac(signing_key, string_to_sign) |> Base.encode16(case: :lower)
  end

  @doc "常数时间签名比对。"
  @spec secure_compare(binary(), binary()) :: boolean()
  def secure_compare(a, b) when is_binary(a) and is_binary(b) do
    Plug.Crypto.secure_compare(a, b)
  end

  defp hmac(key, data), do: :crypto.mac(:hmac, :sha256, key, data)
end
