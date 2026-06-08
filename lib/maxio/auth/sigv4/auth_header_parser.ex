defmodule Maxio.Auth.SigV4.AuthHeaderParser do
  @moduledoc """
  解析 SigV4 签名材料：header-based（Authorization 头 + x-amz-date + x-amz-content-sha256）
  与 presigned（X-Amz-* query 参数）。产出统一 %SignedRequest{}。
  """
  alias Maxio.Auth.SigV4.SignedRequest

  @doc """
  解析 header-based。auth = Authorization 头值；amz_date = x-amz-date 头；
  content_sha256 = x-amz-content-sha256 头（决定 payload_mode）。
  """
  @spec parse_header(String.t(), String.t(), String.t()) ::
          {:ok, SignedRequest.t()} | {:error, :authorization_header_malformed}
  def parse_header(auth, amz_date, content_sha256) when is_binary(auth) do
    with "AWS4-HMAC-SHA256 " <> rest <- auth,
         {:ok, parts} <- split_kv(rest),
         {:ok, credential} <- Map.fetch(parts, "Credential"),
         {:ok, signed_headers_str} <- Map.fetch(parts, "SignedHeaders"),
         {:ok, signature} <- Map.fetch(parts, "Signature"),
         {:ok, {ak, date, region, service}} <- parse_credential(credential) do
      {:ok,
       %SignedRequest{
         access_key: ak,
         scope_date: date,
         region: region,
         service: service,
         signed_headers: String.split(signed_headers_str, ";", trim: true),
         signature: signature,
         amz_date: amz_date,
         auth_type: :header,
         payload_mode: payload_mode(content_sha256),
         expires: nil
       }}
    else
      _ -> {:error, :authorization_header_malformed}
    end
  end

  @doc "解析 presigned X-Amz-* query 参数。"
  @spec parse_presigned(map()) ::
          {:ok, SignedRequest.t()} | {:error, :authorization_query_parameters_error}
  def parse_presigned(query) when is_map(query) do
    with {:ok, "AWS4-HMAC-SHA256"} <- Map.fetch(query, "X-Amz-Algorithm"),
         {:ok, credential} <- Map.fetch(query, "X-Amz-Credential"),
         {:ok, amz_date} <- Map.fetch(query, "X-Amz-Date"),
         {:ok, expires_str} <- Map.fetch(query, "X-Amz-Expires"),
         {:ok, signed_headers_str} <- Map.fetch(query, "X-Amz-SignedHeaders"),
         {:ok, signature} <- Map.fetch(query, "X-Amz-Signature"),
         {expires, ""} <- Integer.parse(expires_str),
         {:ok, {ak, date, region, service}} <- parse_credential(credential) do
      {:ok,
       %SignedRequest{
         access_key: ak,
         scope_date: date,
         region: region,
         service: service,
         signed_headers: String.split(signed_headers_str, ";", trim: true),
         signature: signature,
         amz_date: amz_date,
         auth_type: :presigned,
         payload_mode: :unsigned,
         expires: expires
       }}
    else
      _ -> {:error, :authorization_query_parameters_error}
    end
  end

  # "k1=v1,k2=v2,..." → %{"k1"=>"v1", ...}（值里可能含 / 和 ;，故按首个 = 切）
  defp split_kv(str) do
    map =
      str
      |> String.split(",", trim: true)
      |> Enum.map(&String.trim/1)
      |> Enum.map(fn pair ->
        case String.split(pair, "=", parts: 2) do
          [k, v] -> {k, v}
          _ -> {pair, nil}
        end
      end)
      |> Enum.into(%{})

    if Map.has_key?(map, "Credential") and Map.has_key?(map, "Signature") do
      {:ok, map}
    else
      :error
    end
  end

  # "AK/date/region/service/aws4_request" → {ak, date, region, service}
  defp parse_credential(credential) do
    case String.split(credential, "/") do
      [ak, date, region, service, "aws4_request"] -> {:ok, {ak, date, region, service}}
      _ -> :error
    end
  end

  defp payload_mode("UNSIGNED-PAYLOAD"), do: :unsigned
  defp payload_mode("STREAMING-AWS4-HMAC-SHA256-PAYLOAD"), do: :streaming
  defp payload_mode("STREAMING-AWS4-HMAC-SHA256-PAYLOAD-TRAILER"), do: :streaming
  defp payload_mode("STREAMING-UNSIGNED-PAYLOAD-TRAILER"), do: :streaming
  defp payload_mode(_hash), do: :single
end
