defmodule Maxio.Versioning.VersionId do
  @moduledoc """
  对象版本 ID 生成（ULID：48-bit 毫秒时间戳 + 80-bit 随机，Crockford base32 编码为 26 字符）。
  时间有序（字典序 = 时间序）让 ListObjectVersions 的「key 内 newest-first」= ORDER BY version_id DESC；
  同毫秒并发 PUT 由 80-bit 随机后缀给确定性 tiebreak。URL-safe、≤1024 字节（对齐 AWS version ID 约束）。
  保留串 "null" 表示无版本（Unversioned/Suspended 写入），绝不由 generate 产出（铁律 5）。
  """
  # Crockford base32 字母表（无 I L O U，避免歧义）。
  @crockford ~c"0123456789ABCDEFGHJKMNPQRSTVWXYZ"

  @doc "生成一个新 ULID（26 字符）。"
  @spec generate() :: String.t()
  def generate do
    ts = System.system_time(:millisecond)
    <<rand::80>> = :crypto.strong_rand_bytes(10)
    # 128-bit：48-bit 时间戳 + 80-bit 随机 → 26 个 5-bit 组 base32。
    <<int::128>> = <<ts::48, rand::80>>
    encode(int)
  end

  @doc "无版本保留串。"
  @spec null_sentinel() :: String.t()
  def null_sentinel, do: "null"

  # 把 128-bit 整数编码为 26 字符 Crockford base32（高位在前）。
  defp encode(int) do
    # 26 * 5 = 130 bit；左侧补 2 个 0 bit 到 130 再切 26 组。
    <<g::5, rest::bitstring>> = <<0::2, int::128>>
    do_encode(<<g::5, rest::bitstring>>, [])
  end

  defp do_encode(<<>>, acc), do: acc |> Enum.reverse() |> List.to_string()

  defp do_encode(<<g::5, rest::bitstring>>, acc) do
    do_encode(rest, [Enum.at(@crockford, g) | acc])
  end
end
