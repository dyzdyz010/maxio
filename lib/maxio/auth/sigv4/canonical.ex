defmodule Maxio.Auth.SigV4.Canonical do
  @moduledoc """
  SigV4 Canonical Request 构造（纯函数）。S3 特例：单次编码、路径不归一化。
  入参 req: %{method, path, query (map name=>value), headers ([{lname, value}]), payload_hash}。
  其中 path 是**已 URL 解码的绝对路径**（对象 key 的真实字节），本模块负责再做 S3 的单次 UriEncode。
  headers 的 name 须已小写，且为参与签名的 SignedHeaders 集合（调用方按 SignedHeaders 过滤后传入）。
  """

  @doc "组装 6 段 canonical request，以 \\n 连接（末段无换行）。"
  @spec canonical_request(map()) :: String.t()
  def canonical_request(%{
        method: method,
        path: path,
        query: query,
        headers: headers,
        payload_hash: payload_hash
      }) do
    [
      String.upcase(method),
      canonical_uri(path),
      canonical_query(query),
      canonical_headers(headers),
      signed_headers(headers),
      payload_hash
    ]
    |> Enum.join("\n")
  end

  @doc "CanonicalURI：S3 单次编码且不编码 /；空路径用 /。不归一化。"
  @spec canonical_uri(String.t()) :: String.t()
  def canonical_uri(""), do: "/"
  def canonical_uri(nil), do: "/"
  def canonical_uri(path), do: uri_encode(path, :path)

  @doc """
  CanonicalQueryString：每个 name/value 单独 UriEncode（query 模式，编码 /），
  按编码后 name 字典序排序，key=value 以 & 连接，空值保留 `key=`。
  """
  @spec canonical_query(map()) :: String.t()
  def canonical_query(query) when is_map(query) do
    query
    |> Enum.map(fn {k, v} -> {uri_encode(to_string(k), :query), uri_encode(to_string(v), :query)} end)
    |> Enum.sort_by(fn {k, _v} -> k end)
    |> Enum.map(fn {k, v} -> k <> "=" <> v end)
    |> Enum.join("&")
  end

  @doc "CanonicalHeaders：每行 lname:trimall(value)\\n，按 lname 排序。整体以 \\n 结尾。"
  @spec canonical_headers([{String.t(), String.t()}]) :: String.t()
  def canonical_headers(headers) do
    headers
    |> Enum.map(fn {name, value} -> {String.downcase(name), trimall(value)} end)
    |> Enum.sort_by(fn {name, _v} -> name end)
    |> Enum.map(fn {name, value} -> name <> ":" <> value <> "\n" end)
    |> Enum.join("")
  end

  @doc "SignedHeaders：小写名按字典序、分号连接。"
  @spec signed_headers([{String.t(), String.t()}]) :: String.t()
  def signed_headers(headers) do
    headers
    |> Enum.map(fn {name, _v} -> String.downcase(name) end)
    |> Enum.sort()
    |> Enum.join(";")
  end

  @doc """
  自写 UriEncode。unreserved（A-Za-z0-9-_.~）原样；其余每字节 %XY 大写 hex；
  mode=:path 时额外保留 `/`（S3 CanonicalURI 不编码斜杠），mode=:query 时编码 `/`→%2F。
  """
  @spec uri_encode(String.t(), :path | :query) :: String.t()
  def uri_encode(str, mode) do
    str
    |> :binary.bin_to_list()
    |> Enum.map_join("", fn byte -> encode_byte(byte, mode) end)
  end

  defp encode_byte(byte, mode) do
    cond do
      unreserved?(byte) -> <<byte>>
      byte == ?/ and mode == :path -> "/"
      true -> "%" <> (byte |> Integer.to_string(16) |> String.upcase() |> String.pad_leading(2, "0"))
    end
  end

  defp unreserved?(b) do
    (b >= ?A and b <= ?Z) or (b >= ?a and b <= ?z) or (b >= ?0 and b <= ?9) or
      b in [?-, ?_, ?., ?~]
  end

  @doc "trimall：去首尾空白 + 内部连续空白折叠为单空格。"
  @spec trimall(String.t()) :: String.t()
  def trimall(value) do
    value
    |> String.trim()
    |> String.replace(~r/\s+/, " ")
  end
end
