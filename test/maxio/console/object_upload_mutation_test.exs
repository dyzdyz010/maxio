defmodule Maxio.Console.ObjectUploadMutationTest do
  @moduledoc """
  ObjectMutation Phase 2A C4 —— `Maxio.Console.ObjectUpload.upload_tmp_file/6` 小文件
  （single put）路径迁入 Commit seam 的验收（FS 后端；multipart 路径归 C8 不在本批）：

    1. 快乐路径五位一体：bytes/sidecar/PG row/journal(finalized, operation="put")/
       epoch(committed) 同一 token + fingerprint；
    2. unversioned 目标已有旧对象 + metadata_tx 注入失败（stale journal CAS）：旧 bytes/
       sidecar 逐字节恢复、PG 不变、journal=rolled_back、epoch=rolled_back、backup 清空，
       且上抛错误语义与现状一致（console 返回 {:error, reason}，不 raise）——协议 §8
       「metadata 失败保留旧目标」Console 落点，原 plain-delete 回滚点
       （cleanup_uploaded_object single-put 调用分支）消除的直接证据；
    3. quota 预检（do_put 同构）：超限在 claim/publish 之前 fail-closed——零 journal、
       无孤儿字节、错误面与迁移前一致（{:error, %S3.Error{}}）；
    4. 锁存在性构造断言：around 执行期间另一进程对同 `{bucket, key}` 取锁必 `{:error,
       :locked}`（D5 无锁 caller 补锁的直接证据）；
    5. :sidecar 写权威（D1 gate）：seam 零参与（无 journal、epoch absent），console 既有
       「put_version_with_id 致命提交」值语义不变。

  同步纪律：失败全部经 failpoint 注入；跨进程用 Task.await/assert_receive，零 Process.sleep。
  """

  use Maxio.DataCase, async: false

  import ExUnit.CaptureLog

  alias Maxio.{BucketQuota, Buckets, Objects, ObjectMutation, Storage}
  alias Maxio.Cluster.Paths
  alias Maxio.Console.ObjectUpload
  alias Maxio.Failpoint
  alias Maxio.ObjectMutation.Journal
  alias Maxio.Storage.ObjectEpoch

  @key "console/single-put.bin"

  setup do
    data_dir =
      Path.join(System.tmp_dir!(), "maxio_cu_mutation_#{System.unique_integer([:positive])}")

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

    bucket = "cumut-#{System.unique_integer([:positive])}"
    {:ok, _bucket} = Buckets.create(bucket, "arn:aws:iam:::root")

    %{data_dir: data_dir, bucket: bucket}
  end

  # ── 断言 1：快乐路径五位一体 ──

  test "快乐路径：bytes/sidecar/PG/journal(put)/epoch 五位一体同一 token", ctx do
    content = "console single put body v1"

    assert {:ok, %Objects.Object{} = object} = upload(ctx.bucket, content)
    assert object.version_id == "null"
    assert object.etag == md5_hex(content)
    assert object.size == byte_size(content)

    journal = journal_for(ctx.bucket, @key)
    assert journal.phase == "finalized"
    assert journal.operation == "put"
    assert journal.authority_mode == "pg"
    assert journal.generation == 1
    assert not is_nil(journal.metadata_committed_at)
    assert not is_nil(journal.finalized_at)

    # bytes
    final = final_dir(ctx, ctx.bucket, @key)
    assert File.read!(Path.join(final, "part.0")) == content

    # sidecar：journal published_fingerprint 与 final meta.json 实际字节精确匹配
    fingerprint = journal.published_fingerprint
    assert fingerprint["etag"] == md5_hex(content)
    assert fingerprint["size"] == byte_size(content)
    assert fingerprint["sidecar_sha256"] == sha256_hex(File.read!(Path.join(final, "meta.json")))

    # epoch：committed + 同一 token + 同一 fingerprint
    assert {:ok, %ObjectEpoch{phase: "committed"} = epoch} =
             Storage.current_epoch(target(ctx.bucket, @key))

    assert epoch.token == %{"generation" => journal.generation, "mutation_id" => journal.id}
    assert epoch.fingerprint == fingerprint

    # PG row
    assert {:ok, %Objects.Object{} = row} = Objects.get_metadata(ctx.bucket, @key)
    assert row.etag == md5_hex(content)

    # finalize 已丢弃 durable backup
    assert mutation_dirs(ctx) == []
  end

  # ── 断言 2：unversioned 覆盖 + metadata_tx 注入失败 → 旧对象保留、{:error, _} 返回 ──

  test "unversioned 目标已有旧对象 + metadata_tx 注入失败：旧对象保留、返回 {:error, _}", ctx do
    old_content = "old console body"
    assert {:ok, _object} = upload(ctx.bucket, old_content)

    final = final_dir(ctx, ctx.bucket, @key)
    old_bytes = File.read!(Path.join(final, "part.0"))
    old_sidecar = File.read!(Path.join(final, "meta.json"))
    assert {:ok, %Objects.Object{etag: old_etag}} = Objects.get_metadata(ctx.bucket, @key)

    # publish 之后、metadata 事务之前扰动 journal（attempts+1）→ 事务内 metadata_committed
    # CAS 必然 stale → Repo.rollback → metadata_tx 返回 {:error, _}（真实 metadata_tx 失败）。
    arm_stale_metadata_perturbation(ctx.bucket, @key)

    log =
      capture_log(fn ->
        # 上抛错误语义与现状一致：{:error, reason}，不 raise
        result = upload(ctx.bucket, "new console body must not commit")
        send(self(), {:upload_result, result})
      end)

    assert_receive {:upload_result, {:error, {:object_mutation_metadata_commit_failed, _}}}
    assert log =~ "upload failed"

    # 旧 bytes/sidecar 逐字节恢复、PG 行原样（旧 etag）——plain delete 危险点消除的直接证据
    assert File.read!(Path.join(final, "part.0")) == old_bytes
    assert File.read!(Path.join(final, "meta.json")) == old_sidecar
    assert {:ok, %Objects.Object{etag: ^old_etag}} = Objects.get_metadata(ctx.bucket, @key)

    # journal 与 epoch 双双 rolled_back（gen 2 的失败 mutation）、backup 清空
    journal = journal_for(ctx.bucket, @key)
    assert journal.phase == "rolled_back"
    assert journal.generation == 2

    assert {:ok, %ObjectEpoch{phase: "rolled_back"} = epoch} =
             Storage.current_epoch(target(ctx.bucket, @key))

    assert epoch.token["mutation_id"] == journal.id
    assert mutation_dirs(ctx) == []
  end

  # ── 断言 3：quota 预检 fail-closed（do_put 同构）——零 journal、无孤儿字节 ──

  test "quota 超限在 claim/publish 之前 fail-closed：零 journal、无孤儿字节", ctx do
    assert :ok = BucketQuota.put_hard(ctx.bucket, 3)

    log =
      capture_log(fn ->
        result = upload(ctx.bucket, "1234")
        send(self(), {:upload_result, result})
      end)

    assert_receive {:upload_result,
                    {:error, %Maxio.S3.Error{code: "XMinioAdminBucketQuotaExceeded"}}}

    assert log =~ "upload failed"

    # publish 之前 fail-closed：无 journal、无 epoch、无最终字节、无 PG 行、无 backup
    assert journal_count(ctx.bucket) == 0
    assert {:ok, :absent} = Storage.current_epoch(target(ctx.bucket, @key))
    refute File.exists?(final_dir(ctx, ctx.bucket, @key))
    assert {:error, :not_found} = Objects.get_metadata(ctx.bucket, @key)
    assert mutation_dirs(ctx) == []
  end

  # ── 断言 4：锁存在性——around 执行期间另一进程取同 {bucket, key} 锁必失败 ──

  test "锁存在性：seam 执行期间另一进程对同 {bucket, key} 取锁失败", ctx do
    bucket = ctx.bucket

    # 探针结果经 Agent 同步收集（Cluster.Lock 的 wait_for_result 会吞掉持锁期间发到
    # caller 邮箱的杂项消息，不能 send 回测试进程）；Agent.update 在 failpoint fun 内
    # 同步完成，upload 返回后即可读取，零 sleep。
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

    assert {:ok, %Objects.Object{}} = upload(ctx.bucket, "locked body")

    assert Agent.get(probe, & &1) == {:error, :locked}
    assert journal_for(ctx.bucket, @key).phase == "finalized"
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

    test "console 既有致命 PG 提交值语义不变、seam 零参与", ctx do
      content = "sidecar authority console body"

      assert {:ok, %Objects.Object{} = object} = upload(ctx.bucket, content)
      assert object.etag == md5_hex(content)

      # bytes + sidecar 已落盘、PG 行照旧写入（console 无 best-effort index 分支）
      final = final_dir(ctx, ctx.bucket, @key)
      assert File.read!(Path.join(final, "part.0")) == content
      assert File.regular?(Path.join(final, "meta.json"))
      assert {:ok, %Objects.Object{}} = Objects.get_metadata(ctx.bucket, @key)

      # seam 零参与：无 journal 行、无 epoch、无 durable backup（非协议路径不变）
      assert journal_count(ctx.bucket) == 0
      assert {:ok, :absent} = Storage.current_epoch(target(ctx.bucket, @key))
      assert mutation_dirs(ctx) == []
    end
  end

  # ── helpers ──

  defp upload(bucket, content) do
    tmp_path =
      Path.join(
        System.tmp_dir!(),
        "cu-mutation-#{System.unique_integer([:positive])}"
      )

    File.write!(tmp_path, content)
    on_exit(fn -> File.rm(tmp_path) end)

    ObjectUpload.upload_tmp_file(
      bucket,
      @key,
      "Unversioned",
      tmp_path,
      %{content_type: "application/octet-stream"},
      []
    )
  end

  # 在 publish 之后、metadata 事务之前扰动目标 journal（attempts+1）：事务 hook 内基于
  # 请求手中旧 journal 行的 CAS 必然 stale_journal → 整个 metadata 事务回滚
  # （object_writer_mutation_test 同源注入手段）。
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

         {:ok, _} = ObjectMutation.mark_error(journal, :c4_perturb, %{"stage" => "test"})
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
