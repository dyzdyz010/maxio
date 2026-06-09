defmodule Maxio.ObjectMetaReadAuthorityTest do
  @moduledoc """
  ROUTE B B4-3 —— 翻转读权威（authoritative_source(:read)=:sidecar）。

  覆盖（opts 覆盖 authoritative_source for tests，默认 :pg 不受影响）：
    * read=:sidecar 时 ObjectMeta.get 返回 reconcile 的 sidecar 视图（不依赖 PG）；
    * latest 是 delete_marker 且 version_id==nil -> {:error, :not_found}（GET 应 404）；
    * 全端点缺该对象 -> {:error, :not_found}；
    * 仅 1/3 端点有（< read_quorum=2）-> {:error, :read_quorum}（绝不猜）。
  """
  use Maxio.DataCase, async: false
  alias Maxio.{ObjectMeta, Sidecar}
  alias Maxio.Cluster.Transport.InProcess

  setup do
    InProcess.setup!()

    eps =
      for i <- 0..2,
          do:
            {:"ran#{i}",
             Path.join(System.tmp_dir!(), "ra_d#{i}_#{System.unique_integer([:positive])}")}

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

  defp m(vid, type \\ "object"),
    do: %{
      "format" => "maxio/2",
      "versions" => [
        %{
          "version_id" => vid,
          "type" => type,
          "modtime" => 5,
          "generation" => 1,
          "etag" => "\"e\"",
          "size" => 3,
          "content_type" => "text/plain"
        }
      ]
    }

  defp put(eps, key, meta),
    do:
      Enum.each(eps, fn {_n, d} ->
        dir = Path.join([d, "rab", key])
        File.mkdir_p!(dir)
        File.write!(Path.join(dir, "meta.json"), Sidecar.encode(meta))
      end)

  defp opts(topo),
    do: [transport: InProcess, topology: topo, authoritative_source: [read: :sidecar]]

  test "read=:sidecar 时返回 sidecar 视图（不依赖 PG）", %{eps: eps, topo: topo} do
    # 仅写 sidecar，不写 PG
    put(eps, "k", m("v1"))
    obj = ObjectMeta.get("rab", "k", nil, opts(topo))
    assert obj.etag == "\"e\""
    assert obj.version_id == "v1"
  end

  test "read=:sidecar latest 是 delete_marker -> not_found", %{eps: eps, topo: topo} do
    put(eps, "dk", m("vd", "delete_marker"))
    assert {:error, :not_found} = ObjectMeta.get("rab", "dk", nil, opts(topo))
  end

  test "read=:sidecar 全端点缺该对象 -> not_found", %{topo: topo} do
    assert {:error, :not_found} = ObjectMeta.get("rab", "ghost", nil, opts(topo))
  end

  test "read=:sidecar 仅 1/3 端点有（< read_quorum=2）-> read_quorum 错误（绝不猜）", %{
    eps: eps,
    topo: topo
  } do
    [{_n0, d0} | _] = eps
    dir = Path.join([d0, "rab", "lonely"])
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "meta.json"), Sidecar.encode(m("v1")))
    assert {:error, :read_quorum} = ObjectMeta.get("rab", "lonely", nil, opts(topo))
  end
end
