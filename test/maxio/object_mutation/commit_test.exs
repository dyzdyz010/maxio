defmodule Maxio.ObjectMutation.CommitTest do
  @moduledoc """
  ObjectMutation Phase 1 B5 —— `Maxio.ObjectMutation.Commit` around-mutation seam 的
  数据面接线验收（FS 后端 tmp dir + 真实 PG journal/metadata）：

    1. 快乐路径五位一体：bytes/sidecar/PG row/journal(finalized)/epoch(committed)
       同一 token/fingerprint（协议测试矩阵第一行）；
    2. metadata_tx 抛异常：PG 无新行、旧字节恢复、journal/epoch rolled_back、backup 清空；
    3. metadata_committed 后 failpoint raise：禁回滚三层落点（状态图无边 +
       request_rollback 前置拒绝 + 端点 restore 拒 committed epoch），新字节保留；
    4. owner 在 publisher 注册前 DOWN：Control 持 discard callback 清 staged tmp；
    5. successor fence：A published 停住、B 完整走完，A 的 restore → :superseded 且
       B 的 final/epoch/PG 三态不变；
    6. journal CAS 失败 → metadata 事务回滚、PG 无半提交；
    7. `prepare(initial_backoff_ms:)` 的 journal 不出现在 list_due（recovery 宽限）；
    8. `transaction_hook/2` 共享组合器（Phase 2A C1）：journal=nil 直通、CAS 先行同事务、
       CAS 失败整体回滚且 extra 不执行。

  另锁死 `request_rollback/2` / `max_generation/2` 契约。全部同步用 monitor/assert_receive，
  零 Process.sleep（工程准则）。
  """

  use Maxio.DataCase, async: false

  alias Maxio.{Buckets, Objects, ObjectMutation, Storage}
  alias Maxio.Cluster.Paths
  alias Maxio.Failpoint
  alias Maxio.ObjectMutation.Commit
  alias Maxio.ObjectMutation.Journal
  alias Maxio.Storage.MutationBackup
  alias Maxio.Storage.MutationContext
  alias Maxio.Storage.ObjectEpoch

  @key "obj.bin"
  @fingerprint %{
    "etag" => "abc",
    "size" => 3,
    "sidecar_sha256" => String.duplicate("ab", 32)
  }

  setup do
    dir = Path.join(System.tmp_dir!(), "maxio_omc_#{System.unique_integer([:positive])}")
    File.rm_rf(dir)
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)

    bucket = "omc-#{System.unique_integer([:positive])}"
    {:ok, _bucket} = Buckets.create(bucket, "arn:aws:iam:::root")

    %{dir: dir, bucket: bucket}
  end

  # ── 断言 1：快乐路径五位一体 ──

  test "快乐路径：bytes/sidecar/PG/journal/epoch 同一 token 与 fingerprint", ctx do
    content = "protocol content v1"

    assert {:ok, %{journal: journal, published: published, metadata: object}} =
             protocol_put(ctx, content)

    # journal 终态 finalized，generation 从 1 起（无 legacy epoch/journal）
    journal = ObjectMutation.get(journal.id)
    assert journal.phase == "finalized"
    assert journal.generation == 1

    # bytes：final part.0 即新内容
    final = final_dir(ctx)
    assert File.read!(Path.join(final, "part.0")) == content

    # sidecar：final meta.json 字节 sha256 与 journal/epoch fingerprint 精确一致
    sidecar_bytes = File.read!(Path.join(final, "meta.json"))
    expected = ObjectEpoch.fingerprint(md5_hex(content), byte_size(content), sidecar_bytes)
    assert journal.published_fingerprint == expected
    assert published.epoch_fingerprint == expected

    # epoch：committed + 同一 token（generation/mutation_id）+ 同一 fingerprint
    assert {:ok, %ObjectEpoch{} = epoch} = Storage.current_epoch(target(ctx), data_dir: ctx.dir)
    assert epoch.phase == "committed"
    assert epoch.token == %{"generation" => journal.generation, "mutation_id" => journal.id}
    assert epoch.fingerprint == expected

    # PG row：同一 etag/size（metadata_tx 与 journal metadata_committed 同事务提交）
    assert {:ok, %Objects.Object{} = row} = Objects.get_metadata(ctx.bucket, @key)
    assert row.etag == md5_hex(content)
    assert row.size == byte_size(content)
    assert object.etag == row.etag
    assert not is_nil(journal.metadata_committed_at)
    assert not is_nil(journal.finalized_at)

    # finalize 已丢弃 durable backup
    assert mutation_dirs(ctx) == []
  end

  # ── 断言 2：metadata_tx 抛异常 → 完整回滚 ──

  test "metadata_tx 抛异常：PG 无新行、旧字节恢复、journal/epoch rolled_back、backup 清空", ctx do
    old = "old content"
    {:ok, _} = Storage.put(ctx.bucket, @key, "null", [old], data_dir: ctx.dir)

    assert_raise RuntimeError, "metadata boom", fn ->
      protocol_put(ctx, "new content",
        metadata_tx: fn _journal, _published, _write_info -> raise "metadata boom" end
      )
    end

    # 旧字节逐字恢复、PG 无行
    assert File.read!(Path.join(final_dir(ctx), "part.0")) == old
    assert {:error, :not_found} = Objects.get_metadata(ctx.bucket, @key)

    # journal 与 epoch 双双 rolled_back（同一 token）、durable backup 已清空
    journal = journal_for(ctx, @key)
    assert journal.phase == "rolled_back"
    assert {:ok, %ObjectEpoch{} = epoch} = Storage.current_epoch(target(ctx), data_dir: ctx.dir)
    assert epoch.phase == "rolled_back"
    assert epoch.token["mutation_id"] == journal.id
    assert mutation_dirs(ctx) == []
  end

  test "fresh metadata_tx 抛异常：PG 无行、journal/epoch rolled_back、backup 与 final 均不存在",
       ctx do
    assert_raise RuntimeError, "fresh metadata boom", fn ->
      protocol_put(ctx, "fresh content",
        metadata_tx: fn _journal, _published, _write_info -> raise "fresh metadata boom" end
      )
    end

    assert {:error, :not_found} = Objects.get_metadata(ctx.bucket, @key)

    journal = journal_for(ctx, @key)
    assert journal.phase == "rolled_back"

    assert {:ok, %ObjectEpoch{phase: "rolled_back", token: token}} =
             Storage.current_epoch(target(ctx), data_dir: ctx.dir)

    assert token["mutation_id"] == journal.id
    assert mutation_dirs(ctx) == []
    refute File.exists?(final_dir(ctx))
  end

  # ── 断言 3：metadata_committed 禁回滚三层落点 ──

  test "metadata_committed 后 failpoint raise：request_rollback 被拒、新字节保留、三层禁回滚", ctx do
    old = "old content"
    {:ok, _} = Storage.put(ctx.bucket, @key, "null", [old], data_dir: ctx.dir)

    Failpoint.arm(:object_mutation_after_metadata_commit, {:raise, "crash after pg commit"})
    on_exit(fn -> Failpoint.disarm(:object_mutation_after_metadata_commit) end)

    new_content = "new content"

    assert_raise RuntimeError, "crash after pg commit", fn ->
      protocol_put(ctx, new_content)
    end

    # journal 停在 metadata_committed（finalize 未执行）
    journal = journal_for(ctx, @key)
    assert journal.phase == "metadata_committed"

    # 层 1：@pg_graph 无 metadata_committed → rollback_pending 边
    assert {:error, {:illegal_transition, "metadata_committed", "rollback_pending"}} =
             ObjectMutation.transition(journal, "rollback_pending")

    # 层 2：request_rollback 前置拒绝（Control DOWN 加速器路径的守卫同此判定）
    assert {:error, {:illegal_transition, "metadata_committed", "rollback_pending"}} =
             ObjectMutation.request_rollback(journal)

    # 新字节保留 + PG 行在 + epoch 仍为我们的 published token + backup 保留（crash 取证）
    assert File.read!(Path.join(final_dir(ctx), "part.0")) == new_content
    assert {:ok, %Objects.Object{}} = Objects.get_metadata(ctx.bucket, @key)
    assert {:ok, %ObjectEpoch{} = epoch} = Storage.current_epoch(target(ctx), data_dir: ctx.dir)
    assert epoch.phase == "published"
    assert epoch.token["mutation_id"] == journal.id
    refute mutation_dirs(ctx) == []

    # 层 3：recovery 语义收敛（finalize）后，端点级 restore 拒绝 committed epoch
    assert {:ok, mutation_ctx} = MutationContext.from_journal(journal)
    assert {:ok, :finalized} = Storage.finalize_if_current(mutation_ctx, data_dir: ctx.dir)

    assert {:error, :epoch_committed} =
             Storage.restore_if_current(mutation_ctx, data_dir: ctx.dir)

    assert File.read!(Path.join(final_dir(ctx), "part.0")) == new_content
  end

  # ── 断言 4：owner DOWN（publisher 注册前）→ Control discard 生效 ──

  test "owner 在 publisher 注册前 DOWN：Control 持 staging discard callback 清 tmp", ctx do
    parent = self()

    {:ok, owner} =
      Task.start(fn ->
        Storage.put(ctx.bucket, @key, "null", ["never published"],
          data_dir: ctx.dir,
          around_object_commit: fn write_info, _publish ->
            send(parent, {:pre_publish, Map.fetch!(write_info, :object_commit_control)})

            receive do
              :never -> {:error, :never}
            end
          end
        )
      end)

    assert_receive {:pre_publish, control}, 5_000
    control_ref = Process.monitor(control)
    owner_ref = Process.monitor(owner)

    # staging 已落 .tmp（around 阻塞在 publish 之前，backend 尚未注册回滚/终结闭包）
    assert File.ls!(Path.join(ctx.dir, ".tmp")) != []

    Process.exit(owner, :kill)
    assert_receive {:DOWN, ^owner_ref, :process, ^owner, :killed}, 5_000
    assert_receive {:DOWN, ^control_ref, :process, ^control, :normal}, 5_000

    # Control 的 discard 已清 staged tmp（B2 审查项 1：用 File.ls 判空，不用 wildcard）
    assert File.ls!(Path.join(ctx.dir, ".tmp")) == []
  end

  # ── 断言 5：successor fence ──

  test "successor fence：A published 停住、B 完整走完，A restore :superseded 且 B 三态不变", ctx do
    parent = self()

    Failpoint.arm(
      :object_mutation_before_metadata_commit,
      {:fun,
       fn ->
         send(parent, {:a_paused, self()})

         receive do
           :die -> Process.exit(self(), :kill)
         end
       end}
    )

    on_exit(fn -> Failpoint.disarm(:object_mutation_before_metadata_commit) end)

    {:ok, a_owner} = Task.start(fn -> protocol_put(ctx, "content A", notify: parent) end)

    assert_receive {:write_info, %{object_commit_control: a_control}}, 5_000
    assert_receive {:a_paused, ^a_owner}, 5_000

    # A 已 published（journal + epoch 双 durable）；B 开跑前解除全局 failpoint
    Failpoint.disarm(:object_mutation_before_metadata_commit)
    a_journal = journal_for(ctx, @key)
    assert a_journal.phase == "published"

    # B 完整走完（claim 越过 A 的 published epoch：generation + 1）
    assert {:ok, %{journal: b_journal}} = protocol_put(ctx, "content B")
    b_journal = ObjectMutation.get(b_journal.id)
    assert b_journal.phase == "finalized"
    assert b_journal.generation == a_journal.generation + 1

    final = final_dir(ctx)
    assert File.read!(Path.join(final, "part.0")) == "content B"
    assert {:ok, %ObjectEpoch{} = b_epoch} = Storage.current_epoch(target(ctx), data_dir: ctx.dir)
    assert b_epoch.phase == "committed"
    assert b_epoch.token["mutation_id"] == b_journal.id
    assert {:ok, %Objects.Object{} = b_row} = Objects.get_metadata(ctx.bucket, @key)

    # A 的迟到 restore：只报告 superseded，绝不触碰 successor；A 的 backup 原地保留可取证
    assert {:ok, a_ctx} = MutationContext.from_journal(a_journal)
    assert {:ok, :superseded} = Storage.restore_if_current(a_ctx, data_dir: ctx.dir)

    a_backup = Path.join(ctx.dir, MutationBackup.relative_dir(a_journal.id))
    assert File.regular?(Path.join(a_backup, MutationBackup.manifest_name()))

    # B 三态（bytes/epoch/PG）不变
    assert File.read!(Path.join(final, "part.0")) == "content B"
    assert {:ok, ^b_epoch} = Storage.current_epoch(target(ctx), data_dir: ctx.dir)
    assert {:ok, %Objects.Object{etag: b_etag}} = Objects.get_metadata(ctx.bucket, @key)
    assert b_etag == b_row.etag

    # 杀死停住的 A：Control DOWN 经 guard（journal published → rollback_pending）+
    # best-effort restore（:superseded 折叠为 :ok），B 仍然不变
    a_owner_ref = Process.monitor(a_owner)
    a_control_ref = Process.monitor(a_control)
    send(a_owner, :die)
    assert_receive {:DOWN, ^a_owner_ref, :process, ^a_owner, :killed}, 5_000
    assert_receive {:DOWN, ^a_control_ref, :process, ^a_control, :normal}, 5_000

    a_after = ObjectMutation.get(a_journal.id)
    assert a_after.phase == "rollback_pending"
    assert File.read!(Path.join(final, "part.0")) == "content B"
    assert {:ok, ^b_epoch} = Storage.current_epoch(target(ctx), data_dir: ctx.dir)
  end

  # ── 断言 6：journal CAS 失败 → metadata 事务回滚 ──

  test "journal CAS 失败（并发扰动 attempts）→ metadata 事务回滚、PG 无半提交", ctx do
    old = "old content"
    {:ok, _} = Storage.put(ctx.bucket, @key, "null", [old], data_dir: ctx.dir)

    result =
      protocol_put(ctx, "new content",
        metadata_tx: fn journal, _published, write_info ->
          # 模拟并发恢复器扰动：attempts+1 → 事务 hook 内基于请求手中旧 journal 行的
          # CAS 必然失败 → Repo.rollback（整个 metadata 事务回滚）
          {:ok, _} = ObjectMutation.mark_error(journal, :concurrent_probe, %{"stage" => "test"})

          case Objects.put_version_with_id(
                 ctx.bucket,
                 @key,
                 "null",
                 %{size: write_info.size, etag: write_info.etag},
                 transaction_hook: fn repo, _obj ->
                   _ = Commit.commit_metadata_in_tx!(journal, repo)
                   %{}
                 end
               ) do
            {:ok, _} -> {:ok, :unexpected_commit}
            {:error, reason} -> {:error, reason}
          end
        end
      )

    assert {:error, {:object_mutation_metadata_commit_failed, {:stale_journal, "published", 1}}} =
             result

    # PG 无半提交、旧字节恢复、journal 收敛 rolled_back
    assert {:error, :not_found} = Objects.get_metadata(ctx.bucket, @key)
    assert File.read!(Path.join(final_dir(ctx), "part.0")) == old
    assert journal_for(ctx, @key).phase == "rolled_back"
  end

  # ── 断言 7：prepare 的 recovery 宽限 ──

  test "prepare(initial_backoff_ms: 60_000) 的 journal 不出现在 list_due", ctx do
    t0 = DateTime.utc_now()

    {:ok, journal} =
      ObjectMutation.prepare(prepare_attrs(ctx, "grace.bin", 1),
        now: t0,
        initial_backoff_ms: 60_000
      )

    assert DateTime.diff(journal.next_attempt_at, t0, :millisecond) == 60_000

    due_now = ObjectMutation.list_due(now: DateTime.add(t0, 1, :second))
    refute Enum.any?(due_now, &(&1.id == journal.id))

    due_later = ObjectMutation.list_due(now: DateTime.add(t0, 61, :second))
    assert Enum.any?(due_later, &(&1.id == journal.id))
  end

  # ── 断言 8（Phase 2A C1）：transaction_hook/2 共享组合器 ──

  describe "transaction_hook/2" do
    test "journal=nil 直通：extra 原样执行、无 extra 恒 :ok、journal 零参与", ctx do
      hook = Commit.transaction_hook(nil, fn _repo, obj -> {:extra_ran, obj.version_id} end)

      assert {:ok, {%Objects.Object{}, {:extra_ran, "null"}}} =
               Objects.put_version_with_id(
                 ctx.bucket,
                 "hook-nil.bin",
                 "null",
                 %{size: 1, etag: "e1"},
                 transaction_hook: hook
               )

      # 无 extra：恒 :ok（零 DB 参与，可直接调用）
      assert Commit.transaction_hook(nil).(Repo, :subject) == :ok

      # journal 表零参与（未迁移调用者行为逐字节不变的直通证据）
      target = %{bucket_name: ctx.bucket, object_key: "hook-nil.bin", version_id: "null"}
      assert ObjectMutation.max_generation(target) == 0
    end

    test "journal CAS 先行且与 PG row 同事务；extra 后行、其返回值即 hook 结果", ctx do
      journal = published_journal(ctx, "hook-tx.bin")

      hook =
        Commit.transaction_hook(journal, fn repo, _obj ->
          # extra 执行时 journal 已在同一事务连接内推进 metadata_committed（CAS 先行）
          assert %Journal{phase: "metadata_committed"} = repo.get(Journal, journal.id)
          :extra_result
        end)

      assert {:ok, {%Objects.Object{}, :extra_result}} =
               Objects.put_version_with_id(
                 ctx.bucket,
                 "hook-tx.bin",
                 "null",
                 %{size: 1, etag: "e2"},
                 transaction_hook: hook
               )

      committed = ObjectMutation.get(journal.id)
      assert committed.phase == "metadata_committed"
      assert not is_nil(committed.metadata_committed_at)
    end

    test "journal + 无 extra：hook 返回 :ok、journal 照常推进", ctx do
      journal = published_journal(ctx, "hook-noextra.bin")

      assert {:ok, {%Objects.Object{}, :ok}} =
               Objects.put_version_with_id(
                 ctx.bucket,
                 "hook-noextra.bin",
                 "null",
                 %{size: 1, etag: "e3"},
                 transaction_hook: Commit.transaction_hook(journal)
               )

      assert ObjectMutation.get(journal.id).phase == "metadata_committed"
    end

    test "CAS 失败（并发扰动）→ 整个 metadata 事务回滚、PG 无半提交、extra 不执行", ctx do
      journal = published_journal(ctx, "hook-cas.bin")

      # 模拟并发恢复器扰动：attempts+1 → 手中旧 journal 行的 CAS 必然 stale
      {:ok, _} = ObjectMutation.mark_error(journal, :concurrent_probe, %{"stage" => "test"})

      parent = self()

      hook =
        Commit.transaction_hook(journal, fn _repo, _obj ->
          send(parent, :extra_ran)
          :never
        end)

      assert {:error, {:object_mutation_metadata_commit_failed, {:stale_journal, "published", 1}}} =
               Objects.put_version_with_id(
                 ctx.bucket,
                 "hook-cas.bin",
                 "null",
                 %{size: 1, etag: "e4"},
                 transaction_hook: hook
               )

      # extra 从未执行（CAS 失败即 repo.rollback 抛出）、PG 无半提交、journal 未被误动
      refute_received :extra_ran
      assert {:error, :not_found} = Objects.get_metadata(ctx.bucket, "hook-cas.bin")
      assert ObjectMutation.get(journal.id).phase == "published"
    end
  end

  # ── request_rollback / max_generation 契约 ──

  describe "request_rollback/2" do
    test "prepared/claimed/published → rollback_pending 且 next_attempt_at=now；幂等分支", ctx do
      {:ok, journal} = ObjectMutation.prepare(prepare_attrs(ctx, "rr.bin", 1))
      t = DateTime.utc_now()

      assert {:ok, pending} = ObjectMutation.request_rollback(journal, now: t)
      assert pending.phase == "rollback_pending"
      assert DateTime.compare(pending.next_attempt_at, t) == :eq

      # rollback_pending / rolled_back 幂等
      assert {:ok, %Journal{phase: "rollback_pending"}} = ObjectMutation.request_rollback(pending)
      assert {:ok, rolled} = ObjectMutation.transition(pending, "rolled_back")
      assert {:ok, %Journal{phase: "rolled_back"}} = ObjectMutation.request_rollback(rolled)
    end

    test "metadata_committed 及之后（含 finalize_pending/finalized/quarantined）一律拒绝", ctx do
      {:ok, journal} = ObjectMutation.prepare(prepare_attrs(ctx, "rr2.bin", 1))
      {:ok, journal} = ObjectMutation.transition(journal, "claimed")

      {:ok, journal} =
        ObjectMutation.transition(journal, "published", %{published_fingerprint: @fingerprint})

      {:ok, committed} = ObjectMutation.transition(journal, "metadata_committed")

      assert {:error, {:illegal_transition, "metadata_committed", "rollback_pending"}} =
               ObjectMutation.request_rollback(committed)

      {:ok, pending} = ObjectMutation.transition(committed, "finalize_pending")

      assert {:error, {:illegal_transition, "finalize_pending", "rollback_pending"}} =
               ObjectMutation.request_rollback(pending)

      {:ok, finalized} = ObjectMutation.transition(pending, "finalized")

      assert {:error, {:illegal_transition, "finalized", "rollback_pending"}} =
               ObjectMutation.request_rollback(finalized)

      {:ok, other} = ObjectMutation.prepare(prepare_attrs(ctx, "rr3.bin", 1))
      {:ok, quarantined} = ObjectMutation.quarantine(other, :test, %{"why" => "test"})

      assert {:error, {:illegal_transition, "quarantined", "rollback_pending"}} =
               ObjectMutation.request_rollback(quarantined)
    end
  end

  test "max_generation/2 按 target 取 journal 最大 generation（无记录 → 0）", ctx do
    target = %{bucket_name: ctx.bucket, object_key: "gen.bin", version_id: "null"}
    assert ObjectMutation.max_generation(target) == 0

    {:ok, _} = ObjectMutation.prepare(prepare_attrs(ctx, "gen.bin", 3))
    {:ok, _} = ObjectMutation.prepare(prepare_attrs(ctx, "gen.bin", 7))
    assert ObjectMutation.max_generation(target) == 7

    # 不同 version_id 是不同 target
    assert ObjectMutation.max_generation(%{target | version_id: "v-other"}) == 0
  end

  # ── helpers ──

  # 经真实 Storage.put + ObjectCommit seam 驱动协议化提交（与 handler around 同形）。
  defp protocol_put(ctx, content, opts \\ []) do
    bucket = ctx.bucket
    key = Keyword.get(opts, :key, @key)
    notify = Keyword.get(opts, :notify)
    metadata_tx = Keyword.get(opts, :metadata_tx, &default_metadata_tx(bucket, key, &1, &2, &3))

    Storage.put(bucket, key, "null", [content],
      data_dir: ctx.dir,
      around_object_commit: fn write_info, publish ->
        if notify, do: send(notify, {:write_info, write_info})

        Commit.run(%{
          bucket: bucket,
          key: key,
          version_id: "null",
          operation: "put",
          authority_mode: "pg",
          storage_opts: [data_dir: ctx.dir],
          write_info: write_info,
          publish: fn extra_commit_opts ->
            publish.(Keyword.merge([version_id: "null", object_meta: %{}], extra_commit_opts))
          end,
          metadata_tx: fn journal, published ->
            metadata_tx.(journal, published, write_info)
          end
        })
      end
    )
  end

  # 与 handler 同形的 metadata 事务：put_version_with_id + transaction_hook 内
  # commit_metadata_in_tx!（journal metadata_committed 与 PG row 同事务）。
  defp default_metadata_tx(bucket, key, journal, _published, write_info) do
    case Objects.put_version_with_id(
           bucket,
           key,
           "null",
           %{size: write_info.size, etag: write_info.etag},
           transaction_hook: fn repo, _obj ->
             _ = Commit.commit_metadata_in_tx!(journal, repo)
             %{}
           end
         ) do
      {:ok, {object, _hook_result}} -> {:ok, object}
      {:ok, object} -> {:ok, object}
      {:error, reason} -> {:error, reason}
    end
  end

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

  # 直接构造 published journal（transaction_hook/2 单测用：只验 journal CAS 与 PG 事务
  # 的组合语义，不经 backend publish）。
  defp published_journal(ctx, key) do
    {:ok, journal} = ObjectMutation.prepare(prepare_attrs(ctx, key, 1))
    {:ok, journal} = ObjectMutation.transition(journal, "claimed")

    {:ok, journal} =
      ObjectMutation.transition(journal, "published", %{published_fingerprint: @fingerprint})

    journal
  end

  defp target(ctx) do
    {:ok, target} = ObjectEpoch.object_target(ctx.bucket, @key, "null")
    target
  end

  defp final_dir(ctx) do
    {:ok, rel} = Paths.object_rel(ctx.bucket, @key, "null")
    Path.join(ctx.dir, rel)
  end

  defp journal_for(ctx, key) do
    Repo.one!(
      from j in Journal,
        where: j.bucket_name == ^ctx.bucket and j.object_key == ^key,
        order_by: [desc: j.generation],
        limit: 1
    )
  end

  # durable mutation backup 根下的残留目录（不存在视为空；File.ls 判空，B2 审查项 1）。
  defp mutation_dirs(ctx) do
    case File.ls(Path.join(ctx.dir, ".maxio-object-mutations")) do
      {:ok, entries} -> entries
      {:error, :enoent} -> []
    end
  end

  defp md5_hex(content), do: :crypto.hash(:md5, content) |> Base.encode16(case: :lower)
end
