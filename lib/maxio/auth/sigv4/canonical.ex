defmodule Maxio.Auth.SigV4.Canonical do
  @moduledoc """
  SigV4 Canonical Request 构造（纯函数）。S3 特例：单次编码、路径不归一化。
  入参 req: %{method, path, query (map name=>value), headers ([{lname, value}]), payload_hash}。
  其中 path 是**已 URL 解码的绝对路径**（对象 key 的真实字节），本模块负责再做 S3 的单次 UriEncode。
  headers 为参与签名的 SignedHeaders 集合（调用方按 SignedHeaders 过滤后传入）；名称在此处
  大小写不敏感地归组，同名值按到达顺序合并。
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
  CanonicalQueryString。两种入参：
    * **raw query 字符串**（推荐，SigV4 plug 传 conn.query_string）：按 '&' 切对、每对按首个 '='
      切 name/value，用严格 RFC3986 解码（URI.decode/1，**绝不**把 '+' 当空格），再 query-模式
      UriEncode，按编码后 name 排序。这保证客户端字面 '+'（wire 上 %2B）canonicalize 回 %2B
      而非 %20（对齐 AWS / MinIO RawQuery 语义，铁律 5）。
    * **map**（向后兼容既有纯函数测试/调用方）：对每个 name/value 直接 query-模式 UriEncode 后排序。
  两种入参对"无 '+'/无重复键"的普通请求结果完全一致。空值保留 `key=`。
  """
  @spec canonical_query(String.t() | map()) :: String.t()
  def canonical_query(query) when is_binary(query) do
    query
    |> split_raw_query()
    |> Enum.map(fn {k, v} ->
      {uri_encode(decode_strict(k), :query), uri_encode(decode_strict(v), :query)}
    end)
    |> Enum.sort_by(fn {k, v} -> {k, v} end)
    |> Enum.map(fn {k, v} -> k <> "=" <> v end)
    |> Enum.join("&")
  end

  def canonical_query(query) when is_map(query) do
    query
    |> Enum.map(fn {k, v} ->
      {uri_encode(to_string(k), :query), uri_encode(to_string(v), :query)}
    end)
    |> Enum.sort_by(fn {k, _v} -> k end)
    |> Enum.map(fn {k, v} -> k <> "=" <> v end)
    |> Enum.join("&")
  end

  # 把 raw query 切成 [{name, value}]（保留重复键，值缺省为 ""）。空串 → []。
  defp split_raw_query(""), do: []

  defp split_raw_query(raw) do
    raw
    |> String.split("&", trim: true)
    |> Enum.map(fn pair ->
      case String.split(pair, "=", parts: 2) do
        [k, v] -> {k, v}
        [k] -> {k, ""}
      end
    end)
  end

  # 严格 RFC3986 percent-decode：只解 %XX，**绝不**把 '+' 当空格（区别于 URI.decode_www_form/1）。
  defp decode_strict(str), do: URI.decode(str)

  @doc "CanonicalHeaders：同名头大小写不敏感归组，各值 Trimall 后按到达顺序逗号连接；名称排序。"
  @spec canonical_headers([{String.t(), String.t()}]) :: String.t()
  def canonical_headers(headers) do
    headers
    |> grouped_headers()
    |> Enum.map(fn {name, values} -> name <> ":" <> Enum.join(values, ",") <> "\n" end)
    |> Enum.join("")
  end

  @doc "SignedHeaders：去重后的小写名按字典序、分号连接。"
  @spec signed_headers([{String.t(), String.t()}]) :: String.t()
  def signed_headers(headers) do
    headers
    |> grouped_headers()
    |> Enum.map(fn {name, _values} -> name end)
    |> Enum.join(";")
  end

  defp grouped_headers(headers) do
    headers
    |> Enum.reduce(%{}, fn {name, value}, grouped ->
      name = String.downcase(name)
      value = trimall(value)
      Map.update(grouped, name, [value], &[value | &1])
    end)
    |> Enum.map(fn {name, reversed_values} -> {name, Enum.reverse(reversed_values)} end)
    |> Enum.sort_by(fn {name, _values} -> name end)
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
      unreserved?(byte) ->
        <<byte>>

      byte == ?/ and mode == :path ->
        "/"

      true ->
        "%" <> (byte |> Integer.to_string(16) |> String.upcase() |> String.pad_leading(2, "0"))
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
