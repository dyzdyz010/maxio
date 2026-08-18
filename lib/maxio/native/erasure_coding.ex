defmodule Maxio.Native.ErasureCoding do
  @moduledoc """
  Reed-Solomon 纠删码 + BLAKE3 校验和的 Rust NIF 绑定（底层 reed-solomon-simd GF(2^16) SIMD + blake3）。

  契约："成功即返回值、非法即 raise"，与 `Huanxi.Geo.H3` 一致：
    * encode/3      —— (k, m, data :: binary) -> [shard :: binary]，共 N=k+m 个等长分片
                       （前 k 个数据分片 systematic、后 m 个校验分片）
    * reconstruct/3 —— (k, m, shards :: [binary | nil]) -> 重建后的数据 binary（含零填充，
                       调用方按对象元数据里的原始长度 L 截断）；存活 < k 时 raise
    * blake3/1      —— (data :: binary) -> 32 字节 BLAKE3-256 摘要（per-shard bitrot 校验和）

  底层 NIF（encode/reconstruct）返回 {:ok, _} / {:error, reason}（rustler 0.38 对 Rust Result 的标准编码），
  这里解包；{:error, _} 显式 raise ArgumentError，使调用方可安全假设拿到值（铁律 3：绝不静默）。
  blake3/1 永不失败，NIF 直接返回 binary。
  """
  alias Maxio.Native

  @type shard :: binary()

  @doc """
  把 `data` 编码为 k 个数据分片 + m 个校验分片，返回 N=k+m 个等长二进制分片。
  分片长为 even(ceil(byte_size(data)/k))；末尾数据分片零填充。
  调用方须保存原始 byte_size(data) 以便重建后截断。非法 k/m raise。
  """
  @spec encode(pos_integer(), pos_integer(), binary()) :: [shard()]
  def encode(data_shards, parity_shards, data)
      when is_integer(data_shards) and data_shards > 0 and
             is_integer(parity_shards) and parity_shards > 0 and is_binary(data) do
    unwrap!(
      Native.native_rs_encode(data_shards, parity_shards, data),
      {:encode, data_shards, parity_shards, byte_size(data)}
    )
  end

  def encode(data_shards, parity_shards, data) do
    raise ArgumentError,
          "ErasureCoding.encode 非法参数（铁律 3：绝不静默）：" <>
            "data_shards=#{inspect(data_shards)}（须正整数）、" <>
            "parity_shards=#{inspect(parity_shards)}（须正整数）、" <>
            "data=#{inspect(data, limit: 8)}（须 binary）"
  end

  @doc """
  从长度为 N=k+m 的分片列表重建原始数据（缺失/损坏分片置 nil）。
  至少需 k 个分片在场，否则 raise。返回值含零填充，调用方按原始长度截断。
  """
  @spec reconstruct(pos_integer(), pos_integer(), [shard() | nil]) :: binary()
  def reconstruct(data_shards, parity_shards, shards)
      when is_integer(data_shards) and data_shards > 0 and
             is_integer(parity_shards) and parity_shards > 0 and is_list(shards) do
    unwrap!(
      Native.native_rs_reconstruct(data_shards, parity_shards, shards),
      {:reconstruct, data_shards, parity_shards, length(shards)}
    )
  end

  def reconstruct(data_shards, parity_shards, shards) do
    raise ArgumentError,
          "ErasureCoding.reconstruct 非法参数（铁律 3：绝不静默）：" <>
            "data_shards=#{inspect(data_shards)}（须正整数）、" <>
            "parity_shards=#{inspect(parity_shards)}（须正整数）、" <>
            "shards=#{inspect(shards, limit: 4)}（须 list）"
  end

  @doc "BLAKE3-256 摘要（32 字节）。用于 per-shard bitrot 校验和。"
  @spec blake3(binary()) :: binary()
  def blake3(data) when is_binary(data), do: Native.native_blake3(data)

  # NIF 入口桩：未加载时 raise；加载后被替换为 Rust 实现。
  # 函数名与 src/lib.rs 中 #[rustler::nif] fn 名逐字一致（native_ 前缀）。
  defp unwrap!({:ok, value}, _ctx), do: value

  defp unwrap!({:error, reason}, ctx) do
    raise ArgumentError, "ErasureCoding #{inspect(ctx)} failed: #{inspect(reason)}"
  end
end
