defmodule Maxio.Storage.Erasure.Codec do
  @moduledoc """
  纠删码块编解码（纯 Elixir，over Maxio.Native.ErasureCoding NIF）。

    * split_block/2    —— 把一个 block 编码为 N=K+M 个等长分片 + 每分片一个 BLAKE3-256 校验和。
    * restore_block/5  —— 验证每个非 nil 分片的校验和（不匹配/缺失视为丢失），从存活分片重建并截断到
                          原始 block 长度。**存活 < K（read quorum）-> raise InsufficientShardsError**（铁律 3）。
    * verify_shard/2   —— 单分片校验和验证（nil -> false）。

  RS 只纠 erasure（已知缺失），不定位 silent corruption；本层用校验和把损坏分片显式标记为缺失，
  再交 NIF 重建——这是 bitrot 安全的关键：绝不把"在场但损坏"的分片当好分片喂解码器。
  """
  alias Maxio.Native.ErasureCoding
  alias Maxio.Storage.Erasure.{Config, InsufficientShardsError}

  @type split :: %{shards: [binary()], checksums: [binary()], shard_len: pos_integer()}

  @doc "把 block 切成 N 个分片 + N 个 BLAKE3-256 校验和。"
  @spec split_block(Config.t(), binary()) :: split()
  def split_block(%Config{data_shards: k, parity_shards: m}, block) when is_binary(block) do
    shards = ErasureCoding.encode(k, m, block)
    checksums = Enum.map(shards, &ErasureCoding.blake3/1)
    [first | _] = shards
    %{shards: shards, checksums: checksums, shard_len: byte_size(first)}
  end

  @doc "验证单个分片：nil 或校验和不符 -> false。"
  @spec verify_shard(binary() | nil, binary()) :: boolean()
  def verify_shard(nil, _checksum), do: false

  def verify_shard(shard, checksum) when is_binary(shard) and is_binary(checksum) do
    ErasureCoding.blake3(shard) == checksum
  end

  @doc """
  从 N 个分片（缺失/损坏为 nil）+ N 个存储校验和重建 block，截断到 data_len。
  逐分片验证校验和：不通过的强制置 nil（视为缺失）。存活 >= K -> 重建+截断；< K -> raise。
  `meta` 为可选元数据（bucket/key/version_id/block_index）用于结构化异常/日志。
  """
  @spec restore_block(Config.t(), [binary() | nil], [binary()], non_neg_integer(), keyword()) ::
          binary()
  def restore_block(%Config{} = cfg, shards, checksums, data_len, meta \\ [])
      when is_list(shards) and is_list(checksums) and is_integer(data_len) and data_len >= 0 do
    %Config{data_shards: k, parity_shards: m, read_quorum: read_quorum} = cfg

    verified =
      shards
      |> Enum.zip(checksums)
      |> Enum.map(fn {shard, ck} -> if verify_shard(shard, ck), do: shard, else: nil end)

    present = Enum.count(verified, &(&1 != nil))

    if present < read_quorum do
      raise InsufficientShardsError,
        bucket: Keyword.get(meta, :bucket),
        key: Keyword.get(meta, :key),
        version_id: Keyword.get(meta, :version_id),
        block_index: Keyword.get(meta, :block_index),
        present: present,
        required: read_quorum
    end

    padded = ErasureCoding.reconstruct(k, m, verified)
    binary_part(padded, 0, min(data_len, byte_size(padded)))
  end
end
