defmodule Maxio.S3.ListEmptyParamsAuthorityBranchesTest do
  @moduledoc """
  空 delimiter / 空游标的归一化（`Maxio.S3.ListQuery`）在**三条列举权威分支**上都必须生效。

  ## 为什么单开这个文件

  `list_empty_delimiter_test.exs` / `list_empty_cursor_test.exs` 已覆盖归一化，但它们跑在 test env
  的默认配置下——`config :maxio, :authoritative_source, list: :pg` 且**没有配置
  `Maxio.Cluster.Topology`**。后果是：

    * `:list=:sidecar`（drive-walk 翻列举权威）分支从未被走到；
    * `:pg` 分支里的 drive-walk shadow 每次都在 `Maxio.ObjectMeta.list_shadow/3` 里因取不到拓扑
      而抛异常，被那里的 `rescue` 自吞成一条 `[warning] list shadow error ... 未配置`，**比对逻辑
      一行都没执行**。

  也就是说「列举归一化对三条权威分支都生效」此前只有 PG 分支有执行级证据。本文件把另外两条
  分支真正跑起来（注入 InProcess transport + 显式拓扑），并给出**该分支独有**的执行证据：

    * `:sidecar` 分支 —— 对象只存在于盘上 sidecar，PG 里**一行都没有**；能列出这些 key 的
      唯一可能就是 drive-walk 权威分支确实执行了（同一断言里对 PG 权威直接取证为空）。
    * drive-walk shadow —— 断言只有「drive-walk 真的走完并与 PG 逐项比对」才可能产生的
      `list divergence: PG vs drive-walk` 日志，同时断言**没有** `list shadow error`
      （后者正是分支被自吞时的形态）。

  ## 归一化在这两条分支上的实际保护面

    * 空 delimiter：`Maxio.Listing.common_prefix/3` 与 PG 侧同构，`""` 会走到
      `:binary.match(rest, "")` → `ArgumentError`。在 `:sidecar` 分支上这是 500；在 shadow 分支上
      会被自吞成 `list shadow error`（分歧检测静默失效）。
    * 空游标：`Maxio.Listing.continuation_cursor/1` 与 PG 的 `||` 取值同构——
      `Continuation.decode("") == {:ok, ""}`，游标 `""` 会让 `apply_cursor` 的
      `&1 > ""` 恒真，从而**遮蔽**非空 `start-after`，静默返回全量。
  """
  use Maxio.DataCase, async: false

  import ExUnit.CaptureLog

  alias Maxio.Cluster.{Paths, ShardServer}
  alias Maxio.Cluster.Transport.InProcess
  alias Maxio.Objects
  alias Maxio.S3.Endpoint
  alias Maxio.Test.SigV4Request

  # 盘上富元数据 sidecar：Size/ETag/LastModified 只存在于盘上，PG 无对应行。
  @sidecar_size 42
  @sidecar_etag "\"branchproof\""

  setup do
    data_dir =
      Path.join(System.tmp_dir!(), "maxio_list_branches_#{System.unique_integer([:positive])}")

    File.rm_rf(data_dir)
    File.mkdir_p!(data_dir)

    InProcess.setup!()

    prev_s3 = Application.get_env(:maxio, :s3)
    Application.put_env(:maxio, :s3, Keyword.put(prev_s3, :data_dir, data_dir))

    prev_tx = Application.get_env(:maxio, :shard_transport)
    Application.put_env(:maxio, :shard_transport, InProcess)

    # drive-walk 的 read_quorum 取自全局 :erasure（handler 不传 topology 时同源）——
    # 对齐本测试 N=3（K=2 M=1），quorum=2，三副本可达。
    prev_ec = Application.get_env(:maxio, :erasure)
    Application.put_env(:maxio, :erasure, data_shards: 2, parity_shards: 1, block_size: 1024)

    eps =
      for i <- 0..2,
          do:
            {:"lpab#{i}",
             Path.join(System.tmp_dir!(), "lpab_d#{i}_#{System.unique_integer([:positive])}")}

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

      if prev_tx,
        do: Application.put_env(:maxio, :shard_transport, prev_tx),
        else: Application.delete_env(:maxio, :shard_transport)

      if prev_ec,
        do: Application.put_env(:maxio, :erasure, prev_ec),
        else: Application.delete_env(:maxio, :erasure)

      Enum.each(eps, fn {_n, d} -> File.rm_rf(d) end)
      File.rm_rf(data_dir)
    end)

    {:ok, eps: eps}
  end

  defp call(conn), do: Endpoint.call(conn, Endpoint.init([]))

  defp create_bucket!(bucket) do
    res = SigV4Request.signed_conn(:put, "/" <> bucket) |> call()
    assert res.status in [200, 409]
    :ok
  end

  # 在全部端点写该 key 的 null 版本 sidecar（drive-walk 的唯一数据源）。
  defp put_sidecar_all(eps, bucket, key, meta) do
    {:ok, rel} = Paths.object_rel(bucket, key, "null")
    Enum.each(eps, fn {_n, drive} -> ShardServer.put_sidecar(Path.join(drive, rel), meta) end)
    :ok
  end

  defp rich_meta do
    %{
      "format" => "maxio/2",
      "versions" => [
        %{
          "version_id" => "null",
          "type" => "object",
          "is_latest" => true,
          "modtime" => 1_700_000_000_000_000_000,
          "generation" => 0,
          "etag" => @sidecar_etag,
          "size" => @sidecar_size,
          "content_type" => "text/plain"
        }
      ]
    }
  end

  # 字典序：dir/a.txt < dir/sub/b.txt < top.txt
  @tree ~w(dir/a.txt dir/sub/b.txt top.txt)

  defp get_list(bucket, query), do: SigV4Request.signed_conn(:get, "/" <> bucket, query: query)

  describe "list 权威 = :sidecar（drive-walk 翻权威，PG 完全不参与）" do
    setup do
      prev_auth = Application.get_env(:maxio, :authoritative_source)
      Application.put_env(:maxio, :authoritative_source, read: :pg, list: :sidecar, write: :pg)

      on_exit(fn ->
        if prev_auth,
          do: Application.put_env(:maxio, :authoritative_source, prev_auth),
          else: Application.delete_env(:maxio, :authoritative_source)
      end)

      :ok
    end

    # 只写盘、绝不写 PG 对象行：PG 权威在这个桶上恒为空，是本分支的执行级证据。
    defp seed_sidecar_only!(eps, bucket) do
      create_bucket!(bucket)
      Enum.each(@tree, &put_sidecar_all(eps, bucket, &1, rich_meta()))

      # 反证前提：PG 权威一行都没有——下面任何被列出来的 key 都只可能来自 drive-walk。
      assert Objects.list_objects_v2(bucket, %{max_keys: 1000}).objects == []
      :ok
    end

    test "空 delimiter 在 drive-walk 权威分支上等价于无 delimiter（递归平铺，绝不 500）", %{eps: eps} do
      bucket = "lpab-sc-delim"
      seed_sidecar_only!(eps, bucket)

      res = get_list(bucket, %{"list-type" => "2", "delimiter" => ""}) |> call()

      # 归一化失效时：`:binary.match(rest, "")` → ArgumentError → 500。
      assert res.status == 200

      for key <- @tree, do: assert(res.resp_body =~ "<Key>#{key}</Key>")
      assert res.resp_body =~ "<KeyCount>3</KeyCount>"
      refute res.resp_body =~ "<CommonPrefixes>"
      refute res.resp_body =~ "<Delimiter>"

      # 分支执行证据：这些字段只存在于盘上 sidecar（PG 侧一行都没有，见 seed 断言）。
      assert res.resp_body =~ "<Size>#{@sidecar_size}</Size>"
      assert res.resp_body =~ "<ETag>#{@sidecar_etag}</ETag>"
      assert res.resp_body =~ "<LastModified>2023-11-14T"
    end

    test "drive-walk 权威分支上 delimiter=/ 仍正常折叠（回归：只动空串）", %{eps: eps} do
      bucket = "lpab-sc-slash"
      seed_sidecar_only!(eps, bucket)

      res = get_list(bucket, %{"list-type" => "2", "delimiter" => "/"}) |> call()

      assert res.status == 200
      assert res.resp_body =~ "<Key>top.txt</Key>"
      assert res.resp_body =~ "<CommonPrefixes><Prefix>dir/</Prefix></CommonPrefixes>"
      refute res.resp_body =~ "<Key>dir/a.txt</Key>"
      assert res.resp_body =~ "<Delimiter>/</Delimiter>"
    end

    test "空 continuation-token 在 drive-walk 权威分支上不得遮蔽非空 start-after", %{eps: eps} do
      bucket = "lpab-sc-cursor"
      seed_sidecar_only!(eps, bucket)

      res =
        get_list(bucket, %{
          "list-type" => "2",
          "continuation-token" => "",
          "start-after" => "dir/a.txt"
        })
        |> call()

      assert res.status == 200

      # 归一化失效时：Continuation.decode("") == {:ok, ""} → 游标 "" → `&1 > ""` 恒真 →
      # start-after 被遮蔽 → 三条全返回。
      refute res.resp_body =~ "<Key>dir/a.txt</Key>"
      assert res.resp_body =~ "<Key>dir/sub/b.txt</Key>"
      assert res.resp_body =~ "<Key>top.txt</Key>"
      assert res.resp_body =~ "<KeyCount>2</KeyCount>"
    end
  end

  describe "list 权威 = :pg + drive-walk shadow（比对分支必须真的跑起来）" do
    # PG 权威行（经完整 S3 PUT 链）+ 盘上同名 sidecar：两侧一致时 shadow 零分歧。
    defp seed_pg_and_drive!(eps, bucket) do
      create_bucket!(bucket)

      for key <- @tree do
        res = SigV4Request.signed_conn(:put, "/#{bucket}/#{key}", body: key) |> call()
        assert res.status == 200
        put_sidecar_all(eps, bucket, key, rich_meta())
      end

      assert Enum.map(Objects.list_objects_v2(bucket, %{max_keys: 1000}).objects, & &1.key) ==
               @tree

      :ok
    end

    test "空 delimiter：shadow 比对真的执行且零分歧（绝不退化成 list shadow error）", %{eps: eps} do
      bucket = "lpab-shadow-delim"
      seed_pg_and_drive!(eps, bucket)

      query = %{"list-type" => "2", "delimiter" => ""}

      log = capture_log(fn -> assert call(get_list(bucket, query)).status == 200 end)

      # 归一化失效时（已变异取证）本请求整个 500——PG 权威侧先在 `:binary.match(rest, "")` 上崩，
      # 根本走不到 shadow；即便 PG 侧不崩，`""` 也会让 drive-walk 抛 ArgumentError 被
      # `ObjectMeta.list_shadow/3` 自吞成下面这条 warn，比对一行都不会执行。
      refute log =~ "list shadow error"
      refute log =~ "list shadow caught"
      refute log =~ "divergence"

      # ── 分支执行证据（控制组）──
      # 只在盘上多加一个 key：PG 权威不变，唯有「drive-walk 真的走完并与 PG 逐项比对」才可能
      # 产出这条分歧日志。它与上面的零分歧同用一份空 delimiter query。
      put_sidecar_all(eps, bucket, "orphan-on-drive.txt", rich_meta())

      divergence_log =
        capture_log(fn -> assert call(get_list(bucket, query)).status == 200 end)

      assert divergence_log =~ "list divergence: PG vs drive-walk"
      assert divergence_log =~ "orphan-on-drive.txt"
      refute divergence_log =~ "list shadow error"
    end

    test "空 continuation-token：PG 与 shadow 共享同一个归一化后的游标", %{eps: eps} do
      bucket = "lpab-shadow-cursor"
      seed_pg_and_drive!(eps, bucket)

      query = %{
        "list-type" => "2",
        "delimiter" => "",
        "continuation-token" => "",
        "start-after" => "dir/a.txt"
      }

      {res, log} =
        with_log(fn -> call(get_list(bucket, query)) end)

      assert res.status == 200
      refute res.resp_body =~ "<Key>dir/a.txt</Key>"
      assert res.resp_body =~ "<Key>dir/sub/b.txt</Key>"
      assert res.resp_body =~ "<Key>top.txt</Key>"
      assert res.resp_body =~ "<KeyCount>2</KeyCount>"

      # PG 与 drive-walk 由 handler 喂同一份已归一化的 list_opts；游标若在两侧被解释成不同的值
      # （一侧 "dir/a.txt"、另一侧 ""），走盘会多出 dir/a.txt 而报伪分歧。
      refute log =~ "divergence"
      refute log =~ "list shadow error"

      # ── 分支执行证据（控制组）——同一份空游标 query 下，盘上多一个游标之后的 key 必被检出。
      put_sidecar_all(eps, bucket, "zz-orphan.txt", rich_meta())

      divergence_log =
        capture_log(fn -> assert call(get_list(bucket, query)).status == 200 end)

      assert divergence_log =~ "list divergence: PG vs drive-walk"
      assert divergence_log =~ "zz-orphan.txt"
      refute divergence_log =~ "list shadow error"
    end
  end
end
