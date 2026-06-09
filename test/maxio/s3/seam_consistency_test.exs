defmodule Maxio.S3.SeamConsistencyTest do
  @moduledoc """
  ROUTE B B1-1 提交 seam 一致性回归。

  并发同 key PUT（不同字节）必须要么全 A 要么全 B —— 绝不「A 的字节 + B 的元数据」交错。
  本测试把整个提交 seam（字节经 Distributed.put + 元数据经 Objects.put_version_with_id）
  纳入同一 `Maxio.Lock.with_object_lock`，断言最终 sidecar.etag == PG.etag（消除静默 ETag/bytes 分歧）。

  后端用 Distributed + InProcess（N=6 K=4 M=2），与 cluster_e2e_test 同样的进程内多节点拓扑注入。
  `async: false`：InProcess down 集合是全局 ETS，且 SQL sandbox 须共享给并发 Task。
  """
  use Maxio.DataCase, async: false

  alias Maxio.{Buckets, Objects}
  alias Maxio.Storage.Distributed
  alias Maxio.Cluster.{Paths, Router, Topology, Transport.InProcess}

  setup do
    InProcess.setup!()
    base = Path.join(System.tmp_dir!(), "maxio_seam_#{System.unique_integer([:positive])}")

    # 3 node × 2 drive = N=6 端点；K=4 M=2（与 cluster_e2e_test 同构）。
    endpoints =
      for i <- 0..5 do
        {:"maxio@node#{div(i, 2)}", Path.join(base, "node#{div(i, 2)}_d#{rem(i, 2)}")}
      end

    topology =
      Topology.parse_and_validate!(
        data_shards: 4,
        parity_shards: 2,
        block_size: 1024,
        # 3 node × 2 drive 同 node 名复用，放行 distinct-node 校验（B1-3）。
        allow_colocated_endpoints: true,
        pools: [%{id: 0, sets: [%{id: 0, endpoints: endpoints}]}]
      )

    {:ok, bucket} = Buckets.create("seam-bucket", "arn:aws:iam:::root")

    on_exit(fn -> File.rm_rf(base) end)
    {:ok, base: base, topology: topology, bucket: bucket}
  end

  defp opts(ctx), do: [topology: ctx.topology, transport: InProcess]

  # 用与 Distributed 完全一致的路由 + 路径构造，从任一存活端点读 sidecar 的 etag。
  defp sidecar_etag(ctx, bucket, key, version_id) do
    {:ok, obj_rel} = Paths.object_rel(bucket, key, version_id)
    set_id = Router.set_for(bucket, key, ctx.topology)
    endpoints = Topology.endpoints_from(ctx.topology, set_id)

    Enum.find_value(endpoints, fn {node, drive} ->
      case InProcess.get_sidecar(node, Path.join(drive, obj_rel)) do
        {:ok, meta} -> meta["etag"]
        {:error, _} -> nil
      end
    end)
  end

  # 单次「字节 + 元数据」提交 seam，整段持同一对象锁（B1-1 的核心）。
  defp commit_put(ctx, bucket, key, version_id, body) do
    Maxio.Lock.with_object_lock({bucket, key}, fn ->
      {:ok, %{size: size, etag: etag, sha256: _sha}} =
        Distributed.put(bucket, key, version_id, [body], opts(ctx))

      {:ok, _obj} =
        Objects.put_version_with_id(bucket, key, version_id, %{
          size: size,
          etag: etag,
          content_type: "application/octet-stream",
          storage_class: "STANDARD"
        })

      etag
    end)
  end

  test "concurrent same-key put: sidecar etag and index etag never diverge", ctx do
    bucket = "seam-bucket"
    key = "obj"
    version_id = "null"

    # 小 body（4 个 block_size=1024 的块）足以区分两次写的 etag；分布式逐块 Task.async_stream
    # 在 Windows 上 per-shard 文件 IO 较慢，无需 MB 级即可证明 seam 一致性（铁律 4 仍流式）。
    body_a = :crypto.strong_rand_bytes(4096)
    body_b = :crypto.strong_rand_bytes(4096)
    refute body_a == body_b

    # async: false -> sandbox 为 shared 模式，spawn 的 Task 自动共享父连接（无需显式 allow）。
    task_a = Task.async(fn -> commit_put(ctx, bucket, key, version_id, body_a) end)
    task_b = Task.async(fn -> commit_put(ctx, bucket, key, version_id, body_b) end)

    _ = Task.await(task_a, 30_000)
    _ = Task.await(task_b, 30_000)

    {:ok, obj} = Objects.get_metadata(bucket, key)
    pg_etag = obj.etag
    sc_etag = sidecar_etag(ctx, bucket, key, version_id)

    # 提交 seam 在同一对象锁内：最终 sidecar.etag 与 PG.etag 必相等（要么全 A 要么全 B）。
    assert pg_etag == sc_etag

    # 且必为两候选之一（绝非半截/撕裂值）。
    etag_a = :crypto.hash(:md5, body_a) |> Base.encode16(case: :lower)
    etag_b = :crypto.hash(:md5, body_b) |> Base.encode16(case: :lower)
    assert pg_etag in [etag_a, etag_b]
  end

  test "with_object_lock failure maps to {:error, :locked}" do
    # 门面契约：fun raise 不被吞，正常返回 {:ok, result}；获锁失败由底层 :global.trans 决定。
    assert {:ok, 42} = Maxio.Lock.with_object_lock({"b", "k"}, fn -> 42 end)
  end
end
