defmodule Maxio.S3.ObjectWriterMutationTest do
  @moduledoc """
  ObjectMutation Phase 2A C2 —— `Maxio.S3.ObjectWriter.put_generated!/4`（server-generated
  put，含 Restore/Select output 调用路径）迁入 Commit seam 的验收（FS 后端）：

    1. 快乐路径五位一体：bytes/sidecar/PG row/journal(finalized, operation="generated_put")/
       epoch(committed) 同一 token + fingerprint；
    2. unversioned 目标已有旧对象 + metadata_tx 注入失败（stale journal CAS）：旧 bytes/
       sidecar 逐字节恢复、PG 不变、journal=rolled_back、epoch=rolled_back、backup 清空
       ——协议 §8「metadata 失败保留旧目标」ObjectWriter 落点，原 plain-delete 回滚点
       （cleanup_bytes_after_metadata_failure）消除的直接证据；
    3. PG commit 后 kill（failpoint `:object_mutation_after_metadata_commit`）→ recovery
       drain → 新字节保留、journal=finalized；
    4. :sidecar 写权威（D1 gate）：seam 零参与（无 journal、epoch absent）、publish 即
       权威提交、PG index best-effort——行为与迁移前逐字节一致。

  同步纪律：崩溃/失败全部经 failpoint 注入；收敛用 10ms receive 条件轮询，零 Process.sleep。
  """

  use Maxio.DataCase, async: false

  alias Maxio.{Buckets, Objects, ObjectMutation, Storage}
  alias Maxio.Cluster.Paths
  alias Maxio.Failpoint
  alias Maxio.ObjectMutation.Journal
  alias Maxio.ObjectMutation.Recovery
  alias Maxio.S3.ObjectWriter
  alias Maxio.Storage.ObjectEpoch

  @key "generated/output.txt"

  setup do
    data_dir =
      Path.join(System.tmp_dir!(), "maxio_ow_mutation_#{System.unique_integer([:positive])}")

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

    bucket = "owmut-#{System.unique_integer([:positive])}"
    {:ok, _bucket} = Buckets.create(bucket, "arn:aws:iam:::root")

    %{data_dir: data_dir, bucket: bucket}
  end

  # ── 断言 1：快乐路径五位一体 ──

  test "快乐路径：bytes/sidecar/PG/journal(generated_put)/epoch 五位一体同一 token", ctx do
    content = "generated object content v1"

    object = ObjectWriter.put_generated!(ctx.bucket, @key, [content], sse_target: nil)
    assert %Objects.Object{version_id: "null"} = object
    assert object.etag == md5_hex(content)

    journal = journal_for(ctx.bucket, @key)
    assert journal.phase == "finalized"
    assert journal.operation == "generated_put"
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
    assert row.size == byte_size(content)

    # finalize 已丢弃 durable backup
    assert mutation_dirs(ctx) == []
  end

  # ── 断言 2：unversioned 覆盖 + metadata_tx 注入失败 → 旧对象逐字节恢复 ──

  test "unversioned 目标已有旧对象 + metadata_tx 注入失败：旧 bytes/sidecar 恢复、PG 不变", ctx do
    old_content = "old generated body"
    _old = ObjectWriter.put_generated!(ctx.bucket, @key, [old_content], sse_target: nil)

    final = final_dir(ctx, ctx.bucket, @key)
    old_bytes = File.read!(Path.join(final, "part.0"))
    old_sidecar = File.read!(Path.join(final, "meta.json"))
    assert {:ok, %Objects.Object{etag: old_etag}} = Objects.get_metadata(ctx.bucket, @key)

    # publish 之后、metadata 事务之前扰动 journal（attempts+1）→ 事务内 metadata_committed
    # CAS 必然 stale → Repo.rollback → metadata_tx 返回 {:error, _}（真实 metadata_tx 失败）。
    arm_stale_metadata_perturbation(ctx.bucket, @key)

    err =
      assert_raise Maxio.S3.Error, fn ->
        ObjectWriter.put_generated!(ctx.bucket, @key, ["new body must not commit"],
          sse_target: nil
        )
      end

    assert err.code == "InternalError"

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

  # ── 断言 3：PG commit 后 kill → recovery finalize、新字节保留 ──

  test "PG commit 后 kill：recovery drain 收敛 finalized、新字节保留", ctx do
    old_content = "old body before crash"
    _old = ObjectWriter.put_generated!(ctx.bucket, @key, [old_content], sse_target: nil)

    new_content = "new body survives pg-commit crash"
    Failpoint.arm(:object_mutation_after_metadata_commit, {:raise, "crash after pg commit"})

    assert_raise RuntimeError, "crash after pg commit", fn ->
      ObjectWriter.put_generated!(ctx.bucket, @key, [new_content], sse_target: nil)
    end

    Failpoint.disarm(:object_mutation_after_metadata_commit)

    # crash 时刻：journal 停在 metadata_committed、新字节已发布、PG 行已提交、backup 保留
    journal = journal_for(ctx.bucket, @key)
    assert journal.phase == "metadata_committed"
    assert journal.generation == 2

    final = final_dir(ctx, ctx.bucket, @key)
    assert File.read!(Path.join(final, "part.0")) == new_content
    assert {:ok, %Objects.Object{etag: etag}} = Objects.get_metadata(ctx.bucket, @key)
    assert etag == md5_hex(new_content)
    refute mutation_dirs(ctx) == []

    # recovery 收敛（prepare 宽限 60s → now 注入越过）
    assert_eventually(fn ->
      _ = Recovery.drain(now: future(300))
      ObjectMutation.get(journal.id).phase == "finalized"
    end)

    assert File.read!(Path.join(final, "part.0")) == new_content

    assert {:ok, %ObjectEpoch{phase: "committed"} = epoch} =
             Storage.current_epoch(target(ctx.bucket, @key))

    assert epoch.token == %{"generation" => journal.generation, "mutation_id" => journal.id}
    assert {:ok, %Objects.Object{etag: ^etag}} = Objects.get_metadata(ctx.bucket, @key)
    assert mutation_dirs(ctx) == []
  end

  # ── 断言 4：:sidecar 写权威分支逐字节不变（D1 gate 回归）──

  describe ":sidecar 写权威（D1 gate）" do
    setup do
      prev_auth = Application.get_env(:maxio, :authoritative_source)

      Application.put_env(
        :maxio,
        :authoritative_source,
        Keyword.put(prev_auth || [], :write, :sidecar)
      )

      on_exit(fn -> Application.put_env(:maxio, :authoritative_source, prev_auth) end)
      :ok
    end

    test "publish 即权威提交、PG index best-effort、seam 零参与（含覆盖写）", ctx do
      content = "sidecar authority generated body"

      object = ObjectWriter.put_generated!(ctx.bucket, @key, [content], sse_target: nil)

      # 返回视图由 build_put_view 经已知 attrs 构造（不读 PG 行）——与迁移前一致
      assert %Objects.Object{version_id: "null", is_latest: true} = object
      assert object.etag == md5_hex(content)
      assert object.size == byte_size(content)

      # bytes + sidecar 已权威落盘
      final = final_dir(ctx, ctx.bucket, @key)
      assert File.read!(Path.join(final, "part.0")) == content
      assert File.regular?(Path.join(final, "meta.json"))

      # PG best-effort 索引已写（默认 FS 后端成功路径）
      assert {:ok, %Objects.Object{etag: etag}} = Objects.get_metadata(ctx.bucket, @key)
      assert etag == md5_hex(content)

      # seam 零参与：无 journal 行、无 epoch、无 durable backup（非协议路径逐字节不变）
      assert journal_count(ctx.bucket) == 0
      assert {:ok, :absent} = Storage.current_epoch(target(ctx.bucket, @key))
      assert mutation_dirs(ctx) == []

      # 覆盖写同样不经 seam
      replaced = "sidecar authority replaced body"
      _object = ObjectWriter.put_generated!(ctx.bucket, @key, [replaced], sse_target: nil)
      assert File.read!(Path.join(final, "part.0")) == replaced
      assert journal_count(ctx.bucket) == 0
      assert {:ok, :absent} = Storage.current_epoch(target(ctx.bucket, @key))
    end
  end

  # ── helpers ──

  # 在 publish 之后、metadata 事务之前扰动目标 journal（attempts+1）：事务 hook 内基于
  # 请求手中旧 journal 行的 CAS 必然 stale_journal → 整个 metadata 事务回滚。
  #
  # 这里必须用**保留取证的** operational CAS probe `mark_operational_error/3`（design D6
  # §3.3）：它的 SQL update set 只含 attempts / next_attempt_at / bounded last_error /
  # updated_at，逐字保留 PG published 行上已经持久化的 `published_fingerprint` 与 canonical
  # successful PublishedProof wrapper。legacy `mark_error/4` 会**替换** recovery_evidence，
  # 使随后 `request_rollback/3` 的 published-origin 证据校验拿到 generic evidence 而被
  # `{:error, :invalid_rollback_evidence}` 合法拒绝——那是夹具违约，不是状态机回归。
  # reason 必须是稳定 binary（非 binary 一律 {:error, :invalid_operational_reason}）。
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

         {:ok, _} = ObjectMutation.mark_operational_error(journal, "c2_perturb")
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

  defp future(seconds), do: DateTime.add(DateTime.utc_now(), seconds, :second)

  # 10ms receive 轮询（零 Process.sleep）。
  defp assert_eventually(fun, timeout_ms \\ 10_000) when is_function(fun, 0) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms

    unless eventually?(fun, deadline) do
      flunk("condition not met within #{timeout_ms}ms")
    end
  end

  defp eventually?(fun, deadline) do
    if fun.() do
      true
    else
      if System.monotonic_time(:millisecond) >= deadline do
        false
      else
        receive do
        after
          10 -> eventually?(fun, deadline)
        end
      end
    end
  end
end
