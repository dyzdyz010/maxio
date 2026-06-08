defmodule Maxio.Storage.Erasure.CodecTest do
  use ExUnit.Case, async: true
  import Bitwise
  alias Maxio.Storage.Erasure.{Codec, Config, InsufficientShardsError}

  defp cfg,
    do: Config.load!(drives: for(i <- 0..5, do: "/d#{i}"), data_shards: 4, parity_shards: 2)

  test "split_block 产出 N 个等长分片 + N 个 32 字节校验和" do
    block = :crypto.strong_rand_bytes(900)
    %{shards: shards, checksums: cks, shard_len: sl} = Codec.split_block(cfg(), block)
    assert length(shards) == 6
    assert length(cks) == 6
    assert Enum.all?(shards, &(byte_size(&1) == sl))
    assert Enum.all?(cks, &(byte_size(&1) == 32))
    assert rem(sl, 2) == 0
  end

  test "split -> restore round-trip（无丢失）还原原文" do
    block = :crypto.strong_rand_bytes(900)
    %{shards: shards, checksums: cks} = Codec.split_block(cfg(), block)
    out = Codec.restore_block(cfg(), shards, cks, byte_size(block))
    assert out == block
  end

  test "restore 容忍 M 个 nil 分片" do
    block = :crypto.strong_rand_bytes(2048)
    %{shards: shards, checksums: cks} = Codec.split_block(cfg(), block)
    damaged = shards |> List.replace_at(0, nil) |> List.replace_at(5, nil)
    out = Codec.restore_block(cfg(), damaged, cks, byte_size(block))
    assert out == block
  end

  test "restore 检测 bitrot（分片被篡改但非 nil）-> 校验和不符置 nil -> 仍重建" do
    block = :crypto.strong_rand_bytes(2048)
    %{shards: shards, checksums: cks} = Codec.split_block(cfg(), block)
    # 篡改第 0 个分片的首字节（校验和将不匹配，应被当作缺失）
    corrupt =
      List.update_at(shards, 0, fn <<b, rest::binary>> -> <<bxor(b, 0xFF), rest::binary>> end)

    out = Codec.restore_block(cfg(), corrupt, cks, byte_size(block))
    assert out == block
  end

  test "存活分片 < K（含篡改）-> raise InsufficientShardsError" do
    block = :crypto.strong_rand_bytes(2048)
    %{shards: shards, checksums: cks} = Codec.split_block(cfg(), block)
    # 置 nil 2 个 + 篡改 1 个 = 3 个失效 > M=2，存活 3 < K=4
    bad =
      shards
      |> List.replace_at(0, nil)
      |> List.replace_at(1, nil)
      |> List.update_at(2, fn <<b, rest::binary>> -> <<bxor(b, 0xFF), rest::binary>> end)

    assert_raise InsufficientShardsError, fn ->
      Codec.restore_block(cfg(), bad, cks, byte_size(block), bucket: "b", key: "k", block_index: 0)
    end
  end

  test "verify_shard：nil -> false；匹配 -> true；篡改 -> false" do
    block = :crypto.strong_rand_bytes(128)
    %{shards: [s0 | _], checksums: [c0 | _]} = Codec.split_block(cfg(), block)
    assert Codec.verify_shard(s0, c0)
    refute Codec.verify_shard(nil, c0)
    <<b, rest::binary>> = s0
    refute Codec.verify_shard(<<bxor(b, 0xFF), rest::binary>>, c0)
  end
end
