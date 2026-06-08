defmodule Maxio.S3.RawPath do
  @moduledoc """
  原始请求目标（request-target）解析的**单一事实来源**（铁律 1/2/5）。

  ## 为什么不能用 `conn.path_info`

  生产 Bandit 适配器经 `Plug.Router.Utils.split/1` 生成 `conn.path_info`，它对路径做了
  两件**有损**处理：

    1. **URL 解码**每个 segment；
    2. **折叠空 segment**（合并连续 `/`、丢弃首尾 `/`）。

  这对 S3 是致命的：

    * 对象 key `"dir/"`（文件夹标记，AWS Console / 多数 SDK 极常见）→ `path_info`
      `["bucket","dir"]` → key 退化成 `"dir"`（**数据丢失**），且重建的 CanonicalURI
      `/bucket/dir` ≠ 客户端签名的 `/bucket/dir/` → 误判 403 SignatureDoesNotMatch；
    * `"a//b.txt"`、`"/leading.txt"` 同理被折叠破坏。

  铁律 5（对齐真实 AWS、不归一化、保留 `/`）要求：签名用的 CanonicalURI 与对象 key
  必须忠实于客户端发来的**原始字节**，绝不归一化。

  ## 本模块的契约

  以 `conn.request_path`（适配器保留的**原始、未解码、未折叠**请求目标）为权威来源：

    * `decoded_path/1`：对原始 request_path 做**单次** URL 解码（保留所有 `/`、空段），
      得到“已解码绝对路径”——正是 `Maxio.Auth.SigV4.Canonical` 约定的入参（它内部再做
      S3 单次 UriEncode，与客户端签名前的编码一一对应，往返无损）；
    * `path_style/1` / `vhost_key/1`：从原始 request_path 切出 bucket 与 object key，
      对 key 仅做**单次**解码且不折叠 `/`，从根上避免 `path_info` 的有损行为。

  S3 行为对齐说明：原始目标中的 `%2F`（编码斜杠）经单次解码变成字面 `/`，这与真实
  AWS SDK 签名前对 path 单次解码、并把 `%2F` 当作 key 内字面 `/` 的行为一致。
  """

  @doc """
  已解码的绝对路径（SigV4 CanonicalURI 与错误 `resource` 用）。

  对 `conn.request_path` 做单次 URL 解码，保留全部斜杠与空段、不归一化。
  """
  @spec decoded_path(Plug.Conn.t()) :: String.t()
  def decoded_path(conn) do
    decode_once(conn.request_path)
  end

  @doc """
  path-style 寻址：从原始 request_path 切出 `{bucket, key}`。

    * `"/"`                 → `{nil, nil}`（service 级）
    * `"/bucket"`           → `{"bucket", nil}`（bucket 级，无 key）
    * `"/bucket/"`          → `{"bucket", ""}`（bucket 级，空 key——对齐 AWS）
    * `"/bucket/<key...>"`  → `{"bucket", decode_once("<key...>")}`（object 级，保留层级/尾斜杠）

  bucket 段（首个 `/` 之前）本身不含 `/`，单次解码安全；key 段保留内部 `/`、空段、尾斜杠。
  """
  @spec path_style(Plug.Conn.t()) :: {String.t() | nil, String.t() | nil}
  def path_style(conn) do
    case strip_leading_slash(conn.request_path) do
      "" ->
        {nil, nil}

      rest ->
        case String.split(rest, "/", parts: 2) do
          [bucket] -> {decode_once(bucket), nil}
          [bucket, key_raw] -> {decode_once(bucket), decode_once(key_raw)}
        end
    end
  end

  @doc """
  virtual-host 寻址：bucket 来自子域，object key = 整个原始 path 单次解码（保留 `/`、空段）。

    * `"/"`            → `nil`（bucket 级，无 key）
    * `"/<key...>"`    → `decode_once("<key...>")`
  """
  @spec vhost_key(Plug.Conn.t()) :: String.t() | nil
  def vhost_key(conn) do
    case strip_leading_slash(conn.request_path) do
      "" -> nil
      rest -> decode_once(rest)
    end
  end

  # 单次 percent-decode（不折叠 `/`、不归一化）。URI.decode/1 保留字面 `/` 与空段。
  defp decode_once(raw), do: URI.decode(raw)

  defp strip_leading_slash("/" <> rest), do: rest
  defp strip_leading_slash(other), do: other
end
