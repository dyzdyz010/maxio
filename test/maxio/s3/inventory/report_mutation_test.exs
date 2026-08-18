defmodule Maxio.S3.Inventory.ReportMutationTest do
  @moduledoc """
  ObjectMutation Phase 2A C2 —— Inventory report 写路径迁入 Commit seam 的验收（FS 后端，
  每个 report object 独立 journal，operation="generated_put"）：

    1. 快乐路径（Report.run）：4 个 report object 全部 finalized，数据对象五位一体
       （bytes/sidecar/PG row/journal/epoch 同一 token + fingerprint）；
    2. TOCTOU 命中（直接驱动 write_report_object 绕过 ensure_safe 预检；旧对象仅在盘上、
       无 PG 行——锁内 PG 复检不可见）+ metadata_tx 注入失败：旧 bytes/sidecar 逐字节恢复、
       PG 不变、journal=rolled_back、epoch=rolled_back、backup 清空——协议 §8「metadata
       失败保留旧目标」Inventory 落点，原 plain-delete 回滚点（cleanup_report_object）
       消除的直接证据；
    3. 锁内复检（TOCTOU 收窄）：unversioned 目标已有 PG 行 → `{:report_target_exists, _}`
       abort，零 journal、零字节破坏；
    4. PG commit 后 kill → recovery drain → 新字节保留、journal=finalized；
    5. 跨对象 abort（Report.run）：对象 2（symlink）失败 → 对象 1（data，已 finalized）
       经现状 delete 清理、对象 2 自身 seam 回滚、run 记失败且重试成功；
    6. :sidecar 写权威（D1 gate，经 storage_opts 注入）：seam 零参与、PG index
       best-effort——行为与迁移前逐字节一致。

  同步纪律：失败全部经 failpoint 注入；收敛用 10ms receive 条件轮询，零 Process.sleep。
  """

  use Maxio.DataCase, async: false

  alias Maxio.{Buckets, Objects, ObjectMutation, Storage}
  alias Maxio.Cluster.Paths
  alias Maxio.Failpoint
  alias Maxio.ObjectMutation.Journal
  alias Maxio.ObjectMutation.Recovery
  alias Maxio.S3.Inventory
  alias Maxio.S3.Inventory.Report
  alias Maxio.Storage.ObjectEpoch

  @now ~U[2026-06-30 00:00:00Z]

  setup do
    data_dir =
      Path.join(System.tmp_dir!(), "maxio_inv_mutation_#{System.unique_integer([:positive])}")

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

    suffix = System.unique_integer([:positive])
    src = "invmut-src-#{suffix}"
    dest = "invmut-dest-#{suffix}"
    {:ok, _} = Buckets.create(src, "arn:aws:iam:::root")
    {:ok, _} = Buckets.create(dest, "arn:aws:iam:::root")

    %{data_dir: data_dir, src: src, dest: dest}
  end

  # ── 断言 1：快乐路径（Report.run，4 对象独立 journal）──

  test "快乐路径：4 个 report object 全部 finalized、数据对象五位一体", ctx do
    seed_source_object(ctx.src)
    put_daily_config(ctx)

    summary = Report.run(bucket: ctx.src, id: "daily", now: @now, run_id: "r1", file_id: "p1")

    assert summary.errors == []
    assert summary.reports_written == 1
    assert summary.objects_written == 4

    report = hd(summary.reports)

    # 4 个对象各一条 journal，全部 finalized + operation="generated_put"
    journals = journals_for_bucket(ctx.dest)
    assert length(journals) == 4

    assert Enum.map(journals, & &1.object_key) |> Enum.sort() ==
             Enum.sort([
               report.data_key,
               report.symlink_key,
               report.checksum_key,
               report.manifest_key
             ])

    for journal <- journals do
      assert journal.phase == "finalized"
      assert journal.operation == "generated_put"
      assert journal.authority_mode == "pg"
      assert not is_nil(journal.metadata_committed_at)
      assert not is_nil(journal.finalized_at)
    end

    # 数据对象五位一体：bytes / sidecar fingerprint / PG row / journal / epoch 同一 token
    data_journal = Enum.find(journals, &(&1.object_key == report.data_key))
    final = final_dir(ctx, ctx.dest, report.data_key)
    data_bytes = File.read!(Path.join(final, "part.0"))
    assert :zlib.gunzip(data_bytes) =~ "docs%2Fa.txt"

    fingerprint = data_journal.published_fingerprint
    assert fingerprint["etag"] == md5_hex(data_bytes)
    assert fingerprint["size"] == byte_size(data_bytes)
    assert fingerprint["sidecar_sha256"] == sha256_hex(File.read!(Path.join(final, "meta.json")))

    assert {:ok, %ObjectEpoch{phase: "committed"} = epoch} =
             Storage.current_epoch(target(ctx.dest, report.data_key))

    assert epoch.token == %{
             "generation" => data_journal.generation,
             "mutation_id" => data_journal.id
           }

    assert epoch.fingerprint == fingerprint

    assert {:ok, %Objects.Object{} = row} =
             Objects.get_version(ctx.dest, report.data_key, "null")

    assert row.etag == md5_hex(data_bytes)

    # finalize 已丢弃全部 durable backup
    assert mutation_dirs(ctx) == []
  end

  # ── 断言 2：TOCTOU 命中 + metadata_tx 注入失败 → 旧对象逐字节恢复 ──

  test "TOCTOU 命中（盘上旧对象、无 PG 行）+ metadata_tx 注入失败：旧 bytes/sidecar 恢复", ctx do
    key = "reports/toctou/part-00000"
    old_body = "pre-existing on-disk object (no pg row)"

    # 模拟 TOCTOU：目标 key 在盘上已有对象但 PG 无行（锁内 Objects.get_version 复检
    # 不可见），直接驱动 write_report_object 绕过 ensure_safe 预检。
    {:ok, _} = Storage.put(ctx.dest, key, "null", [old_body], [])
    final = final_dir(ctx, ctx.dest, key)
    old_bytes = File.read!(Path.join(final, "part.0"))
    old_sidecar = File.read!(Path.join(final, "meta.json"))

    arm_stale_metadata_perturbation(ctx.dest, key)

    {:ok, destination_info} = Buckets.lookup(ctx.dest)
    body = "inventory overwrite must roll back"
    spec = {:binary, key, body, byte_size(body), "text/plain", nil}

    assert {:error, {:object_mutation_metadata_commit_failed, {:stale_journal, _, _}}} =
             Report.write_report_object(destination_info, spec, ctx.src, nil, %{
               storage_opts: []
             })

    # 旧 bytes/sidecar 逐字节恢复、PG 仍无行——plain delete 危险点消除的直接证据
    assert File.read!(Path.join(final, "part.0")) == old_bytes
    assert File.read!(Path.join(final, "meta.json")) == old_sidecar
    assert {:error, :not_found} = Objects.get_version(ctx.dest, key, "null")

    journal = journal_for(ctx.dest, key)
    assert journal.phase == "rolled_back"

    assert {:ok, %ObjectEpoch{phase: "rolled_back"} = epoch} =
             Storage.current_epoch(target(ctx.dest, key))

    assert epoch.token["mutation_id"] == journal.id
    assert mutation_dirs(ctx) == []
  end

  # ── 断言 3：锁内复检（TOCTOU 收窄）→ 命中即 abort、零破坏 ──

  test "锁内复检：unversioned 目标已有 PG 行 → report_target_exists abort、零 journal", ctx do
    key = "reports/exists/part-00000"
    old_body = "committed object with pg row"

    {:ok, _} = Storage.put(ctx.dest, key, "null", [old_body], [])

    {:ok, _} =
      Objects.put_version_with_id(ctx.dest, key, "null", %{
        size: byte_size(old_body),
        etag: md5_hex(old_body)
      })

    {:ok, destination_info} = Buckets.lookup(ctx.dest)
    body = "must not overwrite existing target"
    spec = {:binary, key, body, byte_size(body), "text/plain", nil}

    assert {:error, {:report_target_exists, ^key}} =
             Report.write_report_object(destination_info, spec, ctx.src, nil, %{
               storage_opts: []
             })

    # 零 journal（claim 之前 abort）、旧对象 bytes/PG 行原样
    assert journal_count(ctx.dest) == 0
    final = final_dir(ctx, ctx.dest, key)
    assert File.read!(Path.join(final, "part.0")) == old_body
    assert {:ok, %Objects.Object{}} = Objects.get_version(ctx.dest, key, "null")
  end

  # ── 断言 4：PG commit 后 kill → recovery finalize、新字节保留 ──

  test "PG commit 后 kill：recovery drain 收敛 finalized、新字节保留", ctx do
    key = "reports/crash/part-00000"
    body = "report bytes survive pg-commit crash"

    Failpoint.arm(:object_mutation_after_metadata_commit, {:raise, "crash after pg commit"})

    {:ok, destination_info} = Buckets.lookup(ctx.dest)
    spec = {:binary, key, body, byte_size(body), "text/plain", nil}

    assert_raise RuntimeError, "crash after pg commit", fn ->
      Report.write_report_object(destination_info, spec, ctx.src, nil, %{storage_opts: []})
    end

    Failpoint.disarm(:object_mutation_after_metadata_commit)

    journal = journal_for(ctx.dest, key)
    assert journal.phase == "metadata_committed"

    final = final_dir(ctx, ctx.dest, key)
    assert File.read!(Path.join(final, "part.0")) == body
    assert {:ok, %Objects.Object{}} = Objects.get_version(ctx.dest, key, "null")

    assert_eventually(fn ->
      _ = Recovery.drain(now: future(300))
      ObjectMutation.get(journal.id).phase == "finalized"
    end)

    assert File.read!(Path.join(final, "part.0")) == body

    assert {:ok, %ObjectEpoch{phase: "committed"} = epoch} =
             Storage.current_epoch(target(ctx.dest, key))

    assert epoch.token == %{"generation" => journal.generation, "mutation_id" => journal.id}
    assert mutation_dirs(ctx) == []
  end

  # ── 断言 5：跨对象 abort → 对象 1 现状 delete 清理、对象 2 seam 回滚、可重试 ──

  test "跨对象 abort：对象 2 失败 → 对象 1 delete 清理、对象 2 seam 回滚、run 记失败可重试", ctx do
    seed_source_object(ctx.src)
    put_daily_config(ctx)

    base_root = "reports/#{ctx.src}/daily"
    data_key = base_root <> "/data/rabort/pabort.csv.gz"
    symlink_key = base_root <> "/hive/dt=2026-06-30-00-00/rabort/symlink.txt"

    # 对象 2（symlink）的 metadata 事务注入 stale CAS 失败（对象 1 data 不受影响）
    arm_stale_metadata_perturbation(ctx.dest, symlink_key)

    summary =
      Report.run(bucket: ctx.src, id: "daily", now: @now, run_id: "rabort", file_id: "pabort")

    assert summary.reports_written == 0
    assert [%{reason: reason}] = summary.errors
    assert reason =~ "stale_journal"

    # 对象 1（data）：journal 已 finalized（metadata_committed 是 rollback 禁止线，不经
    # seam 回滚），随后被 cleanup_written_objects 以现状 delete 清理（bytes + PG 行）
    data_journal = journal_for(ctx.dest, data_key)
    assert data_journal.phase == "finalized"
    refute File.exists?(Path.join(final_dir(ctx, ctx.dest, data_key), "part.0"))
    assert {:error, :not_found} = Objects.get_version(ctx.dest, data_key, "null")

    # 对象 2（symlink）：seam 回滚（fresh 目标：epoch=rolled_back、PG 无行）
    symlink_journal = journal_for(ctx.dest, symlink_key)
    assert symlink_journal.phase == "rolled_back"
    assert {:error, :not_found} = Objects.get_version(ctx.dest, symlink_key, "null")

    assert {:ok, %ObjectEpoch{phase: "rolled_back"}} =
             Storage.current_epoch(target(ctx.dest, symlink_key))

    # 对象 3/4（checksum/manifest）从未写入
    assert journal_count(ctx.dest) == 2

    # run 记失败可重试：解除注入后重跑（新 run_id）成功
    Failpoint.disarm(:object_mutation_before_metadata_commit)

    retry =
      Report.run(bucket: ctx.src, id: "daily", now: @now, run_id: "rretry", file_id: "pretry")

    assert retry.errors == []
    assert retry.reports_written == 1
    assert retry.objects_written == 4
  end

  # ── 断言 6：:sidecar 写权威分支逐字节不变（D1 gate，经 storage_opts 注入）──

  test ":sidecar 写权威：publish 即权威提交、PG index best-effort、seam 零参与", ctx do
    seed_source_object(ctx.src)
    put_daily_config(ctx)

    summary =
      Report.run(
        bucket: ctx.src,
        id: "daily",
        now: @now,
        run_id: "rsc",
        file_id: "psc",
        storage_opts: [authoritative_source: [write: :sidecar]]
      )

    assert summary.errors == []
    assert summary.reports_written == 1
    assert summary.objects_written == 4

    report = hd(summary.reports)

    # bytes + sidecar 已权威落盘；PG best-effort 索引已写
    final = final_dir(ctx, ctx.dest, report.data_key)
    assert :zlib.gunzip(File.read!(Path.join(final, "part.0"))) =~ "docs%2Fa.txt"
    assert File.regular?(Path.join(final, "meta.json"))
    assert {:ok, %Objects.Object{}} = Objects.get_version(ctx.dest, report.data_key, "null")

    # seam 零参与：无 journal 行、无 epoch、无 durable backup（非协议路径逐字节不变）
    assert journal_count(ctx.dest) == 0
    assert {:ok, :absent} = Storage.current_epoch(target(ctx.dest, report.data_key))
    assert mutation_dirs(ctx) == []
  end

  # ── helpers ──

  defp seed_source_object(src) do
    {:ok, _} =
      Objects.put_version_with_id(src, "docs/a.txt", "null", %{size: 5, etag: "aetag"})
  end

  defp put_daily_config(ctx) do
    :ok =
      Inventory.put_config(ctx.src, %{
        "Id" => "daily",
        "Destination" => %{
          "S3BucketDestination" => %{
            "AccountId" => "000000000000",
            "Bucket" => "arn:aws:s3:::" <> ctx.dest,
            "Format" => "CSV",
            "Prefix" => "reports"
          }
        },
        "IsEnabled" => true,
        "IncludedObjectVersions" => "Current",
        "Schedule" => %{"Frequency" => "Daily"}
      })
  end

  # 在 publish 之后、metadata 事务之前扰动目标 journal（attempts+1）：事务 hook 内基于
  # 请求手中旧 journal 行的 CAS 必然 stale_journal → 整个 metadata 事务回滚
  # （put_object_mutation_e2e_test 同源注入手段）。仅命中指定 key，其余对象照常提交。
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
         case Repo.one(
                from j in Journal,
                  where:
                    j.bucket_name == ^bucket and j.object_key == ^key and j.phase == "published"
              ) do
           nil ->
             :ok

           journal ->
             {:ok, _} = ObjectMutation.mark_operational_error(journal, "c2_perturb")
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

  defp journals_for_bucket(bucket) do
    Repo.all(from j in Journal, where: j.bucket_name == ^bucket)
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
