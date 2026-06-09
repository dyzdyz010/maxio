defmodule Maxio.ObjectMetaListAuthorityTest do
  @moduledoc """
  ROUTE B B4-4 —— 翻转列权威（authoritative_source(:list)=:sidecar）。

  覆盖（opts 覆盖 authoritative_source for tests，默认 :pg 不受影响）：
    * list=:sidecar 时 ObjectMeta.list 返回 drive-walk 结果（强制每 key quorum 确认）；
    * 仅 1/3 端点有的 key（< read_quorum=2）不计入（去掉 P3 shadow 命中≥1 即收的宽松门）。
  """
  use Maxio.DataCase, async: false
  alias Maxio.ObjectMeta
  alias Maxio.Cluster.Transport.InProcess

  setup do
    InProcess.setup!()

    eps =
      for i <- 0..2,
          do:
            {:"lan#{i}",
             Path.join(System.tmp_dir!(), "la_d#{i}_#{System.unique_integer([:positive])}")}

    topo = %{
      data_shards: 2,
      parity_shards: 1,
      block_size: 1024,
      sets: %{0 => %{id: 0, endpoints: eps}},
      set_ids: [0]
    }

    :persistent_term.put({Maxio.Cluster.Topology, :topology}, topo)

    on_exit(fn ->
      :persistent_term.erase({Maxio.Cluster.Topology, :topology})
      Enum.each(eps, fn {_n, d} -> File.rm_rf(d) end)
    end)

    {:ok, eps: eps, topo: topo}
  end

  defp put(eps, key),
    do:
      Enum.each(eps, fn {_n, d} ->
        dir = Path.join([d, "lab", key])
        File.mkdir_p!(dir)
        File.write!(Path.join(dir, "meta.json"), "{}")
      end)

  defp opts(topo),
    do: [transport: InProcess, topology: topo, authoritative_source: [list: :sidecar]]

  test "list=:sidecar 返回 drive-walk 结果（quorum 确认）", %{eps: eps, topo: topo} do
    put(eps, "a")
    put(eps, "b")
    r = ObjectMeta.list("lab", %{max_keys: 100}, opts(topo))
    assert Enum.map(r.objects, & &1.key) == ["a", "b"]
  end

  test "list=:sidecar 仅 1/3 端点有的 key 不计入（< quorum）", %{eps: eps, topo: topo} do
    put(eps, "full")
    [{_n0, d0} | _] = eps
    dir = Path.join([d0, "lab", "lonely"])
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "meta.json"), "{}")
    r = ObjectMeta.list("lab", %{max_keys: 100}, opts(topo))
    # lonely 仅 1/3 端点（< read_quorum=2）-> 被排除
    assert Enum.map(r.objects, & &1.key) == ["full"]
  end
end
