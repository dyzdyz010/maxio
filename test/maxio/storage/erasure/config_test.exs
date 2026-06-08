defmodule Maxio.Storage.Erasure.ConfigTest do
  use ExUnit.Case, async: true
  alias Maxio.Storage.Erasure.Config

  defp drives(n), do: for(i <- 0..(n - 1), do: "/d#{i}")

  test "load! 合并 opts，计算 quorum（M < N/2 -> write_quorum = K）" do
    cfg = Config.load!(drives: drives(6), data_shards: 4, parity_shards: 2, block_size: 1024)
    assert cfg.data_shards == 4
    assert cfg.parity_shards == 2
    assert cfg.block_size == 1024
    assert cfg.read_quorum == 4
    assert cfg.write_quorum == 4
    assert Config.total(cfg) == 6
  end

  test "M == N/2（脑裂边界）-> write_quorum = K+1" do
    cfg = Config.load!(drives: drives(8), data_shards: 4, parity_shards: 4)
    assert cfg.read_quorum == 4
    assert cfg.write_quorum == 5
  end

  test "drives 数量与 K+M 不符 -> raise" do
    assert_raise ArgumentError, fn ->
      Config.load!(drives: drives(5), data_shards: 4, parity_shards: 2)
    end
  end

  test "M < 1 或 M > N/2 -> raise" do
    assert_raise ArgumentError, fn ->
      Config.load!(drives: drives(4), data_shards: 4, parity_shards: 0)
    end

    assert_raise ArgumentError, fn ->
      # M=3 > N/2=2.5 (N=5)
      Config.load!(drives: drives(5), data_shards: 2, parity_shards: 3)
    end
  end
end
