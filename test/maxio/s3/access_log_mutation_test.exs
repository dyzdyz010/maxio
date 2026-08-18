defmodule Maxio.S3.AccessLogMutationTest do
  @moduledoc """
  ObjectMutation Phase 2A C4 —— `Maxio.S3.Plugs.AccessLogDelivery.write_log_object/5`
  （server access log delivery，无锁 caller 补锁批）迁入 Commit seam 的验收（FS 后端）：

    1. 快乐路径五位一体：bytes/sidecar/PG row/journal(finalized, operation="generated_put")/
       epoch(committed) 同一 token + fingerprint；
    2. unversioned 目标已有旧对象 + metadata_tx 注入失败（stale journal CAS）：旧 bytes/
       sidecar 逐字节恢复、PG 不变、journal=rolled_back、epoch=rolled_back、backup 清空，
       且 write_log_object 本身不 raise（best-effort，仅记日志）——协议 §8「metadata 失败
       保留旧目标」AccessLog 落点，原 plain-delete 回滚点（cleanup_log_object）消除的直接证据；
    3. 真实 plug 集成（Endpoint 全链路）：目标 journal 注入失败时**原始 S3 请求仍成功**
       （best-effort 语义断言）；
    4. 锁存在性构造断言：around 执行期间另一进程对同 `{bucket, key}` 取锁必 `{:error,
       :locked}`（D5 无锁 caller 补锁的直接证据）；
    5. :sidecar 写权威（D1 gate）：seam 零参与（无 journal、epoch absent）、publish 即
       权威提交、PG index best-effort——行为与迁移前一致。

  同步纪律：失败全部经 failpoint 注入；跨进程用 Task.await/assert_receive，零 Process.sleep。
  """

  use Maxio.DataCase, async: false

  import ExUnit.CaptureLog

  alias Maxio.{BucketConfigs, Buckets, Objects, ObjectMutation, Storage}
  alias Maxio.Cluster.Paths
  alias Maxio.Failpoint
  alias Maxio.ObjectMutation.Journal
  alias Maxio.S3.Endpoint
  alias Maxio.S3.Plugs.AccessLogDelivery
  alias Maxio.Storage.ObjectEpoch
  alias Maxio.Test.SigV4Request

  @key "access/2026-07-11-00-00-00-c4mutation.log"
  @source "logmut-source"

  setup do
    data_dir =
      Path.join(System.tmp_dir!(), "maxio_al_mutation_#{System.unique_integer([:positive])}")

    File.rm_rf(data_dir)
    File.mkdir_p!(data_dir)

    prev_s3 = Application.get_env(:maxio, :s3)
    Application.put_env(:maxio, :s3, Keyword.put(prev_s3, :data_dir, data_dir))

    on_exit(fn ->
      Application.put_env(:maxio, :s3, prev_s3)
      Failpoint.disarm(:object_mutation_before_metadata_commit)
      Failpoint.disarm(:object_mutation_after_metadata_commit)
      File.rm_rf(data_dir)
    end)

    target = "logmut-target-#{System.unique_integer([:positive])}"
    {:ok, _bucket} = Buckets.create(target, "arn:aws:iam:::root")
    {:ok, target_info} = Buckets.lookup(target)

    %{data_dir: data_dir, target: target, target_info: target_info}
  end

  # ── 断言 1：快乐路径五位一体 ──

  test "快乐路径：bytes/sidecar/PG/journal(generated_put)/epoch 五位一体同一 token", ctx do
    line = "c4 access log line v1"
    body = line <> "\n"

    AccessLogDelivery.write_log_object(ctx.target_info, @key, line, @source, [])

    journal = journal_for(ctx.target, @key)
    assert journal.phase == "finalized"
    assert journal.operation == "generated_put"
    assert journal.authority_mode == "pg"
    assert journal.generation == 1
    assert not is_nil(journal.metadata_committed_at)
    assert not is_nil(journal.finalized_at)

    # bytes
    final = final_dir(ctx, ctx.target, @key)
    assert File.read!(Path.join(final, "part.0")) == body

    # sidecar：journal published_fingerprint 与 final meta.json 实际字节精确匹配
    fingerprint = journal.published_fingerprint
    assert fingerprint["etag"] == md5_hex(body)
    assert fingerprint["size"] == byte_size(body)
    assert fingerprint["sidecar_sha256"] == sha256_hex(File.read!(Path.join(final, "meta.json")))

    # epoch：committed + 同一 token + 同一 fingerprint
    assert {:ok, %ObjectEpoch{phase: "committed"} = epoch} =
             Storage.current_epoch(target(ctx.target, @key))

    assert epoch.token == %{"generation" => journal.generation, "mutation_id" => journal.id}
    assert epoch.fingerprint == fingerprint

    # PG row
    assert {:ok, %Objects.Object{} = row} = Objects.get_metadata(ctx.target, @key)
    assert row.etag == md5_hex(body)
    assert row.size == byte_size(body)
    assert row.metadata == %{"maxio-log-source-bucket" => @source}

    # finalize 已丢弃 durable backup
    assert mutation_dirs(ctx) == []
  end

  # ── 断言 2：unversioned 覆盖 + metadata_tx 注入失败 → 旧对象保留、请求层不 raise ──

  test "unversioned 目标已有旧对象 + metadata_tx 注入失败：旧对象保留且投递不 raise", ctx do
    AccessLogDelivery.write_log_object(ctx.target_info, @key, "old log line", @source, [])

    final = final_dir(ctx, ctx.target, @key)
    old_bytes = File.read!(Path.join(final, "part.0"))
    old_sidecar = File.read!(Path.join(final, "meta.json"))
    assert {:ok, %Objects.Object{etag: old_etag}} = Objects.get_metadata(ctx.target, @key)

    # publish 之后、metadata 事务之前扰动 journal（attempts+1）→ 事务内 metadata_committed
    # CAS 必然 stale → Repo.rollback → metadata_tx 返回 {:error, _}（真实 metadata_tx 失败）。
    arm_stale_metadata_perturbation(ctx.target, @key)

    log =
      capture_log(fn ->
        # best-effort：metadata 失败绝不 raise，仅记日志（写路径错误吞在请求层）。
        AccessLogDelivery.write_log_object(
          ctx.target_info,
          @key,
          "new log line must not commit",
          @source,
          []
        )
      end)

    assert log =~ "server access log storage write failed"

    # 旧 bytes/sidecar 逐字节恢复、PG 行原样（旧 etag）——plain delete 危险点消除的直接证据
    assert File.read!(Path.join(final, "part.0")) == old_bytes
    assert File.read!(Path.join(final, "meta.json")) == old_sidecar
    assert {:ok, %Objects.Object{etag: ^old_etag}} = Objects.get_metadata(ctx.target, @key)

    # journal 与 epoch 双双 rolled_back（gen 2 的失败 mutation）、backup 清空
    journal = journal_for(ctx.target, @key)
    assert journal.phase == "rolled_back"
    assert journal.generation == 2

    assert {:ok, %ObjectEpoch{phase: "rolled_back"} = epoch} =
             Storage.current_epoch(target(ctx.target, @key))

    assert epoch.token["mutation_id"] == journal.id
    assert mutation_dirs(ctx) == []
  end

  # ── 断言 3：真实 plug 集成——目标 metadata 注入失败时原始 S3 请求仍成功 ──

  test "plug 集成：目标 journal 注入失败时原始 S3 请求仍成功（best-effort）", ctx do
    source = "#{@source}-#{System.unique_integer([:positive])}"
    {:ok, _bucket} = Buckets.create(source, "arn:aws:iam:::root")

    :ok =
      BucketConfigs.put(source, :logging, %{
        "LoggingEnabled" => %{"TargetBucket" => ctx.target, "TargetPrefix" => "access/"}
      })

    # 仅当出现目标桶 published 阶段 journal（即 log delivery 自身的 mutation）时扰动；
    # 源对象 put 的 journal（bucket=source）不受影响。
    arm_target_bucket_perturbation(ctx.target)

    log =
      capture_log(fn ->
        response =
          SigV4Request.signed_conn(:put, "/#{source}/hello.txt", body: "hello")
          |> Endpoint.call(Endpoint.init([]))

        send(self(), {:s3_response, response})
      end)

    assert_receive {:s3_response, response}
    assert response.status == 200

    # 源对象已权威提交；目标 log 对象未提交（journal rolled_back、PG 无行）
    assert {:ok, %Objects.Object{}} = Objects.get_metadata(source, "hello.txt")

    journal = journal_for_bucket(ctx.target)
    assert journal.phase == "rolled_back"
    assert journal.operation == "generated_put"
    assert Objects.list_objects_v2(ctx.target, %{prefix: "access/", max_keys: 10}).objects == []
    assert log =~ "server access log storage write failed"
  end

  # ── 断言 4：锁存在性——around 执行期间另一进程取同 {bucket, key} 锁必失败 ──

  test "锁存在性：seam 执行期间另一进程对同 {bucket, key} 取锁失败", ctx do
    bucket = ctx.target

    # 探针结果经 Agent 同步收集（Cluster.Lock 的 wait_for_result 会吞掉持锁期间发到
    # caller 邮箱的杂项消息，不能 send 回测试进程）；Agent.update 在 failpoint fun 内
    # 同步完成，write 返回后即可读取，零 sleep。
    {:ok, probe} = Agent.start_link(fn -> :not_probed end)

    Failpoint.arm(
      :object_mutation_before_metadata_commit,
      {:fun,
       fn ->
         task =
           Task.async(fn ->
             Maxio.Lock.with_object_lock({bucket, @key}, fn -> :acquired end)
           end)

         result = Task.await(task, 10_000)
         Agent.update(probe, fn _ -> result end)
       end}
    )

    AccessLogDelivery.write_log_object(ctx.target_info, @key, "locked line", @source, [])

    assert Agent.get(probe, & &1) == {:error, :locked}

    # 扰动仅探测不注入失败：投递本身照常完成
    assert journal_for(ctx.target, @key).phase == "finalized"
    assert {:ok, %Objects.Object{}} = Objects.get_metadata(ctx.target, @key)
  end

  # ── 断言 5：:sidecar 写权威分支（D1 gate）零 seam 参与 ──

  describe ":sidecar 写权威（D1 gate）" do
    setup do
      prev_auth = Application.get_env(:maxio, :authoritative_source)

      Application.put_env(
        :maxio,
        :authoritative_source,
        Keyword.put(prev_auth || [], :write, :sidecar)
      )

      on_exit(fn ->
        if prev_auth,
          do: Application.put_env(:maxio, :authoritative_source, prev_auth),
          else: Application.delete_env(:maxio, :authoritative_source)
      end)

      :ok
    end

    test "publish 即权威提交、PG index best-effort、seam 零参与", ctx do
      line = "sidecar authority log line"
      body = line <> "\n"

      AccessLogDelivery.write_log_object(ctx.target_info, @key, line, @source, [])

      # bytes + sidecar 已权威落盘
      final = final_dir(ctx, ctx.target, @key)
      assert File.read!(Path.join(final, "part.0")) == body
      assert File.regular?(Path.join(final, "meta.json"))

      # PG best-effort 索引已写（默认 FS 后端成功路径）
      assert {:ok, %Objects.Object{etag: etag}} = Objects.get_metadata(ctx.target, @key)
      assert etag == md5_hex(body)

      # seam 零参与：无 journal 行、无 epoch、无 durable backup（非协议路径不变）
      assert journal_count(ctx.target) == 0
      assert {:ok, :absent} = Storage.current_epoch(target(ctx.target, @key))
      assert mutation_dirs(ctx) == []
    end
  end

  # ── helpers ──

  # 在 publish 之后、metadata 事务之前扰动目标 journal（attempts+1）：事务 hook 内基于
  # 请求手中旧 journal 行的 CAS 必然 stale_journal → 整个 metadata 事务回滚
  # （object_writer_mutation_test 同源注入手段）。
  #
  # 必须用**保留取证的** operational CAS probe `mark_operational_error/3`（design D6 §3.3）：
  # 它只更新 attempts / next_attempt_at / bounded last_error / updated_at，逐字保留 PG
  # published 行上已持久化的 `published_fingerprint` 与 canonical successful PublishedProof
  # wrapper，随后 `request_rollback/3` 的 published-origin 证据校验才有合法 durable evidence。
  # legacy `mark_error/4` 会**替换** recovery_evidence 并被 `{:error, :invalid_rollback_evidence}`
  # 合法拒绝。reason 必须是稳定 binary（非 binary 一律 {:error, :invalid_operational_reason}）。
  defp arm_stale_metadata_perturbation(bucket, key) do
    Failpoint.arm(
      :object_mutation_before_metadata_commit,
      {:fun,
       fn ->
         journal =
           Repo.one!(
             from j in Journal,
               where: j.bucket_name == ^bucket and j.object_key == ^key and j.phase == "published"
           )

         {:ok, _} = ObjectMutation.mark_operational_error(journal, "c4_perturb")
       end}
    )
  end

  # plug 集成版：仅命中目标桶 published 阶段 journal 时扰动（源对象 put 的 journal 放行）。
  # 同上：保留取证的 operational CAS probe，canonical PublishedProof wrapper 逐字保留。
  defp arm_target_bucket_perturbation(bucket) do
    Failpoint.arm(
      :object_mutation_before_metadata_commit,
      {:fun,
       fn ->
         case Repo.one(
                from j in Journal,
                  where: j.bucket_name == ^bucket and j.phase == "published"
              ) do
           nil -> :ok
           journal -> {:ok, _} = ObjectMutation.mark_operational_error(journal, "c4_perturb")
         end
       end}
    )
  end

  defp journal_for(bucket, key) do
    Repo.one!(
      from j in Journal,
        where: j.bucket_name == ^bucket and j.object_key == ^key,
        order_by: [desc: j.generation],
        limit: 1
    )
  end

  defp journal_for_bucket(bucket) do
    Repo.one!(
      from j in Journal,
        where: j.bucket_name == ^bucket,
        order_by: [desc: j.inserted_at],
        limit: 1
    )
  end

  defp journal_count(bucket) do
    Repo.aggregate(from(j in Journal, where: j.bucket_name == ^bucket), :count)
  end

  defp target(bucket, key) do
    {:ok, target} = ObjectEpoch.object_target(bucket, key, "null")
    target
  end

  defp final_dir(ctx, bucket, key) do
    {:ok, rel} = Paths.object_rel(bucket, key, "null")
    Path.join(ctx.data_dir, rel)
  end

  # durable mutation backup 根下的残留目录（不存在视为空；File.ls 判空，B2 审查项 1）。
  defp mutation_dirs(ctx) do
    case File.ls(Path.join(ctx.data_dir, ".maxio-object-mutations")) do
      {:ok, entries} -> entries
      {:error, :enoent} -> []
    end
  end

  defp md5_hex(content), do: :crypto.hash(:md5, content) |> Base.encode16(case: :lower)
  defp sha256_hex(content), do: :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)
end
