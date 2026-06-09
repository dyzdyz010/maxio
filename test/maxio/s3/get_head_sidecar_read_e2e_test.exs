defmodule Maxio.S3.GetHeadSidecarReadE2ETest do
  @moduledoc """
  保真回归（铁律 3 / S3 兼容）—— 在 **read 权威 = :sidecar** 下，GET/HEAD 的两类保真修复整链取证：

    (1) latest 当前版本是 delete marker → 404 携带 `x-amz-delete-marker: true`（+ ULID version_id），
        绝不返回裸 NoSuchKey（AWS S3：「current 版本为 delete marker 时返回 404 + x-amz-delete-marker:true」，
        MinIO 镜像之；versioning-aware 客户端据此区分「被删除标记遮蔽」与「从未存在」）。修复前
        sidecar 读路径把 latest delete marker 塌缩成 {:error,:not_found} → 裸 404，丢删除标记头。

    (2) sidecar reconcile 不足 read_quorum → 503 **SlowDownRead**（对齐 MinIO errErasureReadQuorum
        -> ErrSlowDownRead），绝不 ServiceUnavailable（MinIO 从不产此 Code）。本测试断言**渲染出的
        XML Code**（不只内部元组），锁死 handler 映射。

  经完整 SigV4 → Endpoint → handler 链取证（端到端活体）。
  """
  use Maxio.DataCase, async: false
  import Plug.Conn
  alias Maxio.Test.SigV4Request
  alias Maxio.S3.Endpoint
  alias Maxio.Cluster.{ShardServer, Paths}
  alias Maxio.Cluster.Transport.InProcess

  @data_dir Path.join(System.tmp_dir!(), "maxio_get_head_sidecar")

  setup do
    InProcess.setup!()

    File.rm_rf(@data_dir)
    File.mkdir_p!(@data_dir)
    prev_s3 = Application.get_env(:maxio, :s3)
    Application.put_env(:maxio, :s3, Keyword.put(prev_s3, :data_dir, @data_dir))

    prev_auth = Application.get_env(:maxio, :authoritative_source)
    Application.put_env(:maxio, :authoritative_source, read: :sidecar, list: :pg, write: :pg)
    prev_tx = Application.get_env(:maxio, :shard_transport)
    Application.put_env(:maxio, :shard_transport, InProcess)

    # handler 经 ObjectMeta.get 不传 topology -> read_quorum 取自全局 :erasure 配置。
    # 须带 drives（Config.load! 校验 length(drives)==K+M，否则 rescue 回落 quorum=1，read_quorum
    # 测试永不触发）；drives 仅用于 quorum 计算（read_quorum=K=2），不实际写盘（字节走 InProcess 端点）。
    prev_ec = Application.get_env(:maxio, :erasure)

    Application.put_env(:maxio, :erasure,
      drives: ["d0", "d1", "d2"],
      data_shards: 2,
      parity_shards: 1,
      block_size: 1024
    )

    eps =
      for i <- 0..2,
          do:
            {:"ghn#{i}",
             Path.join(System.tmp_dir!(), "gh_d#{i}_#{System.unique_integer([:positive])}")}

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

  # 在所有端点为 bucket/key 的某版本写 sidecar（version_id 决定盘上落点：null 路径或 .versions/<vid>）。
  defp put_sidecar_all(eps, bucket, key, vid, meta) do
    {:ok, rel} = Paths.object_rel(bucket, key, vid)
    Enum.each(eps, fn {_n, drive} -> ShardServer.put_sidecar(Path.join(drive, rel), meta) end)
  end

  defp dm_meta(vid),
    do: %{
      "format" => "maxio/2",
      "versions" => [
        %{
          "version_id" => vid,
          "type" => "delete_marker",
          "is_latest" => true,
          "modtime" => 1_700_000_000_000_000_000,
          "generation" => 0
        }
      ]
    }

  test "read=:sidecar 当前版本为 delete marker -> GET 404 携 x-amz-delete-marker:true + version-id",
       %{eps: eps} do
    bucket = "ghdmb"
    key = "gone.txt"
    vid = "01HZZZGHDMVERSION0000001"
    # versioned 桶版本树落点（与 do_put Enabled 一致）。
    put_sidecar_all(eps, bucket, key, vid, dm_meta(vid))
    SigV4Request.signed_conn(:put, "/" <> bucket) |> call()

    res = SigV4Request.signed_conn(:get, "/#{bucket}/#{key}") |> call()

    assert res.status == 404
    assert get_resp_header(res, "x-amz-delete-marker") == ["true"]
    assert get_resp_header(res, "x-amz-version-id") == [vid]
  end

  test "read=:sidecar 当前版本为 delete marker -> HEAD 404 携 x-amz-delete-marker:true + version-id",
       %{eps: eps} do
    bucket = "ghdmhb"
    key = "gone2.txt"
    vid = "01HZZZGHDMHEAD0000000001"
    put_sidecar_all(eps, bucket, key, vid, dm_meta(vid))
    SigV4Request.signed_conn(:put, "/" <> bucket) |> call()

    res = SigV4Request.signed_conn(:head, "/#{bucket}/#{key}") |> call()

    assert res.status == 404
    assert get_resp_header(res, "x-amz-delete-marker") == ["true"]
    assert get_resp_header(res, "x-amz-version-id") == [vid]
  end

  test "read=:sidecar reconcile 不足 read_quorum -> GET 503 + <Code>SlowDownRead</Code>（非 ServiceUnavailable）",
       %{eps: eps} do
    bucket = "ghsdr"
    key = "lonely.txt"

    obj_meta = %{
      "format" => "maxio/2",
      "versions" => [
        %{
          "version_id" => "null",
          "type" => "object",
          "is_latest" => true,
          "modtime" => 5,
          "generation" => 0,
          "etag" => "\"e\"",
          "size" => 3,
          "content_type" => "text/plain"
        }
      ]
    }

    # 仅 1/3 端点写 sidecar（< read_quorum=2）-> reconcile {:error,:read_quorum}（绝不猜副本）。
    [{_n0, d0} | _] = eps
    {:ok, rel} = Paths.object_rel(bucket, key, "null")
    ShardServer.put_sidecar(Path.join(d0, rel), obj_meta)

    SigV4Request.signed_conn(:put, "/" <> bucket) |> call()

    res = SigV4Request.signed_conn(:get, "/#{bucket}/#{key}") |> call()

    assert res.status == 503
    assert res.resp_body =~ "<Code>SlowDownRead</Code>"
    refute res.resp_body =~ "ServiceUnavailable"
  end
end
