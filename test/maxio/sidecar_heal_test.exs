defmodule Maxio.SidecarHealTest do
  use ExUnit.Case, async: false
  alias Maxio.{SidecarHeal, Sidecar}
  alias Maxio.Cluster.Transport.InProcess

  setup do
    InProcess.setup!()

    eps =
      for i <- 0..2,
          do:
            {:"shn#{i}",
             Path.join(System.tmp_dir!(), "sh_d#{i}_#{System.unique_integer([:positive])}")}

    on_exit(fn -> Enum.each(eps, fn {_n, d} -> File.rm_rf(d) end) end)
    {:ok, eps: eps}
  end

  defp meta(vid),
    do: %{
      "format" => "maxio/2",
      "versions" => [
        %{
          "version_id" => vid,
          "type" => "object",
          "modtime" => 5,
          "generation" => 1,
          "etag" => "\"e\"",
          "size" => 3
        }
      ]
    }

  # 在端点写对象目录（含 sidecar）
  defp put_sidecar(drive, bucket, key, m) do
    dir = Path.join([drive, bucket, key])
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "meta.json"), Sidecar.encode(m))
  end

  test "heal_divergent 把权威 sidecar 写回缺失/陈旧端点", %{eps: eps} do
    canon = meta("v1")
    # 端点 0/1 有权威；端点 2 缺失（divergent）
    [{_n0, d0}, {_n1, d1}, {_n2, d2}] = eps
    put_sidecar(d0, "b", "k", canon)
    put_sidecar(d1, "b", "k", canon)
    refute File.exists?(Path.join([d2, "b", "k", "meta.json"]))

    info = %{canonical_meta: canon, divergent_endpoints: [2], endpoints: eps}
    n = SidecarHeal.heal_divergent("b", "k", "null", info, transport: InProcess)
    assert n == 1
    assert File.exists?(Path.join([d2, "b", "k", "meta.json"]))
    {:ok, healed} = InProcess.get_sidecar(:shn2, Path.join([d2, "b", "k"]))
    assert healed == canon
  end

  test "单端点 heal 失败不抛、返回成功计数", %{eps: eps} do
    canon = meta("v1")
    # 端点 2 不可达
    InProcess.set_down(:shn2)
    info = %{canonical_meta: canon, divergent_endpoints: [2], endpoints: eps}
    assert 0 = SidecarHeal.heal_divergent("b", "k", "null", info, transport: InProcess)
    InProcess.set_up(:shn2)
  end

  test "多 divergent 端点全部回写、返回成功计数", %{eps: eps} do
    canon = meta("v1")
    [{_n0, d0}, {_n1, d1}, {_n2, d2}] = eps
    put_sidecar(d0, "b", "k", canon)
    refute File.exists?(Path.join([d1, "b", "k", "meta.json"]))
    refute File.exists?(Path.join([d2, "b", "k", "meta.json"]))

    info = %{canonical_meta: canon, divergent_endpoints: [1, 2], endpoints: eps}
    n = SidecarHeal.heal_divergent("b", "k", "null", info, transport: InProcess)
    assert n == 2
    {:ok, h1} = InProcess.get_sidecar(:shn1, Path.join([d1, "b", "k"]))
    {:ok, h2} = InProcess.get_sidecar(:shn2, Path.join([d2, "b", "k"]))
    assert h1 == canon
    assert h2 == canon
  end

  test "版本对象（非 null）回写到 .versions 路径", %{eps: eps} do
    canon = meta("vX")
    [_e0, _e1, {_n2, d2}] = eps
    info = %{canonical_meta: canon, divergent_endpoints: [2], endpoints: eps}
    n = SidecarHeal.heal_divergent("b", "k", "vX", info, transport: InProcess)
    assert n == 1
    healed_dir = Path.join([d2, ".versions", "b", "k", "vX"])
    assert File.exists?(Path.join(healed_dir, "meta.json"))
    {:ok, healed} = InProcess.get_sidecar(:shn2, healed_dir)
    assert healed == canon
  end
end
