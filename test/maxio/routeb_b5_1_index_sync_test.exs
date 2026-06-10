defmodule Maxio.RouteBB5_1IndexSyncTest do
  @moduledoc """
  ROUTE B B5-1 —— PG 降为受维护的派生索引：

    * 迁移：objects.synced_at / index_generation 列 + 中文 COMMENT（铁律 6，pg_catalog 取证）。
    * 写路径注入：put_version_with_id / put_metadata / insert_delete_marker 写入时设
      synced_at=now、index_generation（attrs :generation 缺省 0），upsert 替换集含两列。
    * B5-2 命名契约：Objects.mark_synced/4、reconcile_from_sidecar/3、stale?/2。
    * 分流矩阵：CopyObject / MPU complete × :pg/:sidecar 写权威 × PG 成败——
      :pg 默认字节级不变（成功 200 + PG 行；失败致命 500 InternalError）；
      :sidecar 时 PG 降 best-effort（成功 200 + 索引行；失败 Log.error + 请求仍 200）。
      PG 失败经事务内 CHECK 约束注入（确定性，sandbox 回滚，绝不猜）。
    * PREFER 索引读门控：默认关（纯走盘不变）；开（opts/config）→ PG 命中即返回、miss 走盘。
  """
  use Maxio.DataCase, async: false

  import ExUnit.CaptureLog
  import Plug.Conn

  alias Maxio.{Objects, ObjectMeta, Repo, Storage}
  alias Maxio.Cluster.Transport.InProcess
  alias Maxio.S3.Endpoint
  alias Maxio.Test.SigV4Request
  alias Maxio.Versioning.VersionId

  defp call(conn), do: Endpoint.call(conn, Endpoint.init([]))

  # 写权威切换（per-test，on_exit 还原）。
  defp set_write_authority(mode) do
    prev = Application.get_env(:maxio, :authoritative_source)
    Application.put_env(:maxio, :authoritative_source, Keyword.put(prev, :write, mode))
    on_exit(fn -> Application.put_env(:maxio, :authoritative_source, prev) end)
  end

  # 确定性 PG 写失败注入：事务内 CHECK 约束（sandbox 随测试回滚）。命中 key 的 objects INSERT
  # 必失败（Postgrex.Error check_violation），其余 key 不受影响——精确打击元数据提交 seam。
  defp inject_pg_failure_for_key!(key) do
    Repo.query!(
      "ALTER TABLE objects ADD CONSTRAINT b51_pg_fail_injection CHECK (key <> '#{key}')"
    )

    :ok
  end

  # 隔离对象数据目录（per-test 唯一，on_exit 清理还原）。
  defp isolate_data_dir!(prefix) do
    data_dir = Path.join(System.tmp_dir!(), "#{prefix}_#{System.unique_integer([:positive])}")
    File.rm_rf(data_dir)
    File.mkdir_p!(data_dir)
    prev_s3 = Application.get_env(:maxio, :s3)
    Application.put_env(:maxio, :s3, Keyword.put(prev_s3, :data_dir, data_dir))

    on_exit(fn ->
      Application.put_env(:maxio, :s3, prev_s3)
      File.rm_rf(data_dir)
    end)

    :ok
  end

  # 标准 sidecar 对象版本 entry（reconcile/stale 用例的盘上权威形态）。
  defp object_entry(vid, overrides \\ %{}) do
    Map.merge(
      %{
        "version_id" => vid,
        "type" => "object",
        "is_latest" => true,
        "modtime" => System.os_time(:nanosecond),
        "generation" => 2,
        "size" => 11,
        "etag" => "\"abc123\"",
        "sha256" => "deadbeef",
        "content_type" => "text/plain",
        "user_metadata" => %{"a" => "1"},
        "tags" => %{"t" => "v"},
        "acl_canned" => "private",
        "storage_class" => "STANDARD",
        "sse" => nil
      },
      overrides
    )
  end

  describe "迁移：objects.synced_at / index_generation（铁律 6 中文 COMMENT 取证）" do
    test "两列存在、类型正确、中文 COMMENT 在位" do
      %{rows: rows} =
        Repo.query!("""
        SELECT a.attname, format_type(a.atttypid, a.atttypmod), col_description(a.attrelid, a.attnum)
        FROM pg_attribute a
        WHERE a.attrelid = 'public.objects'::regclass
          AND a.attname IN ('synced_at', 'index_generation')
          AND NOT a.attisdropped
        ORDER BY a.attname
        """)

      cols = Map.new(rows, fn [name, type, comment] -> {name, {type, comment}} end)

      assert {"bigint", gen_comment} = cols["index_generation"]
      assert gen_comment =~ "sidecar 版本 generation"
      assert gen_comment =~ "stale"

      assert {ts_type, sync_comment} = cols["synced_at"]
      assert ts_type =~ "timestamp"
      assert sync_comment =~ "派生索引"
      assert sync_comment =~ "scanner"
    end
  end

  describe "写路径注入 synced_at/index_generation" do
    setup do
      {:ok, _b} = Maxio.Buckets.create("b51w", "arn:aws:iam:::root")
      :ok
    end

    test "put_version_with_id：synced_at=now、index_generation 取 attrs :generation（缺省 0）" do
      {:ok, _} = Objects.put_version_with_id("b51w", "k0", "null", %{size: 1, etag: "\"e\""})
      {:ok, row0} = Objects.get_version("b51w", "k0", "null")
      assert %DateTime{} = row0.synced_at
      assert row0.index_generation == 0

      {:ok, _} =
        Objects.put_version_with_id("b51w", "k3", "v1", %{size: 1, etag: "\"e\"", generation: 3})

      {:ok, row3} = Objects.get_version("b51w", "k3", "v1")
      assert row3.index_generation == 3
    end

    test "put_version_with_id upsert 替换集含 synced_at/index_generation（重写刷新）" do
      {:ok, _} = Objects.put_version_with_id("b51w", "ku", "null", %{size: 1, etag: "\"e1\""})
      {:ok, before_row} = Objects.get_version("b51w", "ku", "null")

      {:ok, _} =
        Objects.put_version_with_id("b51w", "ku", "null", %{
          size: 2,
          etag: "\"e2\"",
          generation: 7
        })

      {:ok, after_row} = Objects.get_version("b51w", "ku", "null")
      assert after_row.index_generation == 7
      assert DateTime.compare(after_row.synced_at, before_row.synced_at) in [:gt, :eq]
    end

    test "put_metadata（MPU complete 路径）注入 synced_at/index_generation=0" do
      {:ok, _} = Objects.put_metadata("b51w", "kmpu", %{size: 9, etag: "\"m\""})
      {:ok, row} = Objects.get_version("b51w", "kmpu", "null")
      assert %DateTime{} = row.synced_at
      assert row.index_generation == 0
    end

    test "insert_delete_marker：marker 行也带 synced_at/index_generation=0" do
      {:ok, %{version_id: vid}} = Objects.insert_delete_marker("b51w", "kdm", "Enabled")
      {:ok, row} = Objects.get_version("b51w", "kdm", vid)
      assert row.is_delete_marker == true
      assert %DateTime{} = row.synced_at
      assert row.index_generation == 0
    end
  end

  describe "B5-2 命名契约：mark_synced/4 / reconcile_from_sidecar/3 / stale?/2" do
    setup do
      {:ok, _b} = Maxio.Buckets.create("b51c", "arn:aws:iam:::root")
      :ok
    end

    test "mark_synced/4 更新 synced_at/index_generation，不触碰 updated_at；缺行 → {:error,:not_found}" do
      {:ok, _} = Objects.put_version_with_id("b51c", "k", "v1", %{size: 1, etag: "\"e\""})
      {:ok, before_row} = Objects.get_version("b51c", "k", "v1")

      assert :ok = Objects.mark_synced("b51c", "k", "v1", 5)

      {:ok, row} = Objects.get_version("b51c", "k", "v1")
      assert row.index_generation == 5
      assert %DateTime{} = row.synced_at
      assert row.updated_at == before_row.updated_at

      assert {:error, :not_found} = Objects.mark_synced("b51c", "ghost", "v1", 1)
    end

    test "reconcile_from_sidecar/3：PG 缺行 → 按 entry 建行（全字段 + synced 原子注入）" do
      vid = VersionId.generate()
      assert :ok = Objects.reconcile_from_sidecar("b51c", "kr", object_entry(vid))

      {:ok, row} = Objects.get_version("b51c", "kr", vid)
      assert row.etag == "\"abc123\""
      assert row.size == 11
      assert row.content_type == "text/plain"
      assert row.metadata == %{"a" => "1"}
      assert row.tags == %{"t" => "v"}
      assert row.is_latest == true
      assert row.is_delete_marker == false
      assert row.index_generation == 2
      assert %DateTime{} = row.synced_at
    end

    test "reconcile_from_sidecar/3：entry is_latest=true 时 unset 该 key 旧 latest 行" do
      {:ok, _} = Objects.put_version_with_id("b51c", "kl", "v-old", %{size: 1, etag: "\"old\""})

      vid = VersionId.generate()
      assert :ok = Objects.reconcile_from_sidecar("b51c", "kl", object_entry(vid))

      {:ok, old_row} = Objects.get_version("b51c", "kl", "v-old")
      assert old_row.is_latest == false
      {:ok, new_row} = Objects.get_version("b51c", "kl", vid)
      assert new_row.is_latest == true
    end

    test "reconcile_from_sidecar/3：delete_marker entry → is_delete_marker 行（etag 空、size 0）" do
      vid = VersionId.generate()

      entry = %{
        "version_id" => vid,
        "type" => "delete_marker",
        "is_latest" => true,
        "modtime" => System.os_time(:nanosecond),
        "generation" => 0
      }

      assert :ok = Objects.reconcile_from_sidecar("b51c", "kdm", entry)

      {:ok, row} = Objects.get_version("b51c", "kdm", vid)
      assert row.is_delete_marker == true
      assert row.etag == ""
      assert row.size == 0
      assert row.index_generation == 0
      assert %DateTime{} = row.synced_at
    end

    test "reconcile_from_sidecar/3：stale 行被整行收敛（etag/generation/metadata 漂移修正）" do
      vid = VersionId.generate()
      {:ok, _} = Objects.put_version_with_id("b51c", "ks", vid, %{size: 99, etag: "\"drift\""})
      {:ok, drifted} = Objects.get_version("b51c", "ks", vid)

      entry = object_entry(vid, %{"generation" => 5})
      assert Objects.stale?(drifted, entry) == true

      assert :ok = Objects.reconcile_from_sidecar("b51c", "ks", entry)

      {:ok, row} = Objects.get_version("b51c", "ks", vid)
      assert row.etag == "\"abc123\""
      assert row.size == 11
      assert row.metadata == %{"a" => "1"}
      assert row.index_generation == 5
      assert Objects.stale?(row, entry) == false
    end

    test "reconcile_from_sidecar/3：桶不存在 → {:error, :no_such_bucket}（best-effort 绝不抛）" do
      assert {:error, :no_such_bucket} =
               Objects.reconcile_from_sidecar("ghost-b51", "k", object_entry("null"))
    end

    test "stale?/2：同步行 false；generation/etag/size/type 漂移 → true" do
      vid = VersionId.generate()
      entry = object_entry(vid)
      assert :ok = Objects.reconcile_from_sidecar("b51c", "kst", entry)
      {:ok, row} = Objects.get_version("b51c", "kst", vid)

      assert Objects.stale?(row, entry) == false
      assert Objects.stale?(row, Map.put(entry, "generation", 3)) == true
      assert Objects.stale?(row, Map.put(entry, "etag", "\"other\"")) == true
      assert Objects.stale?(row, Map.put(entry, "size", 12)) == true
      assert Objects.stale?(row, Map.put(entry, "type", "delete_marker")) == true
      assert Objects.stale?(row, Map.put(entry, "user_metadata", %{"a" => "2"})) == true
    end
  end

  describe "CopyObject 分流矩阵（:pg/:sidecar × PG 成败）" do
    setup do
      isolate_data_dir!("maxio_b51_copy")
      :ok
    end

    @copy_body "b5-1 copy matrix body"

    defp put_src!(bucket) do
      assert call(SigV4Request.signed_conn(:put, "/#{bucket}")).status == 200

      put =
        SigV4Request.signed_conn(:put, "/#{bucket}/src.bin", body: @copy_body)
        |> call()

      assert put.status == 200
      # PG 行存裸 hex etag（响应头由 XML.quote_etag 加引号）。
      :crypto.hash(:md5, @copy_body) |> Base.encode16(case: :lower)
    end

    defp copy_req(bucket, dest_key) do
      SigV4Request.signed_conn(:put, "/#{bucket}/#{dest_key}",
        headers: [{"x-amz-copy-source", "/#{bucket}/src.bin"}]
      )
      |> call()
    end

    test ":pg（默认）× PG 成功 → 200 + PG 行（含 synced_at 注入）——字节级不变" do
      assert ObjectMeta.authoritative_source(:write) == :pg
      expected_etag = put_src!("b51cpa")

      copy = copy_req("b51cpa", "dst.bin")
      assert copy.status == 200
      assert copy.resp_body =~ "<ETag>"
      assert copy.resp_body =~ :crypto.hash(:md5, @copy_body) |> Base.encode16(case: :lower)

      {:ok, row} = Objects.get_metadata("b51cpa", "dst.bin")
      assert row.etag == expected_etag
      assert %DateTime{} = row.synced_at
      assert row.index_generation == 0
    end

    test ":pg（默认）× PG 失败 → 致命 500 InternalError（PG 即权威，绝不静默）" do
      _ = put_src!("b51cpb")
      inject_pg_failure_for_key!("dst-fail.bin")

      {copy, _log} = with_log(fn -> copy_req("b51cpb", "dst-fail.bin") end)

      assert copy.status == 500
      assert copy.resp_body =~ "InternalError"
    end

    test ":sidecar × PG 成功 → 200 + best-effort 索引行 + GET 回读" do
      set_write_authority(:sidecar)
      expected_etag = put_src!("b51cpc")

      copy = copy_req("b51cpc", "dst.bin")
      assert copy.status == 200
      assert copy.resp_body =~ :crypto.hash(:md5, @copy_body) |> Base.encode16(case: :lower)

      # best-effort PG 索引写成功 → 默认 :pg 读路径可回读完整内容。
      {:ok, row} = Objects.get_metadata("b51cpc", "dst.bin")
      assert row.etag == expected_etag

      get = SigV4Request.signed_conn(:get, "/b51cpc/dst.bin") |> call()
      assert get.status == 200
      assert get.resp_body == @copy_body
    end

    test ":sidecar × PG 失败 → 请求仍 200（响应视图内存构造）+ Log.error 绝不静默" do
      set_write_authority(:sidecar)
      _ = put_src!("b51cpd")
      inject_pg_failure_for_key!("dst-fail.bin")

      {copy, log} = with_log(fn -> copy_req("b51cpd", "dst-fail.bin") end)

      assert copy.status == 200
      assert copy.resp_body =~ :crypto.hash(:md5, @copy_body) |> Base.encode16(case: :lower)
      assert log =~ "pg index update failed"

      # PG 索引确实没写进去（失败被降级，留待 scanner reconcile）。
      assert {:error, :not_found} = Objects.get_metadata("b51cpd", "dst-fail.bin")
    end
  end

  describe "MPU complete 分流矩阵（:pg/:sidecar × PG 成败）" do
    setup do
      isolate_data_dir!("maxio_b51_mpu")
      Application.put_env(:maxio, :multipart_min_part_size, 1)
      on_exit(fn -> Application.delete_env(:maxio, :multipart_min_part_size) end)
      :ok
    end

    @part_body "b5-1 mpu matrix part body"

    defp upload_id(xml) do
      [_, rest] = String.split(xml, "<UploadId>")
      [id, _] = String.split(rest, "</UploadId>")
      id
    end

    defp mpu_complete(bucket, key) do
      assert call(SigV4Request.signed_conn(:put, "/#{bucket}")).status == 200

      init =
        SigV4Request.signed_conn(:post, "/#{bucket}/#{key}", query: %{"uploads" => ""})
        |> call()

      assert init.status == 200
      uid = upload_id(init.resp_body)

      up =
        SigV4Request.signed_conn(:put, "/#{bucket}/#{key}",
          query: %{"partNumber" => "1", "uploadId" => uid},
          body: @part_body
        )
        |> call()

      assert up.status == 200
      [etag1] = get_resp_header(up, "etag")

      complete_xml =
        "<CompleteMultipartUpload>" <>
          "<Part><PartNumber>1</PartNumber><ETag>#{etag1}</ETag></Part>" <>
          "</CompleteMultipartUpload>"

      SigV4Request.signed_conn(:post, "/#{bucket}/#{key}",
        query: %{"uploadId" => uid},
        body: complete_xml
      )
      |> call()
    end

    test ":pg（默认）× PG 成功 → 200 + PG 行（synced_at 注入）——字节级不变" do
      assert ObjectMeta.authoritative_source(:write) == :pg
      complete = mpu_complete("b51mpa", "big.bin")
      assert complete.status == 200
      assert complete.resp_body =~ "<ETag>"

      {:ok, row} = Objects.get_metadata("b51mpa", "big.bin")
      assert row.size == byte_size(@part_body)
      assert %DateTime{} = row.synced_at
      assert row.index_generation == 0
    end

    test ":pg（默认）× PG 失败 → 致命 500 InternalError（PG 即权威，绝不静默）" do
      inject_pg_failure_for_key!("mpu-fail.bin")

      {complete, _log} = with_log(fn -> mpu_complete("b51mpb", "mpu-fail.bin") end)

      assert complete.status == 500
      assert complete.resp_body =~ "InternalError"
    end

    test ":sidecar × PG 成功 → 200 + best-effort 索引行 + GET 回读" do
      set_write_authority(:sidecar)
      complete = mpu_complete("b51mpc", "big.bin")
      assert complete.status == 200

      get = SigV4Request.signed_conn(:get, "/b51mpc/big.bin") |> call()
      assert get.status == 200
      assert get.resp_body == @part_body
    end

    test ":sidecar × PG 失败 → Complete 仍 200（盘上 assemble 已权威）+ Log.error 绝不静默" do
      set_write_authority(:sidecar)
      inject_pg_failure_for_key!("mpu-fail.bin")

      {complete, log} = with_log(fn -> mpu_complete("b51mpd", "mpu-fail.bin") end)

      assert complete.status == 200
      assert complete.resp_body =~ "<ETag>"
      assert log =~ "pg index update failed"

      # PG 索引确实没写进去（降级 best-effort，留待 scanner reconcile）。
      assert {:error, :not_found} = Objects.get_metadata("b51mpd", "mpu-fail.bin")
    end
  end

  describe "PREFER 索引读门控（read=:sidecar + read_prefer_index）" do
    setup do
      InProcess.setup!()

      prev_backend = Application.get_env(:maxio, :storage_backend)
      Application.put_env(:maxio, :storage_backend, Maxio.Storage.Distributed)

      eps =
        for i <- 0..2,
            do:
              {:"b51p#{i}",
               Path.join(System.tmp_dir!(), "b51p_d#{i}_#{System.unique_integer([:positive])}")}

      # K=2 M=1 N=3（与既有 sidecar authority 套件一致）。
      topo = %{
        data_shards: 2,
        parity_shards: 1,
        block_size: 1024,
        sets: %{0 => %{id: 0, endpoints: eps}},
        set_ids: [0]
      }

      {:ok, _b} = Maxio.Buckets.create("b51pref", "arn:aws:iam:::root")

      on_exit(fn ->
        if prev_backend,
          do: Application.put_env(:maxio, :storage_backend, prev_backend),
          else: Application.delete_env(:maxio, :storage_backend)

        Enum.each(eps, fn {_n, d} -> File.rm_rf(d) end)
      end)

      {:ok, topo: topo}
    end

    defp read_opts(topo),
      do: [transport: InProcess, topology: topo, authoritative_source: [read: :sidecar]]

    # 真实 PUT 一个对象版本到盘（distributed + InProcess，落 maxio/2 sidecar）；返回盘上 etag。
    defp disk_put!(topo, key, vid, body) do
      object_meta = %{
        content_type: "text/plain",
        tags: %{},
        sse: nil,
        acl_canned: "private",
        storage_class: "STANDARD",
        user_metadata: %{}
      }

      assert {:ok, %{etag: etag}} =
               Storage.put("b51pref", key, vid, [body],
                 object_meta: object_meta,
                 transport: InProcess,
                 topology: topo
               )

      etag
    end

    test "默认关（config false、无 opts）→ 纯走盘：PG 行存在也不读（行为不变）", %{topo: topo} do
      assert Application.get_env(:maxio, :read_prefer_index) == false

      disk_vid = VersionId.generate()
      disk_etag = disk_put!(topo, "k", disk_vid, "disk authority body")

      pg_vid = VersionId.generate()

      {:ok, _} =
        Objects.put_version_with_id("b51pref", "k", pg_vid, %{size: 3, etag: "\"pg-divergent\""})

      got = ObjectMeta.get("b51pref", "k", nil, read_opts(topo))
      assert %Objects.Object{} = got
      assert got.etag == disk_etag
      assert got.version_id == disk_vid
    end

    test "opts read_prefer_index: true + PG 命中 → 返回 PG 索引行（快路径，latest 与显式 versionId）",
         %{topo: topo} do
      disk_vid = VersionId.generate()
      _disk_etag = disk_put!(topo, "k", disk_vid, "disk authority body")

      pg_vid = VersionId.generate()

      {:ok, _} =
        Objects.put_version_with_id("b51pref", "k", pg_vid, %{size: 3, etag: "\"pg-divergent\""})

      opts = read_opts(topo) ++ [read_prefer_index: true]

      latest = ObjectMeta.get("b51pref", "k", nil, opts)
      assert %Objects.Object{} = latest
      assert latest.etag == "\"pg-divergent\""
      assert latest.version_id == pg_vid

      by_vid = ObjectMeta.get("b51pref", "k", pg_vid, opts)
      assert %Objects.Object{etag: "\"pg-divergent\""} = by_vid
    end

    test "opts read_prefer_index: true + PG miss → 走盘 sidecar（权威兜底）", %{topo: topo} do
      disk_vid = VersionId.generate()
      disk_etag = disk_put!(topo, "konly-disk", disk_vid, "only on disk")

      got =
        ObjectMeta.get("b51pref", "konly-disk", nil, read_opts(topo) ++ [read_prefer_index: true])

      assert %Objects.Object{} = got
      assert got.etag == disk_etag
      assert got.version_id == disk_vid
    end

    test "config :read_prefer_index=true 全局开 → PG 命中；opts 显式 false 压回纯走盘", %{topo: topo} do
      prev = Application.get_env(:maxio, :read_prefer_index)
      Application.put_env(:maxio, :read_prefer_index, true)
      on_exit(fn -> Application.put_env(:maxio, :read_prefer_index, prev) end)

      disk_vid = VersionId.generate()
      disk_etag = disk_put!(topo, "k", disk_vid, "disk authority body")

      pg_vid = VersionId.generate()

      {:ok, _} =
        Objects.put_version_with_id("b51pref", "k", pg_vid, %{size: 3, etag: "\"pg-divergent\""})

      # 全局开、无 opts → PG 命中即返回。
      via_config = ObjectMeta.get("b51pref", "k", nil, read_opts(topo))
      assert via_config.etag == "\"pg-divergent\""

      # opts 显式 false 覆盖全局 true → 纯走盘（盘上权威）。
      via_override =
        ObjectMeta.get("b51pref", "k", nil, read_opts(topo) ++ [read_prefer_index: false])

      assert via_override.etag == disk_etag
      assert via_override.version_id == disk_vid
    end
  end
end
