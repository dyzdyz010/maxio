defmodule Maxio.S3.URLEncode do
  @moduledoc """
  S3 列表响应 `encoding-type=url` 专用 URL 编码（对齐 MinIO `cmd/api-utils.go` 的
  `s3URLEncode` / `shouldEscape`，铁律 5）。

  这与 SigV4 CanonicalQueryString 的 `Maxio.Auth.SigV4.Canonical.uri_encode/2` 是
  **两套不同的编码语义**，绝不可混用：

    * SigV4（RFC3986 单次编码）：unreserved 含 `~`；空格编为 `%20`；`/` 在 query 模式编为 `%2F`。
    * S3 list `encoding-type=url`（MinIO s3URLEncode）：不转义 `A-Za-z0-9` 与 `-_.~/*`（**保留 `/`**，
      故 delimiter / CommonPrefixes 的伪目录语义不被破坏）；空格编为 `+`；其余每字节 `%XY`（大写 hex）。

  AWS S3 与 MinIO 的 `encoding-type=url` 都保留字面 `/`：
  例如 key `enc1/test file(3).png` 经此编码得 `enc1/test+file%283%29.png`，delimiter `/` 仍为 `/`。
  """

  # MinIO shouldEscape 不转义的非字母数字字节集合（外加 '~'，与 Go net/url 一致地视为 unreserved）。
  @unescaped [?-, ?_, ?., ?~, ?/, ?*]

  @doc """
  按 MinIO `s3URLEncode` 编码字符串：保留 `A-Za-z0-9` 与 `-_.~/*`，空格→`+`，其余字节→`%XY`（大写）。
  """
  @spec encode(String.t()) :: String.t()
  def encode(str) when is_binary(str) do
    str
    |> :binary.bin_to_list()
    |> Enum.map_join("", &encode_byte/1)
  end

  defp encode_byte(byte) do
    cond do
      unescaped?(byte) -> <<byte>>
      byte == ?\s -> "+"
      true -> "%" <> (byte |> Integer.to_string(16) |> String.upcase() |> String.pad_leading(2, "0"))
    end
  end

  defp unescaped?(b) do
    (b >= ?A and b <= ?Z) or (b >= ?a and b <= ?z) or (b >= ?0 and b <= ?9) or b in @unescaped
  end
end
