defmodule Maxio.Storage.Erasure.BitrotE2ETest do
  @moduledoc """
  bitrot 端到端取证（铁律 3）：写对象 -> 删/损坏 ≤ M 个分片 -> GET 仍返回正确字节（decode-on-read）；
  heal 回写恢复全冗余；删 M+1 个分片 -> GET raise（结构化错误，绝不静默返回错数据）。
  """
  use ExUnit.Case, async: true
  import Bitwise

  alias Maxio.Storage.ErasureCoded
  alias Maxio.Storage.Erasure.{Heal, InsufficientShardsError}

  setup do
    base = Path.join(System.tmp_dir!(), "maxio_bitrot_#{System.unique_integer([:positive])}")
    drives = for i <- 0..5, do: Path.join(base, "d#{i}")
    Enum.each(drives, &File.mkdir_p!/1)
    on_exit(fn -> File.rm_rf(base) end)
    {:ok, drives: drives}
  end

  defp o(drives), do: [drives: drives, data_shards: 4, parity_shards: 2, block_size: 1024]
  defp part(drive, b, k), do: Path.join([drive, b, k, "part.0"])

  test "删 M 个分片 GET 仍正确，heal 后冗余恢复", %{drives: drives} do
    :ok = ErasureCoded.put_bucket("b", o(drives))
    body = :crypto.strong_rand_bytes(5000)
    {:ok, _} = ErasureCoded.put("b", "k", "null", [body], o(drives))

    # 删 2 个盘（M=2）
    Enum.each([0, 5], fn i -> File.rm_rf!(Path.join([Enum.at(drives, i), "b", "k"])) end)

    {:ok, stream} = ErasureCoded.get("b", "k", "null", nil, o(drives))
    assert IO.iodata_to_binary(Enum.to_list(stream)) == body

    {:ok, %{healed: n}} = Heal.heal_object("b", "k", "null", o(drives))
    assert n >= 1
    assert File.exists?(part(Enum.at(drives, 0), "b", "k"))
  end

  test "篡改 M 个分片 GET 仍正确（校验和检测+重建）", %{drives: drives} do
    :ok = ErasureCoded.put_bucket("b", o(drives))
    body = :crypto.strong_rand_bytes(5000)
    {:ok, _} = ErasureCoded.put("b", "k", "null", [body], o(drives))

    Enum.each([1, 2], fn i ->
      p = part(Enum.at(drives, i), "b", "k")
      <<first, rest::binary>> = File.read!(p)
      File.write!(p, <<bxor(first, 0xFF), rest::binary>>)
    end)

    {:ok, stream} = ErasureCoded.get("b", "k", "null", nil, o(drives))
    assert IO.iodata_to_binary(Enum.to_list(stream)) == body
  end

  test "删 M+1 个分片 GET raise（结构化错误，绝不静默错数据）", %{drives: drives} do
    :ok = ErasureCoded.put_bucket("b", o(drives))
    body = :crypto.strong_rand_bytes(5000)
    {:ok, _} = ErasureCoded.put("b", "k", "null", [body], o(drives))

    Enum.each([0, 1, 2], fn i -> File.rm_rf!(Path.join([Enum.at(drives, i), "b", "k"])) end)

    assert_raise InsufficientShardsError, fn ->
      {:ok, stream} = ErasureCoded.get("b", "k", "null", nil, o(drives))
      IO.iodata_to_binary(Enum.to_list(stream))
    end
  end
end
