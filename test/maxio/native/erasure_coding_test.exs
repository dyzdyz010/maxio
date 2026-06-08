defmodule Maxio.Native.ErasureCodingTest do
  use ExUnit.Case, async: true
  alias Maxio.Native.ErasureCoding, as: EC

  describe "encode/3" do
    test "返回 N=k+m 个等长 binary 分片，前 k 个 systematic 拼接=零填充原文" do
      data = :crypto.strong_rand_bytes(1000)
      shards = EC.encode(4, 2, data)
      assert length(shards) == 6
      assert Enum.all?(shards, &is_binary/1)
      lens = Enum.map(shards, &byte_size/1)
      assert lens |> Enum.uniq() |> length() == 1
      [len | _] = lens
      assert rem(len, 2) == 0
      # 前 4 个数据分片拼接后截断到原长 == 原文
      joined = shards |> Enum.take(4) |> IO.iodata_to_binary()
      assert binary_part(joined, 0, byte_size(data)) == data
    end

    test "空数据也能编码（分片长 >= 2 偶数）" do
      shards = EC.encode(3, 2, "")
      assert length(shards) == 5
      assert Enum.all?(shards, &(byte_size(&1) >= 2))
    end

    test "非法参数 raise" do
      assert_raise ArgumentError, fn -> EC.encode(0, 2, "x") end
      assert_raise ArgumentError, fn -> EC.encode(3, 0, "x") end
    end
  end

  describe "reconstruct/3（round-trip）" do
    setup do
      data = :crypto.strong_rand_bytes(5000)
      {:ok, data: data, k: 4, m: 2, shards: EC.encode(4, 2, data)}
    end

    test "无丢失：重建后截断 == 原文", %{data: data, k: k, m: m, shards: shards} do
      present = Enum.map(shards, & &1)
      out = EC.reconstruct(k, m, present)
      assert binary_part(out, 0, byte_size(data)) == data
    end

    test "丢失 1 个数据分片仍可重建", %{data: data, k: k, m: m, shards: shards} do
      shards = List.replace_at(shards, 0, nil)
      out = EC.reconstruct(k, m, shards)
      assert binary_part(out, 0, byte_size(data)) == data
    end

    test "丢失 M 个分片（数据+校验混合）仍可重建", %{data: data, k: k, m: m, shards: shards} do
      # 丢 1 个数据分片 + 1 个校验分片 = M=2 个
      shards = shards |> List.replace_at(1, nil) |> List.replace_at(5, nil)
      out = EC.reconstruct(k, m, shards)
      assert binary_part(out, 0, byte_size(data)) == data
    end

    test "丢失 M+1 个分片 -> raise（存活 < K）", %{k: k, m: m, shards: shards} do
      shards =
        shards
        |> List.replace_at(0, nil)
        |> List.replace_at(1, nil)
        |> List.replace_at(2, nil)

      assert_raise ArgumentError, fn -> EC.reconstruct(k, m, shards) end
    end

    test "分片数量与 N 不符 -> raise", %{k: k, m: m, shards: shards} do
      assert_raise ArgumentError, fn -> EC.reconstruct(k, m, Enum.take(shards, 5)) end
    end
  end

  describe "blake3/1" do
    test "返回 32 字节摘要，确定性，输入不同摘要不同" do
      h1 = EC.blake3("hello")
      h2 = EC.blake3("hello")
      h3 = EC.blake3("hellp")
      assert byte_size(h1) == 32
      assert h1 == h2
      assert h1 != h3
    end
  end
end
