defmodule Maxio.S3.ListObjectsV2SidecarE2ETest do
  @moduledoc """
  Review must-fix 回归（铁律 3 / S3 正确性）—— ListObjectsV2 在 **list 权威 = :sidecar** 下
  对非空桶整链不崩、产出合法 XML。

  根因：:list=:sidecar 分支（drive-walk）曾只产 `%{key: ...}`（无 LastModified/ETag/Size）；
  handler 映射成 `%{last_modified: nil, etag: nil, size: nil}`，views/list_bucket.ex 对其调
  `XML.iso8601(nil)`（FunctionClauseError）/ `XML.quote_etag(nil)`（ArgumentError）/
  `Integer.to_string(nil)`（ArgumentError）→ 500。

  架构级修复：drive-walk 列举源在读当前版本 sidecar（判 delete marker 时已读）的同一份 meta 上
  富集 LastModified/ETag/Size（B4 翻 list 权威）；XML view 再对缺失字段做 S3-valid 兜底（双保险）。

  本测试经完整 SigV4 → Endpoint → handler 链发 ListObjectsV2，覆盖：
    (1) sidecar 携带富元数据 -> XML 含真实 Size/ETag/LastModified；
    (2) sidecar 缺富字段 -> XML 仍合法（Size=0、ETag 空引号、LastModified 兜底当前时刻），绝不 500。
  """
  use Maxio.DataCase, async: false
  alias Maxio.Test.SigV4Request
  alias Maxio.S3.Endpoint
  alias Maxio.Cluster.{ShardServer, Paths}
  alias Maxio.Cluster.Transport.InProcess

  @data_dir Path.join(System.tmp_dir!(), "maxio_list_sidecar")

  setup do
    InProcess.setup!()

    File.rm_rf(@data_dir)
    File.mkdir_p!(@data_dir)
    prev_s3 = Application.get_env(:maxio, :s3)
    Application.put_env(:maxio, :s3, Keyword.put(prev_s3, :data_dir, @data_dir))

    prev_auth = Application.get_env(:maxio, :authoritative_source)
    Application.put_env(:maxio, :authoritative_source, read: :pg, list: :sidecar, write: :pg)
    prev_tx = Application.get_env(:maxio, :shard_transport)
    Application.put_env(:maxio, :shard_transport, InProcess)

    # handler 经 ObjectMeta.list 不传 topology -> drive-walk read_quorum 取自全局 :erasure 配置；
    # 对齐本测试 N=3（K=2 M=1）拓扑，覆盖全局 :erasure 为 K=2 使 quorum=2（3 副本可达）。
    prev_ec = Application.get_env(:maxio, :erasure)
    Application.put_env(:maxio, :erasure, data_shards: 2, parity_shards: 1, block_size: 1024)

    eps =
      for i <- 0..2,
          do:
            {:"lsen#{i}",
             Path.join(System.tmp_dir!(), "lse_d#{i}_#{System.unique_integer([:positive])}")}

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
      Application.put_env(:maxio, :s3, prev_s3)

      if prev_auth,
        do: Application.put_env(:maxio, :authoritative_source, prev_auth),
        else: Application.delete_env(:maxio, :authoritative_source)

      if prev_tx,
        do: Application.put_env(:maxio, :shard_transport, prev_tx),
        else: Application.delete_env(:maxio, :shard_transport)

      if prev_ec,
        do: Application.put_env(:maxio, :erasure, prev_ec),
        else: Application.delete_env(:maxio, :erasure)

      Enum.each(eps, fn {_n, d} -> File.rm_rf(d) end)
      File.rm_rf(@data_dir)
    end)

    {:ok, eps: eps}
  end

  defp call(conn), do: Endpoint.call(conn, Endpoint.init([]))

  # 在所有端点为 bucket/key 写 null 版本 sidecar（meta 由调用方给，模拟富/贫元数据两种形态）。
  defp put_sidecar_all(eps, bucket, key, meta) do
    {:ok, rel} = Paths.object_rel(bucket, key, "null")
    Enum.each(eps, fn {_n, drive} -> ShardServer.put_sidecar(Path.join(drive, rel), meta) end)
  end

  test "list=:sidecar 非空桶 ListObjectsV2 不崩、富元数据渲染进 XML", %{eps: eps} do
    bucket = "lseb"
    SigV4Request.signed_conn(:put, "/" <> bucket) |> call()

    rich = %{
      "format" => "maxio/2",
      "versions" => [
        %{
          "version_id" => "null",
          "type" => "object",
          "is_latest" => true,
          "modtime" => 1_700_000_000_000_000_000,
          "generation" => 0,
          "etag" => "\"abc123\"",
          "size" => 42,
          "content_type" => "text/plain"
        }
      ]
    }

    put_sidecar_all(eps, bucket, "a.txt", rich)

    res = SigV4Request.signed_conn(:get, "/" <> bucket) |> call()

    # 修复前：handler 拿 nil 字段 -> XML view 渲染崩 500。修复后：200 + 合法 XML + 真实富字段。
    assert res.status == 200
    assert res.resp_body =~ "<Key>a.txt</Key>"
    assert res.resp_body =~ "<Size>42</Size>"
    assert res.resp_body =~ "<ETag>\"abc123\"</ETag>"
    assert res.resp_body =~ "<LastModified>2023-11-14T"
  end

  test "list=:sidecar sidecar 缺富字段也产合法 XML（S3-valid 兜底，绝不 500）", %{eps: eps} do
    bucket = "lseb2"
    SigV4Request.signed_conn(:put, "/" <> bucket) |> call()

    # 贫元数据 sidecar（仅 is_delete_marker，无 size/etag/modtime）——drive-walk 历史可见的盘上形态。
    put_sidecar_all(eps, bucket, "b.txt", %{"is_delete_marker" => false})

    res = SigV4Request.signed_conn(:get, "/" <> bucket) |> call()

    assert res.status == 200
    assert res.resp_body =~ "<Key>b.txt</Key>"

    # 兜底：Size=0、ETag 空引号、LastModified 合法 ISO8601（当前时刻），XML 不崩。
    assert res.resp_body =~ "<Size>0</Size>"
    assert res.resp_body =~ "<ETag>\"\"</ETag>"
    assert res.resp_body =~ ~r/<LastModified>\d{4}-\d{2}-\d{2}T/
  end
end
