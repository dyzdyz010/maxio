defmodule Mix.Tasks.MaxioObjectMutationsTest do
  @moduledoc """
  ObjectMutation Phase 1 B7 —— status / recover CLI 验收（协议 §7）：

    1. status 对 finalize_pending journal 建议 finalize、对孤儿 published 建议 restore，
       并展示 journal phase / epoch quorum 逐 endpoint 读数 / placement snapshot /
       backup manifest 存在性；
    2. recover 默认与 `--dry-run` 零副作用（DB/磁盘前后快照相等）；
    3. `--execute --mutation-id` 经 `Recovery.recover/2` 同一入口收敛单条；
    4. `--older-than` 只处理创建超过给定年龄的记录（`list_due` 的 older_than_ms 落点）；
    5. 非法参数 fail-closed。
  """

  use Maxio.DataCase, async: false

  import ExUnit.CaptureIO

  alias Maxio.{Buckets, ObjectMutation}
  alias Maxio.ObjectMutation.Journal
  alias Maxio.Storage.{EpochStore, MutationBackup, MutationContext, ObjectEpoch}
  alias Mix.Tasks.Maxio.ObjectMutations.Recover, as: RecoverTask
  alias Mix.Tasks.Maxio.ObjectMutations.Status, as: StatusTask

  @fingerprint %{
    "etag" => "abc",
    "size" => 3,
    "sidecar_sha256" => String.duplicate("ab", 32)
  }

  setup do
    dir = Path.join(System.tmp_dir!(), "maxio_om_cli_#{System.unique_integer([:positive])}")
    File.rm_rf(dir)
    File.mkdir_p!(dir)

    # CLI 无 storage_opts 注入口（生产语义）：FS data_dir 走 config :maxio, :s3。
    prev_s3 = Application.get_env(:maxio, :s3, [])
    Application.put_env(:maxio, :s3, Keyword.put(prev_s3, :data_dir, dir))

    on_exit(fn ->
      Application.put_env(:maxio, :s3, prev_s3)
      File.rm_rf(dir)
    end)

    bucket = "omcli-#{System.unique_integer([:positive])}"
    {:ok, _bucket} = Buckets.create(bucket, "arn:aws:iam:::root")

    %{dir: dir, bucket: bucket}
  end

  # ── status ──

  test "status：finalize_pending journal 建议 finalize，展示 epoch 逐 endpoint 读数与 manifest",
       ctx do
    {:ok, journal} = finalize_pending_journal(ctx, "fin.bin")
    mctx = write_epoch!(ctx, journal, "published", @fingerprint)
    write_backup_manifest!(ctx, mctx)

    output =
      capture_io(fn ->
        StatusTask.run(["--bucket", ctx.bucket, "--key", "fin.bin"])
      end)

    assert output =~ "[maxio object_mutations.status] mutations=1"
    assert output =~ "mutation_id=#{journal.id} phase=finalize_pending"
    assert output =~ "authority_mode=pg"
    assert output =~ "epoch_quorum=1"
    assert output =~ "status=ok generation=#{journal.generation} mutation_id=#{journal.id}"
    assert output =~ "phase=published"
    assert output =~ "backup_dir=#{inspect(MutationBackup.relative_dir(journal.id))}"
    assert output =~ "manifest=true"
    assert output =~ "suggested_action=finalize:"
    assert output =~ "mix maxio.object_mutations.recover --execute --mutation-id #{journal.id}"
  end

  test "status：孤儿 published journal 建议 restore；--mutation-id --json 单条结构化输出",
       ctx do
    {:ok, journal} = published_journal(ctx, "orphan.bin")
    write_epoch!(ctx, journal, "published", @fingerprint)

    output =
      capture_io(fn ->
        StatusTask.run(["--mutation-id", journal.id, "--json"])
      end)

    assert %{"count" => 1, "mutations" => [view]} = Jason.decode!(output)
    assert view["mutation_id"] == journal.id
    assert view["phase"] == "published"
    assert view["suggested_action"] =~ "restore (rollback"
    assert view["suggested_action"] =~ journal.id
    assert view["epoch"]["epoch_quorum"] == 1

    assert [%{"status" => "ok", "generation" => 1, "phase" => "published"} = reading] =
             view["epoch"]["endpoints"]

    assert reading["mutation_id"] == journal.id
    assert view["backup"]["relative_dir"] == MutationBackup.relative_dir(journal.id)
    assert [%{"manifest" => false}] = view["backup"]["endpoints"]
  end

  test "status：epoch absent 显式 absent 读数；quarantined 建议操作员裁决", ctx do
    {:ok, journal} = ObjectMutation.prepare(prepare_attrs(ctx, "quar.bin", 1))

    {:ok, quarantined} =
      ObjectMutation.quarantine(journal, :evidence_conflict, %{"stage" => "test"})

    output =
      capture_io(fn ->
        StatusTask.run(["--mutation-id", quarantined.id])
      end)

    assert output =~ "phase=quarantined"
    assert output =~ "status=absent"
    assert output =~ "suggested_action=operator adjudication required"
    refute output =~ "recover --execute"
  end

  # B6 审查项 2：attempts 超阈值的持久可重试错误（典型 EC 少数盘 {:partial,_}）——
  # status 建议动作升级为操作员裁决口径，而非继续机械重试。
  test "status：attempts 超阈值的 partial 重试给出操作员裁决口径", ctx do
    {:ok, journal} = published_journal(ctx, "stuck.bin")

    journal =
      Enum.reduce(1..5, journal, fn _i, acc ->
        {:ok, marked} =
          ObjectMutation.mark_error(acc, {:partial, %{applied: 3}}, %{"stage" => "restore"})

        marked
      end)

    assert journal.attempts == 5

    output = capture_io(fn -> StatusTask.run(["--mutation-id", journal.id]) end)

    assert output =~ "suggested_action=stuck retryable error after 5 attempts"
    assert output =~ "operator adjudication"
    assert output =~ "mix maxio.object_mutations.recover --execute --mutation-id #{journal.id}"
  end

  test "status：非法参数 fail-closed", ctx do
    assert_raise Mix.Error, ~r/usage: mix maxio\.object_mutations\.status/, fn ->
      StatusTask.run(["--bad"])
    end

    assert_raise Mix.Error, ~r/--key requires --bucket/, fn ->
      StatusTask.run(["--key", "k"])
    end

    assert_raise Mix.Error, ~r/--mutation-id must be a UUID/, fn ->
      StatusTask.run(["--mutation-id", "not-a-uuid"])
    end

    assert_raise Mix.Error, ~r/object mutation not found/, fn ->
      StatusTask.run(["--mutation-id", Ecto.UUID.generate()])
    end

    _ = ctx
  end

  # ── recover ──

  test "recover 默认/--dry-run：列出决策方向，DB 与磁盘前后快照相等（零副作用）", ctx do
    {:ok, rollback_journal} = ObjectMutation.prepare(prepare_attrs(ctx, "roll.bin", 1))
    {:ok, finalize_journal} = metadata_committed_journal(ctx, "final.bin")
    mctx = write_epoch!(ctx, finalize_journal, "published", @fingerprint)
    write_backup_manifest!(ctx, mctx)

    db_before = journal_snapshot()
    disk_before = dir_snapshot(ctx.dir)

    output = capture_io(fn -> RecoverTask.run(["--dry-run"]) end)

    assert output =~ "dry_run=true due=2"
    assert output =~ "would_recover mutation_id=#{rollback_journal.id}"
    assert output =~ "decision=rollback"
    assert output =~ "would_recover mutation_id=#{finalize_journal.id}"
    assert output =~ "decision=finalize"

    # 缺省（无 --execute）等价 dry-run
    default_output = capture_io(fn -> RecoverTask.run([]) end)
    assert default_output =~ "dry_run=true due=2"

    assert journal_snapshot() == db_before
    assert dir_snapshot(ctx.dir) == disk_before
  end

  test "recover --dry-run --limit N：只列出前 N 条", ctx do
    {:ok, _j1} = ObjectMutation.prepare(prepare_attrs(ctx, "lim1.bin", 1))
    {:ok, _j2} = ObjectMutation.prepare(prepare_attrs(ctx, "lim2.bin", 1))

    output = capture_io(fn -> RecoverTask.run(["--dry-run", "--limit", "1"]) end)

    assert output =~ "dry_run=true due=1"
    assert length(String.split(output, "would_recover", trim: true)) == 2
  end

  test "recover --execute --mutation-id：经 Recovery 同一入口收敛单条", ctx do
    {:ok, journal} = ObjectMutation.prepare(prepare_attrs(ctx, "one.bin", 1))

    output =
      capture_io(fn ->
        RecoverTask.run(["--execute", "--mutation-id", journal.id])
      end)

    assert output =~ "executed=true mutation_id=#{journal.id} phase=rolled_back"
    assert ObjectMutation.get(journal.id).phase == "rolled_back"
  end

  test "recover --execute --older-than：只处理创建超过给定年龄的记录", ctx do
    {:ok, old_journal} = ObjectMutation.prepare(prepare_attrs(ctx, "old.bin", 1))
    {:ok, fresh_journal} = ObjectMutation.prepare(prepare_attrs(ctx, "fresh.bin", 1))

    backdated = DateTime.add(DateTime.utc_now(), -7200, :second)

    {1, _} =
      Repo.update_all(
        from(j in Journal, where: j.id == ^old_journal.id),
        set: [inserted_at: backdated]
      )

    output =
      capture_io(fn ->
        RecoverTask.run(["--execute", "--older-than", "3600"])
      end)

    assert output =~ "executed=true claimed=1"
    assert output =~ "rolled_back=1"
    assert ObjectMutation.get(old_journal.id).phase == "rolled_back"
    assert ObjectMutation.get(fresh_journal.id).phase == "prepared"
  end

  test "recover：非法参数 fail-closed（零副作用）", ctx do
    {:ok, journal} = ObjectMutation.prepare(prepare_attrs(ctx, "guard.bin", 1))

    assert_raise Mix.Error, ~r/usage: mix maxio\.object_mutations\.recover/, fn ->
      RecoverTask.run(["--bad"])
    end

    assert_raise Mix.Error, ~r/mutually exclusive/, fn ->
      RecoverTask.run(["--dry-run", "--execute"])
    end

    assert_raise Mix.Error, ~r/--mutation-id requires --execute/, fn ->
      RecoverTask.run(["--mutation-id", journal.id])
    end

    assert_raise Mix.Error, ~r/--older-than must be a positive integer/, fn ->
      RecoverTask.run(["--dry-run", "--older-than", "0"])
    end

    assert_raise Mix.Error, ~r/--mutation-id must be a UUID/, fn ->
      RecoverTask.run(["--execute", "--mutation-id", "nope"])
    end

    assert ObjectMutation.get(journal.id).phase == "prepared"
  end

  # ── helpers ──

  defp prepare_attrs(ctx, key, generation) do
    %{
      target_kind: "object_version",
      bucket_name: ctx.bucket,
      object_key: key,
      version_id: "null",
      generation: generation,
      operation: "put",
      authority_mode: "pg",
      backend: "Maxio.Storage.FS"
    }
  end

  defp published_journal(ctx, key, generation \\ 1) do
    {:ok, journal} = ObjectMutation.prepare(prepare_attrs(ctx, key, generation))
    {:ok, journal} = ObjectMutation.transition(journal, "claimed")
    ObjectMutation.transition(journal, "published", %{published_fingerprint: @fingerprint})
  end

  defp metadata_committed_journal(ctx, key) do
    {:ok, journal} = published_journal(ctx, key)
    ObjectMutation.transition(journal, "metadata_committed")
  end

  defp finalize_pending_journal(ctx, key) do
    {:ok, journal} = metadata_committed_journal(ctx, key)
    ObjectMutation.transition(journal, "finalize_pending")
  end

  # 直接写 durable epoch（构造盘上事实；claim expect 不约束 phase）。
  defp write_epoch!(ctx, journal, phase, fingerprint) do
    {:ok, mctx} = MutationContext.from_journal(journal)

    attrs = %{
      operation: "put",
      phase: phase,
      value_type: "object",
      updated_at: DateTime.utc_now()
    }

    attrs = if fingerprint, do: Map.put(attrs, :fingerprint, fingerprint), else: attrs
    {:ok, epoch} = ObjectEpoch.new(mctx.target, mctx.token, attrs)
    {:ok, :applied} = EpochStore.cas(ctx.dir, epoch, {:claim, mctx.token})
    mctx
  end

  defp write_backup_manifest!(ctx, mctx) do
    {:ok, manifest} = MutationBackup.manifest(mctx.target, mctx.token, nil, [])
    {:ok, bytes} = MutationBackup.encode(manifest)
    dir = Path.join(ctx.dir, MutationBackup.relative_dir(mctx.mutation_id))
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, MutationBackup.manifest_name()), bytes)
  end

  defp journal_snapshot do
    Repo.all(from j in Journal, order_by: j.id)
    |> Enum.map(
      &Map.take(&1, [
        :id,
        :phase,
        :attempts,
        :lease_owner,
        :lease_expires_at,
        :next_attempt_at,
        :last_error,
        :recovery_evidence,
        :updated_at
      ])
    )
  end

  # 磁盘快照：相对路径 → 内容摘要（--dry-run 零副作用断言）。
  defp dir_snapshot(root) do
    root
    |> collect_files()
    |> Enum.map(fn path ->
      {Path.relative_to(path, root), :erlang.md5(File.read!(path))}
    end)
    |> Enum.sort()
  end

  defp collect_files(path) do
    cond do
      File.regular?(path) ->
        [path]

      File.dir?(path) ->
        path
        |> File.ls!()
        |> Enum.sort()
        |> Enum.flat_map(&collect_files(Path.join(path, &1)))

      true ->
        []
    end
  end
end
