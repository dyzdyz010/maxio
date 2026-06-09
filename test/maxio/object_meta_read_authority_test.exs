defmodule Maxio.ObjectMetaReadAuthorityTest do
  @moduledoc """
  ROUTE B B4-3 —— 翻转读权威（authoritative_source(:read)=:sidecar）。

  覆盖（opts 覆盖 authoritative_source for tests，默认 :pg 不受影响）：
    * read=:sidecar 时 ObjectMeta.get 返回 reconcile 的 sidecar 视图（不依赖 PG）；
    * latest 是 delete_marker 且 version_id==nil -> 返回 delete-marker 视图（is_delete_marker:true +
      version_id），交 handler 发 404 + x-amz-delete-marker:true，**绝不**塌缩成裸 not_found（保真 AWS/MinIO）；
    * 全端点缺该对象 -> {:error, :not_found}；
    * 仅 1/3 端点有（< read_quorum=2）-> {:error, :read_quorum}（绝不猜）；
    * 【B4-3 critical 修复】versioned（Enabled）桶对象版本落 `.versions/<bucket>/<key>/<ULID>/`，
      latest 读（version_id=nil）经版本发现解析当前版本并返回对象（绝不硬编码 null 路径系统性 404）。
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

  # 写 null 布局 sidecar（`<bucket>/<key>/meta.json`，Unversioned 当前版本落点）。
  defp put(eps, key, meta),
    do:
      Enum.each(eps, fn {_n, d} ->
        dir = Path.join([d, "rab", key])
        File.mkdir_p!(dir)
        File.write!(Path.join(dir, "meta.json"), Sidecar.encode(meta))
      end)

  # 写版本树 sidecar（`.versions/<bucket>/<key>/<vid>/meta.json`，Enabled 桶版本真实落点，与 do_put 一致）。
  defp put_versioned(eps, key, vid, meta),
    do:
      Enum.each(eps, fn {_n, d} ->
        dir = Path.join([d, ".versions", "rab", key, vid])
        File.mkdir_p!(dir)
        File.write!(Path.join(dir, "meta.json"), Sidecar.encode(meta))
      end)

  # versioned 版本 entry 的 meta（version_id = ULID，落版本树路径）。
  defp m_v(vid, type \\ "object"),
    do: %{
      "format" => "maxio/2",
      "versions" => [
        %{
          "version_id" => vid,
          "type" => type,
          "modtime" => 5,
          "generation" => 1,
          "etag" => "\"ev\"",
          "size" => 7,
          "content_type" => "text/plain"
        }
      ]
    }

  defp opts(topo),
    do: [transport: InProcess, topology: topo, authoritative_source: [read: :sidecar]]

  test "read=:sidecar 时返回 sidecar 视图（不依赖 PG）", %{eps: eps, topo: topo} do
    # 仅写 sidecar，不写 PG
    put(eps, "k", m("v1"))
    obj = ObjectMeta.get("rab", "k", nil, opts(topo))
    assert obj.etag == "\"e\""
    assert obj.version_id == "v1"
  end

  test "read=:sidecar latest 是 delete_marker -> 返回 delete-marker 视图（含头），绝不塌缩 not_found", %{
    eps: eps,
    topo: topo
  } do
    put(eps, "dk", m("vd", "delete_marker"))
    obj = ObjectMeta.get("rab", "dk", nil, opts(topo))

    # 保真修复：返回 %Object{is_delete_marker: true, version_id: "vd"}，交 handler 发 404 +
    # x-amz-delete-marker:true + x-amz-version-id（与 :pg 路径同构），绝不丢删除标记头。
    assert %Maxio.Objects.Object{} = obj
    assert obj.is_delete_marker == true
    assert obj.version_id == "vd"
  end

  test "read=:sidecar versioned(Enabled)桶 latest GET 解析当前版本（.versions/<ULID> 路径，绝不 404）",
       %{eps: eps, topo: topo} do
    # do_put 对 Enabled 桶把版本写 `.versions/rab/vk/<ULID>/meta.json`（绝不写 null 路径）。
    # 修复前 sidecar_read 硬编码读 null 路径 -> 空 -> all-missing -> not_found（critical 误 404）。
    vid = "01HZZZVERSIONEDULID0001"
    put_versioned(eps, "vk", vid, m_v(vid))
    obj = ObjectMeta.get("rab", "vk", nil, opts(topo))
    assert %Maxio.Objects.Object{} = obj
    assert obj.version_id == vid
    assert obj.etag == "\"ev\""
    assert obj.size == 7
  end

  test "read=:sidecar versioned 桶 latest 当前版本是 delete_marker -> 返回 DM 视图（含 ULID version_id）",
       %{eps: eps, topo: topo} do
    vid = "01HZZZVERSIONEDDM00000001"
    put_versioned(eps, "vdk", vid, m_v(vid, "delete_marker"))
    obj = ObjectMeta.get("rab", "vdk", nil, opts(topo))
    assert %Maxio.Objects.Object{} = obj
    assert obj.is_delete_marker == true
    assert obj.version_id == vid
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
