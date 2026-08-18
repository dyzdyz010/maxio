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

  import ExUnit.CaptureLog

  alias Maxio.{Buckets, Objects, ObjectMutation, Storage}
  alias Maxio.Cluster.Paths
  alias Maxio.Failpoint
  alias Maxio.ObjectMutation.Commit
  alias Maxio.ObjectMutation.Journal
  alias Maxio.Storage.MutationBackup
  alias Maxio.Storage.MutationContext
  alias Maxio.Storage.ObjectEpoch
  alias Maxio.Storage.PublishedProof
  alias Maxio.Test.StoragePublishedProofScriptBackend, as: Script

  @key "obj.bin"
  @fingerprint %{
    "etag" => "abc",
    "size" => 3,
    "sidecar_sha256" => String.duplicate("ab", 32)
  }

  # ── G2 Green review correction R1 冻结常量 ──
  #
  # marker 1：metadata 事务期间持久化的畸形 wrapper 标记，必须逐字保留。
  # marker 2：只由通过 Storage validator 的 finalize 结果携带的 callback-only raw
  #           sentinel，绝不放进畸形 wrapper，也绝不出现在结果 / journal / 日志里。
  @correction_wrapper_marker "g2r1_malformed_wrapper_marker"
  @correction_callback_sentinel "g2r1_callback_raw_sentinel"
  @correction_probe_code "g2r1_concurrent_probe"
  @correction_winner_code "g2r1_terminal_winner"
  @correction_write_loss_code "object_mutation_finalize:durable_outcome_write_failed"
  @correction_internal_envelope {:object_mutation_journal, :internal, :finalize_outcome}
  @correction_capture_opts [
    format: "$metadata$message\n",
    metadata: [:action, :outcome, :reason, :mutation_phase]
  ]

  # ── G2 Green review correction R2 冻结常量 ──
  #
  # marker 3：只由 metadata-committed 竞争者写进 journal 的 raw sentinel。它必须真实存在于
  # 被冻结的赢家证据里，同时绝不出现在请求结果（固定外部信封）与结构化日志里。
  @correction_metadata_winner_sentinel "g2r2_metadata_winner_raw_sentinel"

  # AST 所有权 oracle 的冻结签名：签名 = `{函数名, [各头部实参的 tag]}`，
  # tag 只取模式的构造标签（消费者），故与格式化/注释完全无关。
  @accelerate_producer_signature {:outcome_result, [:converged, {:success, :accelerate}]}

  @accelerate_policy_signatures [
    {:handle_finalize, [:finalized, :_]},
    {:handle_finalize, [:cleanup_pending, :_]}
  ]

  @accelerate_carrier_signatures [
    {:outcome_result, [:converged, {:success, :accelerate}]},
    {:handle_finalize, [:finalized, :_]},
    {:handle_finalize, [:cleanup_pending, :_]}
  ]

  # 必须真实存在于 commit.ex、但绝不允许携带任何 accelerator 的子句。
  @accelerate_forbidden_signatures [
    {:handle_finalize, [:retryable_failure, :_]},
    {:handle_finalize, [:integrity_failure, :_]},
    {:handle_finalize, [:superseded, :_]},
    {:handle_finalize, [{:contract_violation, :finalize}, :_]},
    {:finalize_contract_violation, [:_]},
    {:orchestration_failpoint, [:_]},
    # 【R2 I1】fence 与 already-finalized 捷径是**两个**独立签名，各自单独点名，
    # 因此删掉 already-finalized 子句会直接让 exactly-once 断言失败。
    {:finalize_phase, [:_, :_, :_]},
    {:finalize_phase, [:_, {:struct, :Journal, "finalized"}, :_]}
  ]

  # 纯内存反例骨架：与真实 commit.ex 同构的最小所有权模型。两个反例只改这里的
  # superseded 子句，绝不改动仓库里的任何文件。
  @accelerator_control_superseded """
    defp handle_finalize({:superseded, _summary}, journal),
      do: seam_outcome(journal, terminal_intent(), {:error, :superseded})
  """

  @accelerator_control_source """
  defmodule AcceleratorControl do
    defp outcome_result({:converged, row}, {:success, :accelerate}),
      do: {:request_ok, row, :accelerate}

    defp outcome_result({:converged, row}, {:success, :defer}), do: {:request_ok, row, :defer}

    defp outcome_result({:incompatible, row}, _semantics), do: {:request_error, :internal, row}

    defp request_result({:request_ok, journal, :accelerate}, plan) do
      accelerate_mark_committed(plan, journal)
      :ok
    end

    defp handle_finalize({:finalized, _summary}, journal),
      do: seam_outcome(journal, terminal_intent(), {:success, :accelerate})

    defp handle_finalize({:cleanup_pending, _summary}, journal),
      do: seam_outcome(journal, mark_error_intent(), {:success, :accelerate})

  #{@accelerator_control_superseded}
    defp finalize_phase(journal), do: {:request_ok, journal, :defer}
  end
  """

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
    assert {:error, :invalid_rollback_evidence} =
             ObjectMutation.request_rollback(journal, %{})

    # 新字节保留 + PG 行在 + epoch 仍为我们的 published token + backup 保留（crash 取证）
    assert File.read!(Path.join(final_dir(ctx), "part.0")) == new_content
    assert {:ok, %Objects.Object{}} = Objects.get_metadata(ctx.bucket, @key)
    assert {:ok, %ObjectEpoch{} = epoch} = Storage.current_epoch(target(ctx), data_dir: ctx.dir)
    assert epoch.phase == "published"
    assert epoch.token["mutation_id"] == journal.id
    refute mutation_dirs(ctx) == []

    # 层 3：recovery 语义收敛（finalize）后，端点级 restore 拒绝 committed epoch
    assert {:ok, mutation_ctx} = MutationContext.from_journal(journal)

    # G2 §4.7 授权的机械迁移 1/2：Task 2 已把 finalize 契约从退役的 atom 结果换成精确的
    # 嵌套 union。只迁移这一条断言的形状，全部业务断言保持不变。
    assert {:ok, {:finalized, _summary}} =
             Storage.finalize_if_current(mutation_ctx, data_dir: ctx.dir)

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
          #
          # G2 §4.7 授权的机械迁移 2/2：改用**保留取证**的 mark_operational_error/2。
          # 它同样只把 attempts 加一并造成同一个 stale metadata CAS，但绝不覆写
          # G2 之后 published 行上的 canonical successful proof wrapper；旧的 legacy
          # mark_error/4 会把该 wrapper 换成 generic evidence，从而伪造出一个 G1 必须
          # 拒绝的 published 源状态。全部业务断言保持不变。
          {:ok, _} = ObjectMutation.mark_operational_error(journal, "concurrent_probe")

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

  describe "request_rollback/3" do
    test "prepared/claimed/published → rollback_pending 且 next_attempt_at=now；幂等分支", ctx do
      {:ok, journal} = ObjectMutation.prepare(prepare_attrs(ctx, "rr.bin", 1))
      t = DateTime.utc_now()

      assert {:ok, pending} = ObjectMutation.request_rollback(journal, %{}, now: t)
      assert pending.phase == "rollback_pending"
      assert DateTime.compare(pending.next_attempt_at, t) == :eq

      # rollback_pending / rolled_back 幂等
      assert {:ok, %Journal{phase: "rollback_pending"}} =
               ObjectMutation.request_rollback(pending, %{})

      assert {:ok, rolled} = ObjectMutation.transition(pending, "rolled_back")
      assert {:ok, %Journal{phase: "rolled_back"}} = ObjectMutation.request_rollback(rolled, %{})
    end

    test "metadata_committed 及之后（含 finalize_pending/finalized/quarantined）一律拒绝", ctx do
      {:ok, journal} = ObjectMutation.prepare(prepare_attrs(ctx, "rr2.bin", 1))
      {:ok, journal} = ObjectMutation.transition(journal, "claimed")

      {:ok, journal} =
        ObjectMutation.transition(journal, "published", %{published_fingerprint: @fingerprint})

      {:ok, committed} = ObjectMutation.transition(journal, "metadata_committed")

      # attrs-map API 把非法 authority/phase 统一收敛为精确的 :invalid_rollback_evidence
      # （design D6 / Task 3 Step 2）；低层 transition/4 仍保留 illegal_transition。
      assert {:error, :invalid_rollback_evidence} =
               ObjectMutation.request_rollback(committed, %{})

      assert {:error, {:illegal_transition, "metadata_committed", "rollback_pending"}} =
               ObjectMutation.transition(committed, "rollback_pending")

      {:ok, pending} = ObjectMutation.transition(committed, "finalize_pending")

      assert {:error, :invalid_rollback_evidence} =
               ObjectMutation.request_rollback(pending, %{})

      {:ok, finalized} = ObjectMutation.transition(pending, "finalized")

      assert {:error, :invalid_rollback_evidence} =
               ObjectMutation.request_rollback(finalized, %{})

      {:ok, other} = ObjectMutation.prepare(prepare_attrs(ctx, "rr3.bin", 1))
      {:ok, quarantined} = ObjectMutation.quarantine(other, :test, %{"why" => "test"})

      assert {:error, :invalid_rollback_evidence} =
               ObjectMutation.request_rollback(quarantined, %{})
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

  # ── Task 3 / G2 §4.5–§4.6：proof ordering + finalize disposition RED ──
  #
  # 这些用例经**测试私有**的脚本 backend 驱动真实 Commit 编排，冻结「当前旧行为」的精确
  # 签名。旧生产在 publish 之后**从不**调用 `Storage.verify_published/2`，直接把 journal
  # 写成只有 fingerprint 的 `published`，并用退役的 atom finalize 适配器收口；因此下面
  # 每一条都是真实 RED，而不是能力缺失。
  #
  # 诚实边界（合同 §4.2）：finalize 的记录只观察 Commit 发起的**直接**
  # `Storage.finalize_if_current/2` 调用，绝不观察 publish 期间注册进 `ObjectCommit.Control`
  # 的、由冻结 backend 拥有的 finalize 闭包。`accelerate_mark_committed/2` 的调用次数经
  # 授权 seam 不可观察，故此处只断言可观察的 journal 动作与请求结果，不伪造 accelerator 计数。

  describe "G2 proof ordering and finalize disposition" do
    setup ctx do
      previous = Application.fetch_env!(:maxio, :storage_backend)
      Application.put_env(:maxio, :storage_backend, Script)
      on_exit(fn -> Application.put_env(:maxio, :storage_backend, previous) end)

      start_supervised!(Script)
      Map.put(ctx, :previous_backend, previous)
    end

    # G2 correction §4：用**双 gate** 确定性地证明精确时序
    #   backend publish → verify → 原子 journal published(fingerprint + wrapper) → metadata
    # 而不是事后只数一次调用次数。无 sleep、无轮询，只用消息与 script gate。
    @tag :task3_g2_commit_red
    test "g2 red: publish then verify then atomic published journal then metadata", ctx do
      owner = self()
      verify_ref = make_ref()
      metadata_ref = make_ref()

      Script.script(:verify_published, {:gate, owner, verify_ref, :delegate})

      task =
        Task.async(fn ->
          protocol_put(ctx, "two gate content",
            publish_observer: fn extra ->
              send(owner, {:publish_observed, Keyword.fetch!(extra, :object_mutation)})
            end,
            metadata_tx: gated_metadata_tx(owner, metadata_ref, ctx.bucket, @key)
          )
        end)

      # publish 闭包的真实输入 = claimed context。
      assert_receive {:publish_observed, %MutationContext{} = _claimed_ctx}, 5_000

      # ── gate 1：verify ──
      entered = await_gate!(verify_ref, "verify_published")
      assert entered.operation == :verify_published
      assert entered.ref == verify_ref
      assert is_pid(entered.caller)
      assert Keyword.fetch!(entered.opts, :data_dir) == ctx.dir
      assert %MutationContext{} = verify_ctx = entered.ctx

      # verify 必须已经拿到 publish 返回的非 nil fingerprint。
      refute is_nil(verify_ctx.published_fingerprint),
             "verify 必须收到 publish 返回的 fingerprint"

      # 此刻 journal 仍是 claimed，metadata 尚未进入。
      assert journal_for(ctx, @key).phase == "claimed",
             "verify 之前绝不能把 journal 写成 published"

      refute_received {:metadata_entered, ^metadata_ref, _pid, _journal}

      send(entered.caller, {:script_backend_release, verify_ref})

      # ── gate 2：metadata ──
      assert_receive {:metadata_entered, ^metadata_ref, metadata_pid, metadata_journal}, 5_000

      # journal 必须已经在**同一次转换**里原子写入 fingerprint 与 canonical wrapper。
      assert metadata_journal.phase == "published"
      refute is_nil(metadata_journal.published_fingerprint)

      assert %{"published_proof" => proof, "last_failure" => nil} =
               metadata_journal.recovery_evidence

      assert proof["status"] in ["verified", "degraded"]

      send(metadata_pid, {:metadata_release, metadata_ref})

      assert {:ok, _} = Task.await(task, 15_000)
      assert Script.call_count(:verify_published) == 1
      assert Script.remaining(:verify_published) == 0
    end

    @tag :task3_g2_commit_red
    test "g2 red: a 32-detail degraded proof is persisted as the canonical 31-detail wrapper",
         ctx do
      Script.script(:verify_published, {:return, {:ok, {:degraded, degraded_32_summary()}}})

      assert {:ok, _} = protocol_put(ctx, "degraded content")

      assert Script.call_count(:verify_published) == 1
      journal = journal_for(ctx, @key)

      assert journal.phase in ["metadata_committed", "finalize_pending", "finalized"]
      assert journal.published_fingerprint != nil

      wrapper = journal.recovery_evidence
      refute is_nil(wrapper), "published 转换必须一次写入 fingerprint 与 wrapper"
      assert %{"published_proof" => proof, "last_failure" => _} = wrapper
      assert proof["status"] == "degraded"

      # Stage-B 规范化：初次持久化成功 proof 最多保留 31 条 detail，其余精确计入 omitted。
      assert length(proof["degraded"]) == 31
      assert proof["omitted"] >= 1
    end

    # G2 correction §5：五个 context 全部来自**真实且互相独立**的观察点。
    #   claimed_ctx      ← publish 闭包的实际输入（backend 发布之前）
    #   verify_ctx       ← 脚本 backend 的 verify callback
    #   metadata_journal ← metadata callback 的 journal 实参
    #   fresh_ctx        ← 由该 metadata journal 重建
    #   finalize_ctx     ← 脚本 backend 的直接 finalize callback
    @tag :task3_g2_commit_red
    test "g2 red: claimed, verify, fresh and finalize contexts have independent exact provenance",
         ctx do
      owner = self()

      assert {:ok, %{published: published}} =
               protocol_put(ctx, "provenance content",
                 publish_observer: fn extra ->
                   send(owner, {:publish_observed, Keyword.fetch!(extra, :object_mutation)})
                 end,
                 metadata_tx: recording_metadata_tx(owner, ctx.bucket, @key)
               )

      assert_receive {:publish_observed, %MutationContext{} = claimed_ctx}
      assert_receive {:metadata_entered, metadata_journal}

      returned_fingerprint = published.epoch_fingerprint
      refute is_nil(returned_fingerprint)

      assert [%{ctx: verify_ctx}] = Script.calls(:verify_published)
      assert [%{ctx: finalize_ctx}] = Script.calls(:finalize_if_current)

      assert {:ok, fresh_ctx} = MutationContext.from_journal(metadata_journal)

      # 显式匹配 struct，避免 struct-update 类型告警。
      assert %MutationContext{} = claimed_ctx
      assert %MutationContext{} = verify_ctx
      expected = %MutationContext{claimed_ctx | published_fingerprint: returned_fingerprint}

      assert verify_ctx === expected, "verify 必须收到 claimed ctx + 返回的 fingerprint"
      assert fresh_ctx === expected, "fresh-journal ctx 必须与之严格相等"
      assert finalize_ctx === fresh_ctx, "直接 finalize 必须使用 fresh-journal ctx"

      # 冻结 backend 在 publish 期间捕获的私有 Control finalize 闭包**不可观察**；
      # 上面的严格值相等证明了它本地重建的 proof_ctx 值，而不声称脚本 recorder 看见了它。
    end

    @tag :task3_g2_commit_red
    test "g2 red: restore after a post-proof metadata failure uses the original claimed context",
         ctx do
      {:ok, _} = Storage.put(ctx.bucket, @key, "null", ["old content"], data_dir: ctx.dir)
      owner = self()

      assert_raise RuntimeError, "provenance metadata boom", fn ->
        protocol_put(ctx, "new content",
          publish_observer: fn extra ->
            send(owner, {:publish_observed, Keyword.fetch!(extra, :object_mutation)})
          end,
          metadata_tx: fn _journal, _published, _write_info ->
            raise "provenance metadata boom"
          end
        )
      end

      assert_receive {:publish_observed, %MutationContext{} = claimed_ctx}

      assert [%{ctx: restore_ctx}] = Script.calls(:restore_if_current)

      # restore 必须使用**原始的、与 fingerprint 无关**的 claimed context。
      assert restore_ctx === claimed_ctx
      assert is_nil(restore_ctx.published_fingerprint)
    end

    # 四个 pre-metadata proof failure class 必须是**四个独立用例**：写进一个 `for` 时，
    # 旧生产下第一格的 assert 会直接中止该测试，后三格根本不会执行，也不会消费各自的
    # 脚本条目，从而被静默掩盖。每格都自证 callback 真实执行（call_count/remaining）。

    defp assert_pre_metadata_proof_failure!(ctx, class, stable_code) do
      key = "g2-pre-meta-#{class}.bin"
      {:ok, _} = Storage.put(ctx.bucket, key, "null", ["old content"], data_dir: ctx.dir)
      owner = self()

      # 绑定**确切**的 scripted Storage 结果，稍后逐字比对请求返回。
      scripted = proof_failure(class)
      {:error, {:published_proof_failed, ^class, scripted_summary}} = scripted

      Script.script(:verify_published, {:return, scripted})

      result =
        protocol_put(ctx, "new content",
          key: key,
          metadata_tx: recording_metadata_tx(owner, ctx.bucket, key)
        )

      # 该格的 scripted callback 必须真的被消费掉。
      assert Script.call_count(:verify_published) == 1, "#{class}：verify_published 必须恰好被调用一次"
      assert Script.remaining(:verify_published) == 0, "#{class}：脚本条目必须被精确消费"

      # 精确的结构化请求返回，且 summary 与脚本给出的那一个严格相同。
      assert result == {:error, {:published_proof_failed, class, scripted_summary}},
             "#{class}：请求必须返回原样的结构化 proof error，实际：#{inspect(result)}"

      assert {:error, {:published_proof_failed, ^class, returned_summary}} = result
      assert returned_summary === scripted_summary

      # metadata 回调零调用、PG 零副作用。
      refute_received {:metadata_entered, _journal}
      assert {:error, :not_found} = Objects.get_metadata(ctx.bucket, key)

      journal = journal_for(ctx, key)

      assert journal.phase in ["rollback_pending", "rolled_back"],
             "#{class}：必须收敛到 rollback 域，实际 #{journal.phase}"

      assert is_nil(journal.published_fingerprint), "#{class}：rollback 三元组的 fingerprint 必须为 nil"

      # 精确、未加引号的 proof 稳定 code。
      assert journal.last_error == stable_code, "#{class}：必须写入精确的稳定 code"
      refute String.contains?(journal.last_error, "\""), "#{class}：稳定 code 绝不能被 inspect 加引号"

      assert %{"published_proof" => nil, "last_failure" => failure} = journal.recovery_evidence
      assert failure["status"] == "failed"
      assert failure["class"] == Atom.to_string(class)
      assert failure["mode"] == "proof"

      # 旧字节恢复。
      {:ok, rel} = Paths.object_rel(ctx.bucket, key, "null")
      assert File.read!(Path.join([ctx.dir, rel, "part.0"])) == "old content"
    end

    @tag :task3_g2_commit_red
    test "g2 red: a pre-metadata unavailable proof rolls back with canonical evidence", ctx do
      assert_pre_metadata_proof_failure!(
        ctx,
        :unavailable,
        "published_proof_failed:proof:unavailable"
      )
    end

    @tag :task3_g2_commit_red
    test "g2 red: a pre-metadata mismatch proof rolls back with canonical evidence", ctx do
      assert_pre_metadata_proof_failure!(ctx, :mismatch, "published_proof_failed:proof:mismatch")
    end

    @tag :task3_g2_commit_red
    test "g2 red: a pre-metadata corrupt proof rolls back with canonical evidence", ctx do
      assert_pre_metadata_proof_failure!(ctx, :corrupt, "published_proof_failed:proof:corrupt")
    end

    @tag :task3_g2_commit_red
    test "g2 red: a pre-metadata placement_drift proof rolls back with canonical evidence", ctx do
      assert_pre_metadata_proof_failure!(
        ctx,
        :placement_drift,
        "published_proof_failed:proof:placement_drift"
      )
    end

    @tag :task3_g2_commit_red
    test "g2 red: a pre-metadata superseded proof converges without forging a fenced failure",
         ctx do
      key = "g2-pre-meta-superseded.bin"
      {:ok, _} = Storage.put(ctx.bucket, key, "null", ["old content"], data_dir: ctx.dir)
      owner = self()

      summary = superseded_summary()
      Script.script(:verify_published, {:return, {:ok, {:superseded, summary}}})

      result =
        protocol_put(ctx, "new content",
          key: key,
          metadata_tx: recording_metadata_tx(owner, ctx.bucket, key)
        )

      # 精确的 request-level successor 词条，summary 严格同一。
      assert result == {:error, {:published_proof_superseded, summary}},
             "superseded 必须返回精确的 request-level 词条，实际：#{inspect(result)}"

      assert {:error, {:published_proof_superseded, returned}} = result
      assert returned === summary

      refute_received {:metadata_entered, _journal}

      journal = journal_for(ctx, key)
      assert journal.phase in ["rollback_pending", "rolled_back"]
      assert is_nil(journal.published_fingerprint)
      assert journal.last_error == "published_proof_superseded:proof"

      assert %{"published_proof" => nil, "last_failure" => failure} = journal.recovery_evidence
      assert failure["status"] == "superseded"

      # successor 绝不能被伪造成 published_proof_failed/:fenced。
      refute failure["class"] == "fenced"
      refute failure["status"] == "failed"

      assert {:error, :not_found} = Objects.get_metadata(ctx.bucket, key)
    end

    @tag :task3_g2_commit_red
    test "g2 red: a proof callback contract violation uses the exact generic G1 evidence", ctx do
      key = "g2-pre-meta-violation.bin"
      {:ok, _} = Storage.put(ctx.bucket, key, "null", ["old content"], data_dir: ctx.dir)
      owner = self()

      # 退役的 atom 结果：由既有 Storage trust boundary 折叠成 proof contract violation。
      Script.script(:verify_published, {:return, {:ok, :verified}})

      result =
        protocol_put(ctx, "new content",
          key: key,
          metadata_tx: recording_metadata_tx(owner, ctx.bucket, key)
        )

      # 精确的固定 contract violation 词条。
      assert result == {:error, {:published_proof_contract_violation, :proof}},
             "contract violation 必须返回精确的固定词条，实际：#{inspect(result)}"

      refute_received {:metadata_entered, _journal}

      journal = journal_for(ctx, key)
      assert journal.phase in ["rollback_pending", "rolled_back"]
      assert is_nil(journal.published_fingerprint)
      assert journal.last_error == "published_proof_contract_violation:proof"

      # 精确的四键 generic G1 证据；绝不调用 PublishedProof merge、绝不伪造 summary。
      assert journal.recovery_evidence == %{
               "authority_mode" => "pg",
               "stage" => "verify_published",
               "outcome" => "contract_violation",
               "mode" => "proof"
             }

      assert {:error, :not_found} = Objects.get_metadata(ctx.bucket, key)
    end

    @tag :task3_g2_commit_red
    test "g2 red: losing the claimed to published transition uses the exact journal-transition evidence",
         ctx do
      key = "g2-publish-transition-loss.bin"
      {:ok, _} = Storage.put(ctx.bucket, key, "null", ["old content"], data_dir: ctx.dir)

      owner = self()
      ref = make_ref()

      # 在 proof 成功之后、claimed→published CAS 之前确定性地扰动 attempts：
      # 用 gate 消息同步，绝不 sleep/poll。
      Script.script(:verify_published, {:gate, owner, ref, :delegate})

      task =
        Task.async(fn -> protocol_put(ctx, "new content", key: key) end)

      # gate 在 backend callback 的**调用方进程**里等待，因此 release 必须发回它送来的
      # 那个 pid，而不是脚本 Agent。使用已冻结的 map 形态 gate 记录。
      entered = await_gate!(ref, "verify_published")

      assert entered.operation == :verify_published
      assert entered.ref == ref
      assert is_pid(entered.caller)
      assert %MutationContext{} = entered.ctx
      refute is_nil(entered.ctx.published_fingerprint), "verify 必须已经拿到 publish 返回的 fingerprint"
      assert Keyword.fetch!(entered.opts, :data_dir) == ctx.dir

      perturbed = journal_for(ctx, key)
      {:ok, _} = ObjectMutation.mark_operational_error(perturbed, "concurrent_probe")

      send(entered.caller, {:script_backend_release, ref})
      result = Task.await(task, 15_000)

      assert result == {:error, {:object_mutation_journal, :internal, :publish_transition}},
             "publish 转换丢失必须返回精确的内部结果：#{inspect(result)}"

      journal = journal_for(ctx, key)

      assert journal.recovery_evidence == %{
               "authority_mode" => "pg",
               "stage" => "journal_publish",
               "outcome" => "transition_failed"
             }

      assert journal.last_error == "published_proof_journal_transition:failed"
      assert is_nil(journal.published_fingerprint)
      assert {:error, :not_found} = Objects.get_metadata(ctx.bucket, key)
    end

    # 【tests-only script-oracle 修正】直接被脚本化的 `Storage.restore_if_current/2` 确实
    # 失败了，但外层 ObjectCommit/Control 经 journal guard 使用**backend 私有的** restore
    # 闭包（`FS.do_restore_if_current/2`，publish 期间捕获，不经公开 Storage seam）独立完成
    # 恢复并清理 backup。Script 只代理公开 seam，看不到那个 Control 闭包，因此这里断言的是
    # 该闭包**可观察的最终收敛结果**（epoch rolled_back + 同一 token + backup 已清），
    # 而不是一个脚本无法控制的 backup 保留。
    @tag :task3_g2_commit_red
    test "g2 red: a restore failure after a primary proof failure preserves evidence while control converges",
         ctx do
      key = "g2-pre-meta-restore-failure.bin"
      {:ok, _} = Storage.put(ctx.bucket, key, "null", ["old content"], data_dir: ctx.dir)
      owner = self()

      scripted = proof_failure(:unavailable)
      {:error, {:published_proof_failed, :unavailable, scripted_summary}} = scripted

      # 主因是 proof 失败；随后 best-effort restore 也失败。
      Script.script(:verify_published, {:return, scripted})
      Script.script(:restore_if_current, {:return, {:error, :g2_restore_sentinel}})

      # 在操作**之前**就把期望的主证据 term 与 JSON 字节完全构造并冻结下来。
      # 之后一律与这份预期值比对，而不是拿事后值和它自己（或一次 refetch）比。
      {:ok, expected_evidence} =
        PublishedProof.journal_evidence("rollback_pending", nil, scripted_summary)

      expected_bytes = Jason.encode!(expected_evidence)
      expected_code = "published_proof_failed:proof:unavailable"

      {result, log} =
        with_log(fn ->
          protocol_put(ctx, "new content",
            key: key,
            metadata_tx: recording_metadata_tx(owner, ctx.bucket, key)
          )
        end)

      # 请求仍返回**原始的主 proof 错误**，而不是 restore 的次生原因。
      assert result == {:error, {:published_proof_failed, :unavailable, scripted_summary}},
             "restore 失败不得改写主 proof 错误，实际：#{inspect(result)}"

      refute_received {:metadata_entered, _journal}
      assert {:error, :not_found} = Objects.get_metadata(ctx.bucket, key)

      journal = journal_for(ctx, key)

      # 与**预先冻结**的期望值严格比对：term 与编码字节都必须逐字相同。
      assert journal.recovery_evidence === expected_evidence,
             "持久化证据必须严格等于预先构造的主 proof 失败证据"

      assert Jason.encode!(journal.recovery_evidence) == expected_bytes,
             "持久化证据的 JSON 字节必须与预先构造的字节逐字相同"

      assert journal.last_error == expected_code
      refute String.contains?(journal.last_error, "\"")

      # 【correction R1 §4.1】restore 失败是 log-only 的次生运维失败：journal 必须停在
      # rollback_pending（既不前进也不被次生失败改写），且 rollback CAS 已把
      # next_attempt_at 置为 now，Recovery 立即可见。
      assert journal.phase == "rollback_pending",
             "restore 失败不得推进或改写 journal 的 rollback_pending 主状态"

      refute is_nil(journal.next_attempt_at),
             "rollback CAS 必须写下 next_attempt_at 让 Recovery 立即可见"

      # raw restore 原因绝不落库、绝不出现在结果里、也绝不进日志。
      refute String.contains?(inspect(result), "g2_restore_sentinel")
      refute String.contains?(journal.last_error, "g2_restore_sentinel")
      refute String.contains?(expected_bytes, "g2_restore_sentinel")
      refute String.contains?(Jason.encode!(journal.recovery_evidence), "g2_restore_sentinel")

      refute String.contains?(log, "g2_restore_sentinel"),
             "raw restore 原因绝不能出现在日志里"

      # 旧字节必须仍然是旧内容（restore 失败 → 未被改写成新内容）。
      {:ok, rel} = Paths.object_rel(ctx.bucket, key, "null")
      assert File.read!(Path.join([ctx.dir, rel, "part.0"])) == "old content"

      # 直接 scripted restore 恰好被调用并失败一次。
      assert Script.call_count(:restore_if_current) == 1
      assert Script.remaining(:restore_if_current) == 0

      # Control 的私有 FS restore 闭包随后独立收敛：同一 token 的 epoch 变为 rolled_back，
      # backup 由该闭包清理。这是脚本可观察到的最终事实。
      {:ok, epoch_target} = ObjectEpoch.object_target(ctx.bucket, key, "null")

      assert {:ok, %ObjectEpoch{} = epoch} =
               Storage.current_epoch(epoch_target, data_dir: ctx.dir)

      assert epoch.phase == "rolled_back"
      assert epoch.token["mutation_id"] == journal.id
      assert mutation_dirs(ctx) == []
    end

    # --- §4.6 finalize disposition 矩阵 ---

    @tag :task3_g2_commit_red
    test "g2 red: a finalized disposition converges terminally, drops backup and preserves the proof",
         ctx do
      {result, snapshot} =
        gated_finalize!(ctx, @key, "finalized content", {:ok, {:finalized, finalized_summary()}})

      assert {:ok, _} = result

      journal = journal_for(ctx, @key)
      assert journal.phase == "finalized"
      assert %{"published_proof" => proof, "last_failure" => nil} = journal.recovery_evidence
      assert proof["status"] in ["verified", "degraded"]
      refute is_nil(journal.finalized_at)

      assert_snapshot_preserved!(journal, snapshot, "finalized")

      # 终态 finalized：durable backup 必须被清除。
      assert mutation_dirs(ctx) == [], "finalized 之后 backup 必须移除"

      # 【correction R1 §4.4】终态：永远不进 recovery 到期队列。
      refute_due!(journal, "finalized")
    end

    # 【tests-only script-oracle 修正】cleanup_pending 仍然是 request success，且 journal
    # 停在 finalize_pending 并带上清理债务与重试排期。但同步的 `Control.mark_committed`
    # 会执行 backend 私有的 finalize 闭包（`FS.do_finalize_if_current/2`，publish 期间捕获，
    # 不经公开 Storage seam），它可以独立把 storage epoch 收敛为 committed 并清掉 backup。
    # Script 无法代理该闭包，因此这里断言它可观察的最终收敛结果，而不是 backup 保留。
    @tag :task3_g2_commit_red
    test "g2 red: cleanup_pending is request success, non-terminal and scheduled while control converges",
         ctx do
      {result, snapshot} =
        gated_finalize!(
          ctx,
          @key,
          "cleanup content",
          {:ok, {:cleanup_pending, cleanup_pending_summary()}}
        )

      assert {:ok, _} = result, "cleanup_pending 是请求成功"

      journal = journal_for(ctx, @key)
      assert journal.phase == "finalize_pending", "cleanup_pending 不是终态"
      assert is_nil(journal.finalized_at)

      assert %{"published_proof" => proof, "last_failure" => failure} = journal.recovery_evidence
      assert proof["status"] in ["verified", "degraded"]
      assert failure["status"] == "cleanup_pending"
      assert failure["mode"] == "finalize"

      assert_snapshot_preserved!(journal, snapshot, "cleanup_pending")

      # 精确、未加引号的 cleanup 稳定 code。
      assert journal.last_error == "published_proof_cleanup_pending:finalize",
             "cleanup_pending 必须写入精确的稳定 code"

      refute String.contains?(journal.last_error, "\"")

      # 有清理债务：必须排期重试。
      refute is_nil(journal.next_attempt_at), "cleanup_pending 必须排期重试"

      # Control 的私有 FS finalize 闭包独立收敛：同一 token 的 epoch 变为 committed，
      # backup 由该闭包清理。这是脚本可观察到的最终事实。
      assert {:ok, %ObjectEpoch{} = epoch} = Storage.current_epoch(target(ctx), data_dir: ctx.dir)
      assert epoch.phase == "committed"
      assert epoch.token["mutation_id"] == journal.id
      assert mutation_dirs(ctx) == []

      # 【correction R1 §4.1】cleanup_pending 仍是完整成功的数据面：final bytes 就是本次
      # 内容，epoch fingerprint 与 journal 上的 fingerprint 严格 `===`。
      assert File.read!(Path.join(final_dir(ctx), "part.0")) == "cleanup content"
      assert epoch.fingerprint === journal.published_fingerprint

      # 直接 scripted `Storage.finalize_if_current/2` 恰好一次，脚本队列精确清空。
      assert Script.call_count(:finalize_if_current) == 1
      assert Script.remaining(:finalize_if_current) == 0
    end

    # 同理，四个 post-metadata finalize failure class 必须是四个独立用例，每格自证其
    # scripted finalize callback 真实执行，并断言**精确未加引号**的 finalize 稳定 code。

    defp assert_post_metadata_finalize_failure!(ctx, class, expected_phase) do
      key = "g2-finalize-#{class}.bin"
      stable_code = "published_proof_failed:finalize:#{class}"

      scripted = finalize_failure(class)
      {:error, {:published_proof_failed, ^class, scripted_summary}} = scripted

      # 本格自己的 pre-finalize gated 快照。
      {result, snapshot} = gated_finalize!(ctx, key, "content", scripted)

      # 该格的 scripted finalize callback 必须真的被消费掉。
      assert Script.call_count(:finalize_if_current) == 1,
             "#{class}：直接 Storage.finalize_if_current/2 必须恰好被调用一次"

      assert Script.remaining(:finalize_if_current) == 0, "#{class}：脚本条目必须被精确消费"

      # 精确的结构化 proof error，summary 与脚本给出的严格同一。
      assert result == {:error, {:published_proof_failed, class, scripted_summary}},
             "#{class}：请求必须返回原样的结构化 proof error，实际：#{inspect(result)}"

      journal = journal_for(ctx, key)

      # 与本格快照严格比对：proof term、JSON 字节、fingerprint 三者逐字不变。
      assert_snapshot_preserved!(journal, snapshot, to_string(class))

      assert journal.phase == expected_phase, "#{class}：期望 #{expected_phase}，实际 #{journal.phase}"

      # unavailable 可重试 → 必须排期重试；integrity 终态 → 不排期。
      if class == :unavailable do
        refute is_nil(journal.next_attempt_at), "#{class}：可重试失败必须排期"
      end

      # 所有 finalize 失败都必须保留 durable backup。
      refute mutation_dirs(ctx) == [], "#{class}：finalize 失败必须保留 backup"

      # 精确、未加引号的 finalize 稳定 code；绝不允许 inspect/1 洗白成带引号的形态。
      assert journal.last_error == stable_code, "#{class}：必须写入精确的 finalize 稳定 code"

      refute String.contains?(journal.last_error, "\""),
             "#{class}：finalize 稳定 code 绝不能被 inspect 加引号"

      assert %{"published_proof" => proof, "last_failure" => failure} = journal.recovery_evidence

      # 初始成功 proof 必须原样保留，只有 last_failure 被合并。
      assert proof["status"] in ["verified", "degraded"]
      refute is_nil(journal.published_fingerprint), "#{class}：metadata 之后 fingerprint 必须保留"
      assert failure["class"] == Atom.to_string(class)
      assert failure["mode"] == "finalize"

      # 【correction R1 §4.4】canonical finalize failure 必须同时锁死精确的 status。
      assert failure["status"] == "failed", "#{class}：canonical failure status 必须是 failed"

      # metadata 之后绝不回滚。
      refute journal.phase in ["rollback_pending", "rolled_back"]

      # 【correction R1 §4.4】终态（quarantined）分支必须被 list_due 排除；协议不要求
      # next_attempt_at == nil，因此断言的是真实的到期排除语义。
      if expected_phase == "quarantined", do: refute_due!(journal, to_string(class))
    end

    @tag :task3_g2_commit_red
    test "g2 red: a post-metadata unavailable finalize merges last failure and stays pending",
         ctx do
      assert_post_metadata_finalize_failure!(ctx, :unavailable, "finalize_pending")

      # 显式反证被引号包裹的 legacy 形态（本格是合同点名要求的那一格）。
      journal = journal_for(ctx, "g2-finalize-unavailable.bin")
      refute journal.last_error == "\"published_proof_failed:finalize:unavailable\""
      refute journal.last_error == inspect("published_proof_failed:finalize:unavailable")
    end

    @tag :task3_g2_commit_red
    test "g2 red: a post-metadata mismatch finalize merges last failure and quarantines", ctx do
      assert_post_metadata_finalize_failure!(ctx, :mismatch, "quarantined")
    end

    @tag :task3_g2_commit_red
    test "g2 red: a post-metadata corrupt finalize merges last failure and quarantines", ctx do
      assert_post_metadata_finalize_failure!(ctx, :corrupt, "quarantined")
    end

    @tag :task3_g2_commit_red
    test "g2 red: a post-metadata placement_drift finalize merges last failure and quarantines",
         ctx do
      assert_post_metadata_finalize_failure!(ctx, :placement_drift, "quarantined")
    end

    @tag :task3_g2_commit_red
    test "g2 red: a post-metadata successor converges terminally without rollback", ctx do
      summary = finalize_superseded_summary()

      {result, snapshot} =
        gated_finalize!(ctx, @key, "successor content", {:ok, {:superseded, summary}})

      # 精确的 request-level successor 词条，summary 严格同一。
      assert result == {:error, {:published_proof_superseded, summary}},
             "metadata 之后的 successor 必须返回精确的 request-level 词条：#{inspect(result)}"

      journal = journal_for(ctx, @key)
      refute journal.phase in ["rollback_pending", "rolled_back"], "metadata 之后绝不回滚"
      assert journal.phase == "finalized", "successor 必须终态收敛为 finalized"

      assert %{"published_proof" => proof, "last_failure" => failure} = journal.recovery_evidence
      assert proof["status"] in ["verified", "degraded"]
      assert failure["status"] == "superseded"
      assert failure["mode"] == "finalize"
      refute failure["class"] == "fenced"

      assert_snapshot_preserved!(journal, snapshot, "superseded")

      # 【correction R1 §4.4】终态：永远不进 recovery 到期队列。
      refute_due!(journal, "superseded")

      # 精确、未加引号的 successor 稳定 code。
      assert journal.last_error == "published_proof_superseded:finalize",
             "successor 必须写入精确的稳定 code"

      refute String.contains?(journal.last_error, "\"")

      # successor 是终态：保留 backup，交后续 GC/收敛，不再排期本请求重试。
      refute mutation_dirs(ctx) == [], "successor 终态必须保留 backup"
    end

    @tag :task3_g2_commit_red
    test "g2 red: a finalize contract violation quarantines with byte-exact evidence", ctx do
      # 退役 atom 结果 → 既有 Storage trust boundary 折叠为 finalize contract violation。
      {result, snapshot} = gated_finalize!(ctx, @key, "violation content", {:ok, :finalized})

      # 精确的固定 contract violation 词条。
      assert result == {:error, {:published_proof_contract_violation, :finalize}},
             "finalize contract violation 必须返回精确的固定词条：#{inspect(result)}"

      journal = journal_for(ctx, @key)
      assert journal.phase == "quarantined"
      refute journal.phase in ["rollback_pending", "rolled_back"]

      # fingerprint 与 wrapper 的 term 及 JSON 字节必须逐字保持不变。
      assert %{"published_proof" => proof} = journal.recovery_evidence
      assert proof["status"] in ["verified", "degraded"]

      assert_snapshot_preserved!(journal, snapshot, "contract_violation")

      # 【correction R1 §4.1】evidence-preserving 隔离必须保住**完整 wrapper**：初始
      # wrapper 的 term 与完整 JSON 字节都逐字不变，而不只是它的 "published_proof" 子项。
      assert_wrapper_preserved!(journal, snapshot, "contract_violation")

      assert journal.last_error == "published_proof_contract_violation:finalize"
      refute String.contains?(journal.last_error, "\"")

      # 终态隔离：保留 backup 供取证。
      refute mutation_dirs(ctx) == [], "contract violation 隔离必须保留 backup"

      # 终态：永远不进 recovery 到期队列。
      refute_due!(journal, "contract_violation")
    end

    # G2 correction §7：用**finalize gate** 在 merge 之前真正读一次 pending journal，
    # 快照初始 proof term / JSON 字节 / fingerprint，再放行一个会触发 merge 的结果，
    # 最后证明这三者逐字不变、只有 canonical last_failure 变化。
    # 这取代了旧的「拿 merge 之后的值和它自己比」的自证式断言。
    @tag :task3_g2_commit_red
    test "g2 red: the pre-merge proof term, bytes and fingerprint survive a finalize merge",
         ctx do
      owner = self()
      finalize_ref = make_ref()

      Script.script(
        :finalize_if_current,
        {:gate, owner, finalize_ref,
         {:return, {:ok, {:cleanup_pending, cleanup_pending_summary()}}}}
      )

      task = Task.async(fn -> protocol_put(ctx, "snapshot content") end)

      entered = await_gate!(finalize_ref, "finalize_if_current")
      assert entered.operation == :finalize_if_current
      assert %MutationContext{} = entered.ctx

      # merge 之前读取 pending journal 并快照三项取证。
      pending = journal_for(ctx, @key)
      assert pending.phase in ["metadata_committed", "finalize_pending"]
      assert %{"published_proof" => initial_proof} = pending.recovery_evidence
      refute is_nil(initial_proof)
      initial_proof_bytes = Jason.encode!(initial_proof)
      initial_fingerprint = pending.published_fingerprint
      refute is_nil(initial_fingerprint)

      send(entered.caller, {:script_backend_release, finalize_ref})
      assert {:ok, _} = Task.await(task, 15_000)

      converged = journal_for(ctx, @key)

      assert %{"published_proof" => merged_proof, "last_failure" => failure} =
               converged.recovery_evidence

      # 初始 proof 的 term、编码字节与 fingerprint 三者逐字不变。
      assert merged_proof === initial_proof
      assert Jason.encode!(merged_proof) == initial_proof_bytes
      assert converged.published_fingerprint === initial_fingerprint

      # 只有 canonical last_failure 发生变化。
      assert failure["status"] == "cleanup_pending"
      assert failure["mode"] == "finalize"
    end

    @tag :task3_g2_commit_red
    test "g2 control: an orchestration failpoint raise is never folded into a proof outcome",
         ctx do
      Failpoint.arm(:object_mutation_finalize, {:raise, "g2 orchestration failpoint"})
      on_exit(fn -> Failpoint.disarm(:object_mutation_finalize) end)

      result = protocol_put(ctx, "failpoint content")

      # 编排层 failpoint raise 属于 orchestration 域，绝不能被当成 backend callback 的
      # contract violation 或 proof failure 处理。既有契约（并由冻结的 Recovery 基线锁死）
      # 是：请求成功、journal 停在 finalize_pending，由 Recovery 后续收敛——所以这里断言
      # 的是「绝不被折叠成 proof 结论」，而不是「必须抛到调用方」。
      refute match?({:error, {:published_proof_contract_violation, _mode}}, result),
             "orchestration failpoint 绝不能被折叠成 callback contract violation：#{inspect(result)}"

      refute match?({:error, {:published_proof_failed, _class, _summary}}, result),
             "orchestration failpoint 绝不能被折叠成 proof failure：#{inspect(result)}"

      journal = journal_for(ctx, @key)
      refute journal.phase == "quarantined", "orchestration failpoint 不得触发 proof 隔离"
    end

    @tag :task3_g2_commit_red
    test "g2 control: the script seam is live and unscripted operations delegate to FS", ctx do
      assert Script.seam_live?()
      assert Storage.backend() == Script
      assert ctx.previous_backend == Maxio.Storage.FS

      assert {:ok, _} = protocol_put(ctx, "delegation content")

      # 未编排任何条目：四个受控操作全部走 FS 委派，且剩余条目为零。
      assert Script.remaining_all() == %{
               verify_published: 0,
               finalize_if_current: 0,
               current_epoch: 0,
               restore_if_current: 0
             }
    end
  end

  # ── Task 3 / G2 Green review correction R1：单一 durable-finalize-outcome seam ──
  #
  # 两组彼此独立的矩阵：
  #   §4.2 纯 merge 拒绝 —— 属于内部 durable 契约违约，绝不返回原 backend union、
  #        也绝不返回 cleanup 成功；
  #   §4.3 durable 动作 CAS 写丢失 —— 保留原请求语义、绝不覆盖赢家、绝不加速。
  #
  # 全部用脚本 gate / failpoint `{:fun, _}` / 消息同步驱动，零 sleep、零轮询、零
  # Application-env 脚本状态、零新增生产 failpoint。

  describe "G2 green review correction R1 durable finalize outcome" do
    setup ctx do
      previous = Application.fetch_env!(:maxio, :storage_backend)
      Application.put_env(:maxio, :storage_backend, Script)
      on_exit(fn -> Application.put_env(:maxio, :storage_backend, previous) end)

      start_supervised!(Script)
      Map.put(ctx, :previous_backend, previous)
    end

    # --- §4.2 merge-rejection 矩阵 ---

    @tag :task3_g2_green_review_correction
    test "g2r1 merge rejection: a cleanup merge rejection never returns request success", ctx do
      assert_merge_rejection!(
        ctx,
        "cleanup",
        {:ok, {:cleanup_pending, cleanup_pending_summary_with_sentinel()}}
      )
    end

    @tag :task3_g2_green_review_correction
    test "g2r1 merge rejection: a superseded merge rejection never terminalizes", ctx do
      assert_merge_rejection!(
        ctx,
        "superseded",
        {:ok, {:superseded, finalize_superseded_summary_with_sentinel()}}
      )
    end

    @tag :task3_g2_green_review_correction
    test "g2r1 merge rejection: an unavailable merge rejection never returns the backend union",
         ctx do
      assert_merge_rejection!(ctx, "unavailable", finalize_failure_with_sentinel(:unavailable))
    end

    @tag :task3_g2_green_review_correction
    test "g2r1 merge rejection: an integrity merge rejection never returns the backend union",
         ctx do
      assert_merge_rejection!(ctx, "mismatch", finalize_failure_with_sentinel(:mismatch))
    end

    # --- §4.3 durable 动作 CAS 写丢失矩阵 ---

    @tag :task3_g2_green_review_correction
    test "g2r1 cas loss: a lost metadata_committed to finalize_pending fence defers with no finalize",
         ctx do
      key = "g2r1-loss-fence.bin"
      owner = self()
      ref = make_ref()

      Failpoint.arm(
        :object_mutation_after_metadata_commit,
        {:fun,
         fn ->
           send(owner, {:fence_gate, ref, self()})

           receive do
             {:fence_release, ^ref} -> :ok
           after
             5_000 -> raise(RuntimeError, message: "fence gate timeout")
           end
         end}
      )

      on_exit(fn -> Failpoint.disarm(:object_mutation_after_metadata_commit) end)

      {{result, snapshot}, log} =
        with_log(@correction_capture_opts, fn ->
          task = Task.async(fn -> protocol_put(ctx, "fence loss content", key: key) end)

          assert_receive {:fence_gate, ^ref, gate_pid}, 5_000

          observed = journal_for(ctx, key)
          assert observed.phase == "metadata_committed"
          {:ok, winner} = correction_probe(observed)

          send(gate_pid, {:fence_release, ref})
          {Task.await(task, 15_000), correction_snapshot(winner)}
        end)

      assert {:ok, _} = result, "安全可恢复的 metadata_committed 赢家：请求成功且 defer"

      journal = assert_winner_intact!(ctx, key, snapshot, log, "fence_loss")
      assert journal.phase == "metadata_committed"

      # fence 丢失后绝不继续直接 finalize，也绝不 restore。
      assert_call_counts!("fence_loss", 1, 0, 0)
    end

    @tag :task3_g2_green_review_correction
    test "g2r1 cas loss: a lost cleanup mark_error preserves request success", ctx do
      key = "g2r1-loss-cleanup.bin"

      {{result, snapshot}, log} =
        gated_finalize_race!(
          ctx,
          key,
          "cleanup loss content",
          {:ok, {:cleanup_pending, cleanup_pending_summary()}},
          &correction_probe/1
        )

      assert {:ok, _} = result, "cleanup 写丢失后原请求语义仍是成功"

      journal = assert_winner_intact!(ctx, key, snapshot, log, "cleanup_loss")
      assert journal.phase == "finalize_pending"
      assert journal.last_error == @correction_probe_code
      assert_call_counts!("cleanup_loss", 1, 1, 0)
    end

    @tag :task3_g2_green_review_correction
    test "g2r1 cas loss: a lost unavailable mark_error preserves the original proof error", ctx do
      key = "g2r1-loss-unavailable.bin"
      scripted = finalize_failure(:unavailable)
      {:error, {:published_proof_failed, :unavailable, summary}} = scripted

      {{result, snapshot}, log} =
        gated_finalize_race!(ctx, key, "unavailable loss", scripted, &correction_probe/1)

      assert result == {:error, {:published_proof_failed, :unavailable, summary}},
             "写丢失绝不改写原始结构化 proof 错误：#{inspect(result)}"

      journal = assert_winner_intact!(ctx, key, snapshot, log, "unavailable_loss")
      assert journal.phase == "finalize_pending"
      assert_call_counts!("unavailable_loss", 1, 1, 0)
    end

    @tag :task3_g2_green_review_correction
    test "g2r1 cas loss: a lost integrity quarantine preserves the original proof error", ctx do
      key = "g2r1-loss-integrity.bin"
      scripted = finalize_failure(:mismatch)
      {:error, {:published_proof_failed, :mismatch, summary}} = scripted

      {{result, snapshot}, log} =
        gated_finalize_race!(ctx, key, "integrity loss", scripted, &correction_probe/1)

      assert result == {:error, {:published_proof_failed, :mismatch, summary}},
             "写丢失绝不改写原始结构化 proof 错误：#{inspect(result)}"

      journal = assert_winner_intact!(ctx, key, snapshot, log, "integrity_loss")
      assert journal.phase == "finalize_pending"
      assert_call_counts!("integrity_loss", 1, 1, 0)
    end

    @tag :task3_g2_green_review_correction
    test "g2r1 cas loss: a lost superseded terminal transition preserves the successor error",
         ctx do
      key = "g2r1-loss-superseded.bin"
      summary = finalize_superseded_summary()

      {{result, snapshot}, log} =
        gated_finalize_race!(
          ctx,
          key,
          "superseded loss",
          {:ok, {:superseded, summary}},
          &correction_probe/1
        )

      assert result == {:error, {:published_proof_superseded, summary}},
             "写丢失绝不改写精确的 successor 词条：#{inspect(result)}"

      journal = assert_winner_intact!(ctx, key, snapshot, log, "superseded_loss")
      assert journal.phase == "finalize_pending"
      assert_call_counts!("superseded_loss", 1, 1, 0)
    end

    @tag :task3_g2_green_review_correction
    test "g2r1 cas loss: a lost finalized terminal transition preserves request success", ctx do
      key = "g2r1-loss-finalized.bin"

      {{result, snapshot}, log} =
        gated_finalize_race!(
          ctx,
          key,
          "finalized loss",
          {:ok, {:finalized, finalized_summary()}},
          &correction_probe/1
        )

      assert {:ok, _} = result, "finalized 写丢失后原请求语义仍是成功"

      journal = assert_winner_intact!(ctx, key, snapshot, log, "finalized_loss")
      assert journal.phase == "finalize_pending"
      assert_call_counts!("finalized_loss", 1, 1, 0)
    end

    @tag :task3_g2_green_review_correction
    test "g2r1 cas loss: a lost callback-contract quarantine preserves the finalize contract error",
         ctx do
      key = "g2r1-loss-contract.bin"

      # 退役 atom 结果 → 冻结的 Storage trust boundary 折叠为 finalize contract violation。
      {{result, snapshot}, log} =
        gated_finalize_race!(ctx, key, "contract loss", {:ok, :finalized}, &correction_probe/1)

      assert result == {:error, {:published_proof_contract_violation, :finalize}},
             "写丢失绝不改写固定 finalize 契约错误：#{inspect(result)}"

      journal = assert_winner_intact!(ctx, key, snapshot, log, "contract_loss")
      assert journal.phase == "finalize_pending"
      assert_call_counts!("contract_loss", 1, 1, 0)
    end

    @tag :task3_g2_green_review_correction
    test "g2r1 cas loss: a lost orchestration mark_operational_error preserves request success",
         ctx do
      key = "g2r1-loss-orchestration.bin"
      owner = self()

      Failpoint.arm(
        :object_mutation_finalize,
        {:fun,
         fn ->
           observed = journal_for(ctx, key)
           {:ok, winner} = correction_probe(observed)
           send(owner, {:orchestration_winner, winner})
           raise(RuntimeError, message: "g2r1 orchestration boom")
         end}
      )

      on_exit(fn -> Failpoint.disarm(:object_mutation_finalize) end)

      {result, log} =
        with_log(@correction_capture_opts, fn ->
          protocol_put(ctx, "orchestration loss content", key: key)
        end)

      assert_received {:orchestration_winner, winner}
      snapshot = correction_snapshot(winner)

      assert {:ok, _} = result, "编排错误：既有请求成功语义必须保留"

      journal = assert_winner_intact!(ctx, key, snapshot, log, "orchestration_loss")
      assert journal.phase == "finalize_pending"
      assert journal.last_error == @correction_probe_code

      # 编排 failpoint 在直接 finalize 之前触发，因此直接 finalize 零调用。
      assert_call_counts!("orchestration_loss", 1, 0, 0)
    end

    @tag :task3_g2_green_review_correction
    test "g2r1 cas loss: an incompatible terminal winner yields the fixed internal envelope",
         ctx do
      key = "g2r1-loss-incompatible.bin"

      {{result, snapshot}, log} =
        gated_finalize_race!(
          ctx,
          key,
          "incompatible winner",
          {:ok, {:cleanup_pending, cleanup_pending_summary()}},
          fn journal ->
            ObjectMutation.quarantine_preserving_evidence(journal, @correction_winner_code)
          end
        )

      assert result == {:error, @correction_internal_envelope},
             "不兼容终态赢家必须收敛为固定内部信封：#{inspect(result)}"

      journal = assert_winner_intact!(ctx, key, snapshot, log, "incompatible_winner")
      assert journal.phase == "quarantined"
      assert journal.last_error == @correction_winner_code
      assert_call_counts!("incompatible_winner", 1, 1, 0)
      refute_due!(journal, "incompatible_winner")
    end

    # --- §4.3 终态幂等控制组（**不**扰动 attempts）---
    #
    # 这三格恰好命中 `ObjectMutation.transition/4` 的 generic 终态幂等：赢家已经写到同一个
    # 目标终态且 attempts 未变，因此 CAS 输家会拿到一个 `{:ok, winner}`。它绝不是本次意图
    # 的证明，必须被裁决为不兼容赢家。attempts-bump 那几格无法替代这组控制。

    @tag :task3_g2_green_review_correction
    test "g2r1 terminal idempotency: a non-proving finalized winner is adjudicated incompatible",
         ctx do
      key = "g2r1-idem-finalized.bin"

      {{result, snapshot}, log} =
        gated_finalize_race!(
          ctx,
          key,
          "idempotent finalized",
          {:ok, {:finalized, finalized_summary()}},
          &correction_terminal_winner(&1, "finalized")
        )

      assert result == {:error, @correction_internal_envelope},
             "非证明性的 {:ok, winner} 必须收敛为固定内部信封：#{inspect(result)}"

      journal = assert_winner_intact!(ctx, key, snapshot, log, "idem_finalized")
      assert journal.phase == "finalized"
      assert journal.last_error == @correction_winner_code
      assert_call_counts!("idem_finalized", 1, 1, 0)
      refute_due!(journal, "idem_finalized")
    end

    @tag :task3_g2_green_review_correction
    test "g2r1 terminal idempotency: a non-proving superseded-to-finalized winner is incompatible",
         ctx do
      key = "g2r1-idem-superseded.bin"

      {{result, snapshot}, log} =
        gated_finalize_race!(
          ctx,
          key,
          "idempotent superseded",
          {:ok, {:superseded, finalize_superseded_summary()}},
          &correction_terminal_winner(&1, "finalized")
        )

      assert result == {:error, @correction_internal_envelope},
             "非证明性的 {:ok, winner} 必须收敛为固定内部信封：#{inspect(result)}"

      journal = assert_winner_intact!(ctx, key, snapshot, log, "idem_superseded")
      assert journal.phase == "finalized"
      assert journal.last_error == @correction_winner_code
      assert_call_counts!("idem_superseded", 1, 1, 0)
      refute_due!(journal, "idem_superseded")
    end

    @tag :task3_g2_green_review_correction
    test "g2r1 terminal idempotency: a non-proving integrity-to-quarantined winner is incompatible",
         ctx do
      key = "g2r1-idem-quarantined.bin"

      {{result, snapshot}, log} =
        gated_finalize_race!(
          ctx,
          key,
          "idempotent quarantined",
          finalize_failure(:corrupt),
          &correction_terminal_winner(&1, "quarantined")
        )

      assert result == {:error, @correction_internal_envelope},
             "非证明性的 {:ok, winner} 必须收敛为固定内部信封：#{inspect(result)}"

      journal = assert_winner_intact!(ctx, key, snapshot, log, "idem_quarantined")
      assert journal.phase == "quarantined"
      assert journal.last_error == @correction_winner_code
      assert_call_counts!("idem_quarantined", 1, 1, 0)
      refute_due!(journal, "idem_quarantined")
    end

    # --- §4.3 / §5 静态取证（不新增任何运行时 Control seam）---

    # 【correction R2 §3.2】AST 所有权 oracle：权威是 `Code.string_to_quoted!/1` 得到的真实
    # 语法树，绝不数源码行、也绝不把正则字面量当证据。函数头里的 tuple 模式是**消费者**，
    # 只有表达式体里的构造才是生产者；注释与换行格式一律无关。
    @tag :task3_g2_green_review_correction
    test "g2r2 ast: the accelerate tuple has exactly one producer owned by the accelerate outcome clause" do
      report = accelerator_report(File.read!("lib/maxio/object_mutation/commit.ex"))

      assert accelerator_violations(report) == [],
             "真实 commit.ex 的加速器所有权必须完好：#{inspect(report)}"

      # 生产者唯一，且它就是 converged + success-accelerate 的 outcome_result 子句。
      assert report.producers == [@accelerate_producer_signature]

      # accelerate success policy 恰好由 finalized 与 cleanup-pending 两个 handle_finalize
      # 子句交给 seam。
      assert Enum.sort(report.policies) == Enum.sort(@accelerate_policy_signatures)

      # 携带任何 `:accelerate` 的子句体恰好只有这三个。
      assert Enum.sort(report.carriers) == Enum.sort(@accelerate_carrier_signatures)

      # 反向锁死：这些子句必须**各自恰好出现一次**（否则上面的集合相等会变成空洞断言，
      # 而且删掉其中任何一个子句都会被这里立刻抓到），且一律不得供给或构造 accelerator。
      for signature <- @accelerate_forbidden_signatures do
        assert Enum.count(report.clauses, &(&1 == signature)) == 1,
               "被点名的子句必须恰好存在一次：#{inspect(signature)}"

        refute signature in report.carriers, "该子句绝不允许携带 accelerator：#{inspect(signature)}"
      end
    end

    # 纯内存反例控制（不改动仓库任何文件）：先证明骨架在分析器下是干净的，再证明两种
    # 真实回归——多行第二生产者、policy 挪进错误 disposition——都会被拒绝。
    @tag :task3_g2_green_review_correction
    test "g2r2 ast control: a multiline second producer is rejected" do
      assert accelerator_violations(accelerator_report(@accelerator_control_source)) == [],
             "反例骨架自身必须是干净的基线"

      mutated =
        String.replace(
          @accelerator_control_source,
          @accelerator_control_superseded,
          """
            defp handle_finalize({:superseded, _summary}, row) do
              {
                :request_ok,
                row,
                :accelerate
              }
            end
          """
        )

      report = accelerator_report(mutated)

      assert length(report.producers) == 2, "多行第二生产者必须被识别为生产者"
      assert :producer_ownership in accelerator_violations(report)
      assert :carrier_ownership in accelerator_violations(report)
    end

    @tag :task3_g2_green_review_correction
    test "g2r2 ast control: an accelerate policy moved to a wrong disposition is rejected" do
      mutated =
        String.replace(
          @accelerator_control_source,
          @accelerator_control_superseded,
          """
            defp handle_finalize({:superseded, _summary}, journal),
              do: seam_outcome(journal, terminal_intent(), {:success, :accelerate})
          """
        )

      report = accelerator_report(mutated)

      assert length(report.policies) == 3, "挪错分支的 policy 必须被识别为 policy 供给点"
      assert {:handle_finalize, [:superseded, :_]} in report.carriers
      assert :policy_ownership in accelerator_violations(report)
      assert :carrier_ownership in accelerator_violations(report)
    end

    # 【correction R2 §6.4】源码 `_ = ObjectMutation` 检查只是补充线索，绝不声称证明了
    # 全部 case-discard。写入次数的权威是真实 Repo telemetry（见 §6.3 各格）。
    @tag :task3_g2_green_review_correction
    test "g2r2 static: the fixed write-loss scalar exists and source discards are a weak hint only" do
      source = File.read!("lib/maxio/object_mutation/commit.ex")

      assert source =~ @correction_write_loss_code, "必须存在唯一的固定写丢失标量 code"

      refute Regex.match?(~r/_\s*=\s*ObjectMutation\./, source),
             "补充线索：production 里不应出现 `_ = ObjectMutation.` 形态的丢弃"
    end

    # --- §6.1 winner fail-closed 矩阵 ---

    @tag :task3_g2_green_review_correction
    test "g2r2 winner: a metadata-committed winner whose evidence fails the durable validator is incompatible",
         ctx do
      key = "g2r2-winner-meta-evidence.bin"

      {result, winner, sql, log} =
        fence_race!(ctx, key, "winner meta evidence", fn observed ->
          # JSON-safe，但绝不是 canonical wrapper：`validate_durable_evidence/2` 必拒。
          # 证据里挂上 marker 3：它是唯一由 metadata-committed 竞争者写入的 raw sentinel。
          ObjectMutation.mark_error(observed, @correction_winner_code, %{
            "g2r2" => @correction_metadata_winner_sentinel
          })
        end)

      assert result == {:error, @correction_internal_envelope},
             "非 canonical evidence 的 winner 必须 fail closed：#{inspect(result)}"

      final = assert_winner_frozen!(ctx, key, winner, log, "meta_evidence")
      assert_cas_loss_sql!(sql, "meta_evidence")
      assert_call_counts!("meta_evidence", 1, 0, 0)

      # marker 3 泄漏证明：sentinel 必须**真的**在被冻结的赢家证据里（否则下面两条
      # refute 就是空洞的），但绝不出现在固定外部信封 / 请求结果与结构化日志里。
      assert String.contains?(
               Jason.encode!(winner.recovery_evidence),
               @correction_metadata_winner_sentinel
             ),
             "控制组必须真的把 sentinel 写进赢家证据"

      assert String.contains?(
               Jason.encode!(final.recovery_evidence),
               @correction_metadata_winner_sentinel
             ),
             "被冻结的最终行必须逐字保留该 sentinel"

      refute String.contains?(inspect(result), @correction_metadata_winner_sentinel),
             "raw winner sentinel 绝不能出现在请求结果 / 固定外部信封里"

      refute String.contains?(log, @correction_metadata_winner_sentinel),
             "raw winner sentinel 绝不能进日志"
    end

    @tag :task3_g2_green_review_correction
    test "g2r2 winner: a finalize-pending winner carrying an unrelated canonical wrapper is incompatible",
         ctx do
      key = "g2r2-winner-unrelated.bin"

      {result, winner, sql, log} =
        gated_finalize_sql_race!(
          ctx,
          key,
          "winner unrelated wrapper",
          {:ok, {:cleanup_pending, cleanup_pending_summary()}},
          fn observed ->
            # 第三个「独立看也合法」的 canonical wrapper + 无关 stable code：
            # 既不是 observed 的，也不是本 intent 纯构造的 merged wrapper。
            ObjectMutation.mark_error(
              observed,
              "published_proof_failed:finalize:corrupt",
              unrelated_canonical_wrapper(observed)
            )
          end
        )

      assert result == {:error, @correction_internal_envelope},
             "valid-but-unrelated wrapper/code 的 winner 必须 fail closed：#{inspect(result)}"

      assert_winner_frozen!(ctx, key, winner, log, "unrelated_wrapper")
      assert_cas_loss_sql!(sql, "unrelated_wrapper")
      assert_call_counts!("unrelated_wrapper", 1, 1, 0)
    end

    @tag :task3_g2_green_review_correction
    test "g2r2 winner: a phase regression from finalize_pending to metadata_committed is incompatible",
         ctx do
      key = "g2r2-winner-regression.bin"

      {result, winner, sql, log} =
        gated_finalize_sql_race!(
          ctx,
          key,
          "winner phase regression",
          {:ok, {:cleanup_pending, cleanup_pending_summary()}},
          fn observed ->
            # 状态图不允许回退，因此用**测试进程**的窄 update_all 直接播种非法回退赢家。
            # 该 SQL 由 pid filter 排除在 request query 计数之外。
            seed_row!(observed, phase: "metadata_committed", attempts: observed.attempts + 1)
          end
        )

      assert result == {:error, @correction_internal_envelope},
             "phase 回退的 winner 必须 fail closed：#{inspect(result)}"

      assert_winner_frozen!(ctx, key, winner, log, "phase_regression")
      assert_cas_loss_sql!(sql, "phase_regression")
      assert_call_counts!("phase_regression", 1, 1, 0)
    end

    @tag :task3_g2_green_review_correction
    test "g2r2 winner: an attempts-flat winner with tampered scheduling scalars is incompatible",
         ctx do
      key = "g2r2-winner-scalars.bin"

      {result, winner, sql, log} =
        gated_finalize_sql_race!(
          ctx,
          key,
          "winner tampered scalars",
          {:ok, {:cleanup_pending, cleanup_pending_summary()}},
          fn observed ->
            # attempts 不变，但 lease/next_attempt_at 被改写：CAS 的 lease 匹配必然落空，
            # 且 attempts 未增时这些调度标量必须与 observed 严格一致。
            seed_row!(observed,
              lease_owner: "g2r2-tamper",
              lease_expires_at: DateTime.add(DateTime.utc_now(), 3600, :second),
              next_attempt_at: DateTime.add(DateTime.utc_now(), 7200, :second)
            )
          end
        )

      assert result == {:error, @correction_internal_envelope},
             "attempts 未增却篡改调度/lease 标量的 winner 必须 fail closed：#{inspect(result)}"

      assert_winner_frozen!(ctx, key, winner, log, "tampered_scalars")
      assert_cas_loss_sql!(sql, "tampered_scalars")
      assert_call_counts!("tampered_scalars", 1, 1, 0)
    end

    @tag :task3_g2_green_review_correction
    test "g2r2 winner: a finalize-pending winner whose fingerprint diverges is incompatible",
         ctx do
      key = "g2r2-winner-fingerprint.bin"

      {result, winner, sql, log} =
        gated_finalize_sql_race!(
          ctx,
          key,
          "winner fingerprint divergence",
          {:ok, {:cleanup_pending, cleanup_pending_summary()}},
          fn observed ->
            seed_row!(observed,
              published_fingerprint: @fingerprint,
              attempts: observed.attempts + 1
            )
          end
        )

      assert result == {:error, @correction_internal_envelope},
             "fingerprint 与 observed 不一致的 winner 必须 fail closed：#{inspect(result)}"

      assert_winner_frozen!(ctx, key, winner, log, "fingerprint_divergence")
      assert_cas_loss_sql!(sql, "fingerprint_divergence")
      assert_call_counts!("fingerprint_divergence", 1, 1, 0)
    end

    # 公共 idempotent control：按 ObjectMutation 既有契约是 0 UPDATE + 1 SELECT。
    # 它**不能**替代上面的真实 CAS-loss cells。
    @tag :task3_g2_green_review_correction
    test "g2r2 control: an already-target-phase transition is 0 UPDATE and 1 SELECT", ctx do
      key = "g2r2-idempotent-control.bin"
      journal = published_journal(ctx, key)
      {:ok, committed} = ObjectMutation.transition(journal, "metadata_committed")
      {:ok, pending} = ObjectMutation.transition(committed, "finalize_pending")

      {{:ok, _row}, sql} =
        capture_journal_sql(self(), fn ->
          ObjectMutation.transition(pending, "finalize_pending")
        end)

      assert sql.updates == 0, "已处于目标 phase 的 transition 不得发出 UPDATE"
      assert sql.selects == 1, "已处于目标 phase 的 transition 恰好一次 SELECT"
    end

    # --- §6.2 complete scalar controls ---

    @tag :task3_g2_green_review_correction
    test "g2r2 scalar: a cleanup competitor with identical code and evidence but a different backoff defers",
         ctx do
      key = "g2r2-scalar-backoff.bin"
      summary = cleanup_pending_summary()

      {result, winner, sql, log} =
        gated_finalize_sql_race!(
          ctx,
          key,
          "cleanup backoff competitor",
          {:ok, {:cleanup_pending, summary}},
          fn observed ->
            # 同 code、同 canonical merged evidence，只有 backoff 不同：
            # 它绝不能被误判为本次 intent 的证明。
            {:ok, merged} =
              PublishedProof.merge_failure(
                "finalize_pending",
                observed.recovery_evidence,
                summary
              )

            ObjectMutation.mark_error(
              observed,
              "published_proof_cleanup_pending:finalize",
              merged,
              backoff_ms: 987_654
            )
          end
        )

      assert {:ok, _} = result, "cleanup 请求语义保留为成功"

      # 但绝不加速：winner 是竞争者写入的行，不是本请求证明的行。
      assert_winner_frozen!(ctx, key, winner, log, "cleanup_backoff")

      # 真实 CAS-loss 路径的精确 Repo 取证：恰好 1 UPDATE + 2 SELECT，
      # 绝无第二次写入（此前本格丢弃了 `_sql`，只是「看起来」被证明）。
      assert_cas_loss_sql!(sql, "cleanup_backoff")
      assert_call_counts!("cleanup_backoff", 1, 1, 0)
    end

    @tag :task3_g2_green_review_correction
    test "g2r2 scalar: a finalized competitor that leaves the lease uncleared is incompatible",
         ctx do
      key = "g2r2-scalar-lease.bin"

      {result, winner, sql, log} =
        finalized_lease_injection_race!(ctx, key, "finalized lease competitor")

      assert result == {:error, @correction_internal_envelope},
             "未清 lease 的 finalized 行不证明 terminal intent：#{inspect(result)}"

      assert_winner_frozen!(ctx, key, winner, log, "finalized_lease")
      refute is_nil(winner.lease_owner), "控制组必须真的留下未清的 lease"

      # 非证明性的 `{:ok, row}` 路径：terminal CAS 的那一次 UPDATE 与 `cas_result` 的
      # 那一次 SELECT，此外**既无第二次写入、也无 seam refetch**。
      assert sql.updates == 1,
             "finalized_lease：terminal CAS UPDATE 必须恰好一次，实际 #{sql.updates}：#{inspect(sql.queries)}"

      assert sql.selects == 1,
             "finalized_lease：`{:ok, row}` 路径必须恰好一次 SELECT（无 refetch），实际 #{sql.selects}：#{inspect(sql.queries)}"
    end

    @tag :task3_g2_green_review_correction
    test "g2r2 scalar: a malformed wrapper with a backend finalized result never terminalizes",
         ctx do
      key = "g2r2-scalar-malformed-finalized.bin"
      wrapper = correction_malformed_wrapper()

      {{result, snapshot}, log} =
        with_log(@correction_capture_opts, fn ->
          gated_finalize_with_metadata!(
            ctx,
            key,
            "malformed finalized content",
            {:ok, {:finalized, finalized_summary()}},
            metadata_tx: correction_wrapper_metadata_tx(ctx.bucket, key, wrapper)
          )
        end)

      # callback 恰好执行一次，但 finalized 不做 merge——它必须单独过同一个 durable 权威门。
      assert Script.call_count(:finalize_if_current) == 1
      assert Script.remaining(:finalize_if_current) == 0

      assert result == {:error, {:published_proof_contract_violation, :finalize}},
             "畸形 wrapper 下的 finalized 必须走 pure durable contract violation：#{inspect(result)}"

      journal = journal_for(ctx, key)
      assert journal.phase == "quarantined", "绝不 terminalize 为 finalized"
      refute journal.phase == "finalized"
      assert journal.last_error == "published_proof_contract_violation:finalize"
      assert journal.recovery_evidence === wrapper
      assert Jason.encode!(journal.recovery_evidence) == snapshot.wrapper_bytes
      assert journal.published_fingerprint === snapshot.fingerprint
      assert journal.attempts == snapshot.attempts
      assert is_nil(journal.finalized_at), "绝不写 finalized_at"

      refute String.contains?(log, @correction_callback_sentinel)
      refute_due!(journal, "malformed_finalized")
    end

    @tag :task3_g2_green_review_correction
    test "g2r2 scalar: exact intended terminal and mark-error rows are still accepted", ctx do
      # 防止 proof 过严：无竞争者时 finalized 与 cleanup 必须照常收敛。
      key_final = "g2r2-scalar-accept-final.bin"

      {result_final, _snapshot} =
        gated_finalize!(
          ctx,
          key_final,
          "accept finalized",
          {:ok, {:finalized, finalized_summary()}}
        )

      assert {:ok, _} = result_final, "无竞争的 finalized 必须仍被接受"
      assert journal_for(ctx, key_final).phase == "finalized"
    end

    @tag :task3_g2_green_review_correction
    test "g2r2 scalar: an uncontended cleanup mark_error row is still accepted", ctx do
      key = "g2r2-scalar-accept-cleanup.bin"

      {result, _snapshot} =
        gated_finalize!(
          ctx,
          key,
          "accept cleanup",
          {:ok, {:cleanup_pending, cleanup_pending_summary()}}
        )

      assert {:ok, _} = result, "无竞争的 cleanup 必须仍被接受"

      journal = journal_for(ctx, key)
      assert journal.phase == "finalize_pending"
      assert journal.last_error == "published_proof_cleanup_pending:finalize"
    end
  end

  # ── G2 Green review correction R1 fixtures ──

  # 属于 canonical wrapper 命名空间（两个键齐备）但 `published_proof` 不是合法 aggregate
  # summary：`PublishedProof.merge_failure/3` 必然拒绝它，而它本身完全 JSON-safe，
  # 因此可以原样持久化进 journal。绝不削弱 PublishedProof。
  defp correction_malformed_wrapper do
    %{
      "published_proof" => %{"g2r1_marker" => @correction_wrapper_marker},
      "last_failure" => nil
    }
  end

  # 在 metadata 事务期间把 marker 1 写进 journal，使 fresh pending 行在 finalize 之前
  # 就已经逐字携带该畸形 wrapper。
  defp correction_wrapper_metadata_tx(bucket, key, wrapper) do
    fn journal, published, write_info ->
      result = default_metadata_tx(bucket, key, journal, published, write_info)
      committed = ObjectMutation.get(journal.id)
      assert committed.phase == "metadata_committed"
      {:ok, _} = ObjectMutation.mark_error(committed, "g2r1_wrapper_injected", wrapper)
      result
    end
  end

  defp correction_snapshot(journal) do
    %{
      phase: journal.phase,
      attempts: journal.attempts,
      last_error: journal.last_error,
      fingerprint: journal.published_fingerprint,
      wrapper: journal.recovery_evidence,
      wrapper_bytes: Jason.encode!(journal.recovery_evidence)
    }
  end

  # 保留取证的确定性扰动：只加一次 attempts + 写稳定 code，fingerprint 与 evidence 不动。
  defp correction_probe(journal),
    do: ObjectMutation.mark_operational_error(journal, @correction_probe_code)

  # 终态幂等赢家：**不**改 attempts，只把同一个目标终态连同不同的 code/evidence 写下去。
  defp correction_terminal_winner(journal, phase) do
    ObjectMutation.transition(journal, phase, %{
      last_error: @correction_winner_code,
      recovery_evidence: %{"g2r1_winner" => phase}
    })
  end

  defp correction_write_loss_count(log),
    do: length(String.split(log, @correction_write_loss_code)) - 1

  defp assert_call_counts!(label, verify, finalize, restore) do
    assert Script.call_count(:verify_published) == verify, "#{label}：verify 调用次数必须精确"
    assert Script.call_count(:finalize_if_current) == finalize, "#{label}：直接 finalize 调用次数必须精确"
    assert Script.call_count(:restore_if_current) == restore, "#{label}：restore 调用次数必须精确"
  end

  # 赢家逐字不变 + 恰好一条固定写丢失日志 + 无 raw/CAS/sentinel 泄漏。
  defp assert_winner_intact!(ctx, key, snapshot, log, label) do
    journal = journal_for(ctx, key)

    assert journal.phase == snapshot.phase, "#{label}：赢家 phase 必须不变"
    assert journal.attempts == snapshot.attempts, "#{label}：赢家 attempts 必须不变"
    assert journal.last_error === snapshot.last_error, "#{label}：赢家 code 必须不变"

    assert journal.published_fingerprint === snapshot.fingerprint,
           "#{label}：赢家 fingerprint 必须不变"

    assert journal.recovery_evidence === snapshot.wrapper, "#{label}：赢家 evidence term 必须不变"

    assert Jason.encode!(journal.recovery_evidence) == snapshot.wrapper_bytes,
           "#{label}：赢家 evidence JSON 字节必须不变"

    assert correction_write_loss_count(log) == 1,
           "#{label}：必须恰好记录一条固定写丢失日志（既不静默、也不重复重试）"

    refute String.contains?(log, @correction_callback_sentinel), "#{label}：sentinel 绝不进日志"
    refute String.contains?(log, "stale_journal"), "#{label}：raw CAS 原因绝不进日志"
    refute String.contains?(log, @correction_wrapper_marker), "#{label}：raw evidence 绝不进日志"

    journal
  end

  defp assert_merge_rejection!(ctx, label, finalize_result) do
    key = "g2r1-merge-#{label}.bin"
    wrapper = correction_malformed_wrapper()

    # 该 finalize 结果必须真的通过冻结的 Storage callback validator——否则它会被折叠成
    # callback contract violation，本格就测不到「纯 merge 拒绝」。
    assert PublishedProof.validate_callback_result(:finalize, finalize_result) == :ok,
           "#{label}：脚本 finalize 结果必须通过冻结的 validator"

    {{result, snapshot}, log} =
      with_log(@correction_capture_opts, fn ->
        gated_finalize_with_metadata!(
          ctx,
          key,
          "merge rejection content",
          finalize_result,
          metadata_tx: correction_wrapper_metadata_tx(ctx.bucket, key, wrapper)
        )
      end)

    # 直接 finalize callback 恰好执行一次，脚本条目精确消费。
    assert Script.call_count(:finalize_if_current) == 1,
           "#{label}：直接 finalize 必须恰好被调用一次"

    assert Script.remaining(:finalize_if_current) == 0, "#{label}：脚本条目必须被精确消费"

    assert result == {:error, {:published_proof_contract_violation, :finalize}},
           "#{label}：merge 拒绝必须返回固定 finalize 契约错误，绝不返回原 union 或 cleanup 成功，实际：#{inspect(result)}"

    journal = journal_for(ctx, key)

    assert journal.phase == "quarantined", "#{label}：merge 拒绝必须 evidence-preserving 隔离"
    assert journal.last_error == "published_proof_contract_violation:finalize"
    refute String.contains?(journal.last_error, "\"")

    # marker 1：畸形 wrapper 的 term、完整 JSON 字节与 fingerprint 全部逐字不变。
    assert journal.recovery_evidence === wrapper, "#{label}：畸形 wrapper term 必须逐字保留"
    assert journal.recovery_evidence === snapshot.wrapper
    assert Jason.encode!(journal.recovery_evidence) == snapshot.wrapper_bytes
    assert journal.published_fingerprint === snapshot.fingerprint
    assert journal.attempts == snapshot.attempts

    # 绝不回滚、绝不 restore；backup 保留。
    refute journal.phase in ["rollback_pending", "rolled_back"]
    assert Script.call_count(:restore_if_current) == 0, "#{label}：merge 拒绝绝不触发 restore"
    refute mutation_dirs(ctx) == [], "#{label}：merge 拒绝必须保留 backup"

    # marker 2：callback-only raw sentinel 绝不出现在结果、journal 或日志里。
    refute String.contains?(inspect(result), @correction_callback_sentinel)
    refute String.contains?(inspect(journal), @correction_callback_sentinel)
    refute String.contains?(log, @correction_callback_sentinel)

    refute_due!(journal, label)
  end

  defp gated_finalize_with_metadata!(ctx, key, content, finalize_result, opts) do
    owner = self()
    ref = make_ref()

    Script.script(:finalize_if_current, {:gate, owner, ref, {:return, finalize_result}})

    task = Task.async(fn -> protocol_put(ctx, content, [key: key] ++ opts) end)

    entered = await_gate!(ref, "finalize_if_current")
    assert entered.operation == :finalize_if_current
    assert entered.ref == ref

    pending = journal_for(ctx, key)
    snapshot = correction_snapshot(pending)

    send(entered.caller, {:script_backend_release, ref})
    {Task.await(task, 15_000), snapshot}
  end

  # 在直接 finalize gate 上取到 Commit 已观察到的那一行，用一个确定性的 ObjectMutation
  # 操作制造 CAS 赢家，再放行请求。零 sleep、零轮询、零游离进程。
  defp gated_finalize_race!(ctx, key, content, finalize_result, perturb) do
    with_log(@correction_capture_opts, fn ->
      owner = self()
      ref = make_ref()

      Script.script(:finalize_if_current, {:gate, owner, ref, {:return, finalize_result}})
      task = Task.async(fn -> protocol_put(ctx, content, key: key) end)

      entered = await_gate!(ref, "finalize_if_current")
      assert entered.operation == :finalize_if_current

      observed = journal_for(ctx, key)
      assert observed.phase == "finalize_pending"
      {:ok, winner} = perturb.(observed)

      send(entered.caller, {:script_backend_release, ref})
      {Task.await(task, 15_000), correction_snapshot(winner)}
    end)
  end

  defp cleanup_pending_summary_with_sentinel do
    {:ok, {:cleanup_pending, summary}} =
      PublishedProof.classify_finalize(1, [
        {"ordinal:0", PublishedProof.endpoint_finalized("ordinal:0", %{})},
        {"ordinal:1",
         PublishedProof.endpoint_cleanup_pending("ordinal:1", %{
           code: @correction_callback_sentinel
         })}
      ])

    summary
  end

  defp finalize_failure_with_sentinel(class) do
    {:error, {:published_proof_failed, ^class, summary}} =
      PublishedProof.classify_finalize(1, [
        {"local",
         PublishedProof.endpoint_finalize_failed(class, "local", %{
           owned: true,
           code: @correction_callback_sentinel
         })}
      ])

    {:error, {:published_proof_failed, class, summary}}
  end

  # `endpoint_finalize_superseded/1` 不接受 attrs，因此 marker 2 只能显式挂到那条
  # superseded detail 的可选 `code` 字段上——"code" 属于冻结的 endpoint finalize 键集合
  # 且满足 safe-text 约束，故该结果仍完整通过 Storage validator，不削弱任何校验。
  defp finalize_superseded_summary_with_sentinel do
    summary = finalize_superseded_summary()
    [witness | rest] = summary["degraded"]

    Map.put(summary, "degraded", [
      Map.put(witness, "code", @correction_callback_sentinel) | rest
    ])
  end

  # ── G2 Green review correction R2 fixtures ──

  # AST 所有权分析器：把源码解析成真实语法树，再把每个 `defp` 子句拆成
  #   * 头部签名 `{name, [tag, ...]}`（tuple 模式 = **消费者**）
  #   * 表达式体（唯一可能出现**生产者**与 policy 供给的位置）
  # 行数、注释、换行格式一律不参与判定。
  defp accelerator_report(source) do
    clauses = source |> Code.string_to_quoted!() |> defp_clauses()

    %{
      clauses: Enum.map(clauses, fn {signature, _body} -> signature end),
      producers: accelerator_nodes(clauses, &producer_node?/1),
      policies: accelerator_nodes(clauses, &policy_node?/1),
      carriers:
        for(
          {signature, body} <- clauses,
          count_nodes(body, &(&1 == :accelerate)) > 0,
          do: signature
        )
    }
  end

  defp accelerator_violations(report) do
    Enum.reject(
      [
        report.producers != [@accelerate_producer_signature] && :producer_ownership,
        Enum.sort(report.policies) != Enum.sort(@accelerate_policy_signatures) &&
          :policy_ownership,
        Enum.sort(report.carriers) != Enum.sort(@accelerate_carrier_signatures) &&
          :carrier_ownership
      ],
      &(&1 == false)
    )
  end

  # 每个匹配节点各计一次：同一子句里出现两个生产者也会被识别为两项。
  defp accelerator_nodes(clauses, matcher) do
    Enum.flat_map(clauses, fn {signature, body} ->
      List.duplicate(signature, count_nodes(body, matcher))
    end)
  end

  # 三元 tuple 在 AST 里是 `{:{}, _, [...]}`，因此 `{:request_ok, row, :accelerate}` 的
  # **构造**只能长这个样子；函数头里的同形模式不在 body 内，天然被排除。
  defp producer_node?({:{}, _meta, [:request_ok, _row, :accelerate]}), do: true
  defp producer_node?(_node), do: false

  # 二元 tuple 是字面量：body 里的 `{:success, :accelerate}` 即 policy 供给点。
  defp policy_node?({:success, :accelerate}), do: true
  defp policy_node?(_node), do: false

  defp count_nodes(ast, matcher) do
    {_ast, count} =
      Macro.prewalk(ast, 0, fn node, acc ->
        {node, if(matcher.(node), do: acc + 1, else: acc)}
      end)

    count
  end

  defp defp_clauses(ast) do
    {_ast, clauses} =
      Macro.prewalk(ast, [], fn
        {:defp, _meta, [head, body]} = node, acc when is_list(body) ->
          case Keyword.fetch(body, :do) do
            {:ok, expression} -> {node, [{head_signature(head), expression} | acc]}
            :error -> {node, acc}
          end

        node, acc ->
          {node, acc}
      end)

    Enum.reverse(clauses)
  end

  defp head_signature({:when, _meta, [call | _guards]}), do: head_signature(call)

  defp head_signature({name, _meta, args}) when is_atom(name) and is_list(args),
    do: {name, Enum.map(args, &head_tag/1)}

  defp head_signature({name, _meta, nil}) when is_atom(name), do: {name, []}

  # 模式的构造标签：两个 atom 的 tuple 保留完整对（区分 `{:success, :accelerate}` 与
  # `{:success, :defer}`），否则只取首元素 atom；其余一律记 `:_`。
  #
  # 【R2 I1】`pattern = var` 绑定必须取被匹配的**模式**一侧，结构体模式必须保留结构体名
  # 与被钉死的 `:phase` 字面量——否则 `%Journal{phase: "finalized"}` 会和泛型 journal
  # 变量塌缩成同一个签名，删掉 already-finalized 子句也照样绿。
  defp head_tag({:=, _meta, [pattern, _var]}), do: head_tag(pattern)

  defp head_tag({:%, _meta, [{:__aliases__, _alias_meta, parts}, {:%{}, _fields_meta, fields}]}),
    do: {:struct, List.last(parts), Keyword.get(fields, :phase, :_)}

  defp head_tag({tag, second}) when is_atom(tag) and is_atom(second), do: {tag, second}
  defp head_tag({tag, _rest}) when is_atom(tag), do: tag
  defp head_tag({:{}, _meta, [tag | _rest]}) when is_atom(tag), do: tag
  defp head_tag(tag) when is_atom(tag), do: tag
  defp head_tag(_node), do: :_

  # 复用既有 `[:maxio, :repo, :query]` telemetry 模式，但按发出 SQL 的 pid 归属，
  # 从而只统计 request task 自己的语句；测试进程的注入 SQL 被自动排除。
  defp capture_journal_sql(pid, fun) do
    ref = make_ref()
    parent = self()
    handler_id = {:g2r2_repo_capture, ref}

    :telemetry.attach(
      handler_id,
      [:maxio, :repo, :query],
      fn _event, _measurements, metadata, _config ->
        send(parent, {ref, self(), metadata.query})
      end,
      nil
    )

    try do
      result = fun.()
      :telemetry.detach(handler_id)
      {result, journal_sql_counts(drain_sql(ref, []), pid)}
    after
      :telemetry.detach(handler_id)
    end
  end

  defp drain_sql(ref, acc) do
    receive do
      {^ref, pid, query} -> drain_sql(ref, [{pid, query} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp journal_sql_counts(entries, pid) do
    mine =
      Enum.filter(entries, fn {p, q} -> p == pid and String.contains?(q, "object_mutations") end)

    %{
      updates: Enum.count(mine, fn {_p, q} -> String.starts_with?(q, "UPDATE") end),
      selects: Enum.count(mine, fn {_p, q} -> String.starts_with?(q, "SELECT") end),
      queries: Enum.map(mine, fn {_p, q} -> q end)
    }
  end

  # 真实 CAS-attempt 路径：恰好一次 action UPDATE，绝无第二次 UPDATE。
  # `{:error, _}` 路径恰好两次 SELECT（action 内 repo.get + seam refetch）。
  defp assert_cas_loss_sql!(sql, label) do
    assert sql.updates == 1,
           "#{label}：action CAS UPDATE 必须恰好一次（绝无第二次写入），实际 #{sql.updates}：#{inspect(sql.queries)}"

    assert sql.selects == 2,
           "#{label}：`{:error, _}` 路径必须恰好两次 SELECT（action repo.get + seam refetch），实际 #{sql.selects}"
  end

  # winner 逐字冻结：无论被接受还是被拒绝，原 row 都不得被规范化/修复/改写。
  #
  # 【correction R2 §3.3】权威字段清单直接取自 `Journal.__schema__(:fields)`——包含全部
  # 生命周期与 insert/update 时间戳。绝不在测试里另维护一份手写的部分字段列表。
  defp assert_winner_frozen!(ctx, key, winner, log, label) do
    final = journal_for(ctx, key)

    fields = Journal.__schema__(:fields)
    assert length(fields) > 0

    for field <- fields do
      assert Map.fetch!(final, field) === Map.fetch!(winner, field),
             "#{label}：winner 持久化字段 #{field} 不得被改写"
    end

    # 证据的编码字节也必须逐字相同（term 相等之外的独立取证）。
    assert Jason.encode!(final.recovery_evidence) == Jason.encode!(winner.recovery_evidence)

    assert correction_write_loss_count(log) == 1,
           "#{label}：必须恰好一条固定安全日志，实际 #{correction_write_loss_count(log)}"

    refute String.contains?(log, "stale_journal"), "#{label}：raw CAS 原因绝不进日志"
    refute String.contains?(log, @correction_callback_sentinel)
    refute String.contains?(log, @correction_wrapper_marker)

    final
  end

  # 窄口径 update_all 播种：只用于构造公共 API 无法表达的非法赢家（phase 回退、
  # 篡改的调度标量、发散的 fingerprint）。它由测试进程发出，被 pid filter 排除。
  defp seed_row!(journal, sets) do
    {1, _} =
      Repo.update_all(
        from(j in Journal, where: j.id == ^journal.id),
        set: sets
      )

    {:ok, ObjectMutation.get(journal.id)}
  end

  # 无关但独立看合法的 canonical wrapper：由另一个 finalize failure summary 合并而来。
  defp unrelated_canonical_wrapper(journal) do
    {:error, {:published_proof_failed, :corrupt, summary}} = finalize_failure(:corrupt)

    {:ok, merged} =
      PublishedProof.merge_failure("finalize_pending", journal.recovery_evidence, summary)

    merged
  end

  # fence race：gate 在 `:object_mutation_after_metadata_commit`，observed 为
  # metadata_committed（非目标 phase），因此必然真正进入一次 CAS attempt。
  defp fence_race!(ctx, key, content, perturb) do
    owner = self()
    ref = make_ref()

    Failpoint.arm(
      :object_mutation_after_metadata_commit,
      {:fun,
       fn ->
         send(owner, {:fence_gate, ref, self()})

         receive do
           {:fence_release, ^ref} -> :ok
         after
           5_000 -> raise(RuntimeError, message: "fence gate timeout")
         end
       end}
    )

    on_exit(fn -> Failpoint.disarm(:object_mutation_after_metadata_commit) end)

    {{result, winner, sql}, log} =
      with_log(@correction_capture_opts, fn ->
        task = Task.async(fn -> protocol_put(ctx, content, key: key) end)

        assert_receive {:fence_gate, ^ref, gate_pid}, 5_000

        observed = journal_for(ctx, key)
        assert observed.phase == "metadata_committed"
        {:ok, winner} = perturb.(observed)

        {result, sql} =
          capture_journal_sql(gate_pid, fn ->
            send(gate_pid, {:fence_release, ref})
            Task.await(task, 15_000)
          end)

        {result, winner, sql}
      end)

    {result, winner, sql, log}
  end

  # finalize race + SQL 取证：gate 在直接 finalize callback 上，observed 为
  # finalize_pending，perturb 之后释放，只统计 request task 释放后的语句。
  defp gated_finalize_sql_race!(ctx, key, content, finalize_result, perturb) do
    owner = self()
    ref = make_ref()

    Script.script(:finalize_if_current, {:gate, owner, ref, {:return, finalize_result}})

    {{result, winner, sql}, log} =
      with_log(@correction_capture_opts, fn ->
        task = Task.async(fn -> protocol_put(ctx, content, key: key) end)

        entered = await_gate!(ref, "finalize_if_current")
        observed = journal_for(ctx, key)
        assert observed.phase == "finalize_pending"
        {:ok, winner} = perturb.(observed)

        {result, sql} =
          capture_journal_sql(entered.caller, fn ->
            send(entered.caller, {:script_backend_release, ref})
            Task.await(task, 15_000)
          end)

        {result, winner, sql}
      end)

    {result, winner, sql, log}
  end

  # 【§6.2】finalized lease 控制：用既有 Repo telemetry 做确定性 post-UPDATE gate。
  # 只捕获 request task 对 object_mutations 的 terminal UPDATE；SQL 已完成但 handler
  # 尚未返回、`cas_result` 尚未 `repo.get` 时，测试进程用窄 update_all **只**改 lease pair，
  # 保留请求刚写入的 exact timestamp/code/evidence/fingerprint/attempts，再释放 handler。
  # 绝不猜测 intent 的私有微秒时钟，也绝不新增 production clock seam。
  #
  # 【correction R2 §3.1】gate 之外**同时**按 request pid 采集 Repo telemetry：测试进程的
  # lease 注入 SQL 与 `journal_for/2` 读取都被 pid filter 排除，因此返回的计数就是请求
  # 自己在 `{:ok, row}` 非证明路径上的精确 1 UPDATE + 1 SELECT。
  defp finalized_lease_injection_race!(ctx, key, content) do
    owner = self()
    ref = make_ref()
    gate_ref = make_ref()
    handler_id = {:g2r2_lease_gate, gate_ref}

    Script.script(
      :finalize_if_current,
      {:gate, owner, ref, {:return, {:ok, {:finalized, finalized_summary()}}}}
    )

    {{result, winner, sql}, log} =
      with_log(@correction_capture_opts, fn ->
        task = Task.async(fn -> protocol_put(ctx, content, key: key) end)

        entered = await_gate!(ref, "finalize_if_current")
        observed = journal_for(ctx, key)
        assert observed.phase == "finalize_pending"
        request_pid = entered.caller

        :telemetry.attach(
          handler_id,
          [:maxio, :repo, :query],
          fn _event, _measurements, metadata, _config ->
            if self() == request_pid and String.starts_with?(metadata.query, "UPDATE") and
                 String.contains?(metadata.query, "object_mutations") do
              send(owner, {:terminal_update, gate_ref, self()})

              receive do
                {:terminal_update_release, ^gate_ref} -> :ok
              after
                5_000 -> :ok
              end
            end
          end,
          nil
        )

        {{result, winner}, sql} =
          capture_journal_sql(request_pid, fn ->
            send(request_pid, {:script_backend_release, ref})

            # terminal UPDATE 的 SQL 已完成，但 handler 阻塞在这里，`cas_result` 尚未 repo.get。
            assert_receive {:terminal_update, ^gate_ref, ^request_pid}, 5_000

            {:ok, winner} =
              seed_row!(observed,
                lease_owner: "g2r2-uncleared-lease",
                lease_expires_at: DateTime.add(DateTime.utc_now(), 3600, :second)
              )

            send(request_pid, {:terminal_update_release, gate_ref})
            {Task.await(task, 15_000), winner}
          end)

        :telemetry.detach(handler_id)

        {result, winner, sql}
      end)

    :telemetry.detach(handler_id)
    {result, winner, sql, log}
  end

  # ── G2 fixtures ──

  # G2 consolidation §3：**每一个** finalize disposition 分支都必须自己在 merge 之前经真实
  # gate 读一次 pending journal，快照 proof term / JSON 字节 / fingerprint，之后严格与该
  # 快照比对。没有任何运行时循环，每格独立可选。
  defp gated_finalize!(ctx, key, content, finalize_result) do
    owner = self()
    ref = make_ref()

    Script.script(:finalize_if_current, {:gate, owner, ref, {:return, finalize_result}})

    task = Task.async(fn -> protocol_put(ctx, content, key: key) end)

    entered = await_gate!(ref, "finalize_if_current")
    assert entered.operation == :finalize_if_current
    assert entered.ref == ref
    assert is_pid(entered.caller)
    assert %MutationContext{} = entered.ctx
    assert Keyword.fetch!(entered.opts, :data_dir) == ctx.dir

    # merge 之前的真实 pending 快照。
    pending = journal_for(ctx, key)
    assert %{"published_proof" => proof} = pending.recovery_evidence
    refute is_nil(proof), "finalize 之前 journal 必须已经持有 canonical successful proof"
    refute is_nil(pending.published_fingerprint)

    snapshot = %{
      proof: proof,
      bytes: Jason.encode!(proof),
      fingerprint: pending.published_fingerprint,
      # 【correction R1 §4.1】完整 wrapper（而不只是它的 "published_proof" 子项）也要
      # 被快照下来，供 evidence-preserving 分支做 term + 完整 JSON 字节的严格比对。
      wrapper: pending.recovery_evidence,
      wrapper_bytes: Jason.encode!(pending.recovery_evidence)
    }

    send(entered.caller, {:script_backend_release, ref})
    {Task.await(task, 15_000), snapshot}
  end

  # evidence-preserving 分支专用：完整 wrapper 的 term 与完整 JSON 字节都必须逐字不变。
  defp assert_wrapper_preserved!(journal, snapshot, label) do
    assert journal.recovery_evidence === snapshot.wrapper,
           "#{label}：完整 recovery_evidence wrapper term 必须逐字不变"

    assert Jason.encode!(journal.recovery_evidence) == snapshot.wrapper_bytes,
           "#{label}：完整 recovery_evidence wrapper 的 JSON 字节必须逐字不变"
  end

  # 终态行必须永远不出现在 recovery 到期队列里——即使注入极远的未来 now。
  # 协议并不要求 `next_attempt_at == nil`，因此这里断言的是 list_due 的真实排除语义。
  defp refute_due!(journal, label) do
    due =
      ObjectMutation.list_due(now: DateTime.add(DateTime.utc_now(), 3650, :day), limit: 1_000)

    refute Enum.any?(due, &(&1.id == journal.id)),
           "#{label}：终态行绝不能出现在 list_due（即使注入极远未来 now）"
  end

  defp assert_snapshot_preserved!(journal, snapshot, label) do
    assert %{"published_proof" => proof} = journal.recovery_evidence
    assert proof === snapshot.proof, "#{label}：初始 proof term 必须逐字不变"
    assert Jason.encode!(proof) == snapshot.bytes, "#{label}：初始 proof JSON 字节必须逐字不变"

    assert journal.published_fingerprint === snapshot.fingerprint,
           "#{label}：fingerprint 必须逐字不变"
  end

  # 等待脚本 backend 的完整 entered 记录；缺失时给出自解释的 RED 说明而不是裸超时。
  defp await_gate!(ref, label) do
    receive do
      {:script_backend_entered, %{ref: ^ref} = entered} ->
        entered
    after
      5_000 ->
        flunk(
          "#{label} gate 从未进入：旧生产在该点不调用对应的 Storage callback，" <>
            "因此这一步不存在可观察的边界"
        )
    end
  end

  # metadata 观察 seam：只用 owner-pid 消息，不用 Application env、不用 persistent_term。
  defp recording_metadata_tx(owner, bucket, key) do
    fn journal, published, write_info ->
      send(owner, {:metadata_entered, journal})
      default_metadata_tx(bucket, key, journal, published, write_info)
    end
  end

  # 阻塞式 metadata gate：把自己的 pid 一并送出，release 必须发回该 pid。
  defp gated_metadata_tx(owner, ref, bucket, key) do
    fn journal, published, write_info ->
      send(owner, {:metadata_entered, ref, self(), journal})

      receive do
        {:metadata_release, ^ref} -> :ok
      after
        5_000 -> raise(RuntimeError, message: "metadata gate #{inspect(ref)} timeout")
      end

      default_metadata_tx(bucket, key, journal, published, write_info)
    end
  end

  defp degraded_32_summary do
    failed =
      for index <- 1..32 do
        identity = "ordinal:#{index}"
        {identity, PublishedProof.failed(:unavailable, identity, %{owned: true})}
      end

    {:ok, {:degraded, summary}} =
      PublishedProof.classify(1, [{"local", PublishedProof.verified("local", %{})} | failed])

    summary
  end

  defp superseded_summary do
    {:ok, {:superseded, summary}} =
      PublishedProof.classify(1, [{"local", PublishedProof.superseded("local")}])

    summary
  end

  defp proof_failure(class) do
    {:error, {:published_proof_failed, ^class, summary}} =
      PublishedProof.classify(1, [
        {"local", PublishedProof.failed(class, "local", %{owned: true})}
      ])

    {:error, {:published_proof_failed, class, summary}}
  end

  defp finalized_summary do
    {:ok, {:finalized, summary}} =
      PublishedProof.classify_finalize(1, [
        {"local", PublishedProof.endpoint_finalized("local", %{})}
      ])

    summary
  end

  defp cleanup_pending_summary do
    {:ok, {:cleanup_pending, summary}} =
      PublishedProof.classify_finalize(1, [
        {"ordinal:0", PublishedProof.endpoint_finalized("ordinal:0", %{})},
        {"ordinal:1", PublishedProof.endpoint_cleanup_pending("ordinal:1", %{})}
      ])

    summary
  end

  defp finalize_superseded_summary do
    {:ok, {:superseded, summary}} =
      PublishedProof.classify_finalize(1, [
        {"local", PublishedProof.endpoint_finalize_superseded("local")}
      ])

    summary
  end

  defp finalize_failure(class) do
    {:error, {:published_proof_failed, ^class, summary}} =
      PublishedProof.classify_finalize(1, [
        {"local", PublishedProof.endpoint_finalize_failed(class, "local", %{owned: true})}
      ])

    {:error, {:published_proof_failed, class, summary}}
  end

  # ── helpers ──

  # 经真实 Storage.put + ObjectCommit seam 驱动协议化提交（与 handler around 同形）。
  defp protocol_put(ctx, content, opts \\ []) do
    bucket = ctx.bucket
    key = Keyword.get(opts, :key, @key)
    notify = Keyword.get(opts, :notify)
    metadata_tx = Keyword.get(opts, :metadata_tx, &default_metadata_tx(bucket, key, &1, &2, &3))

    # G2 correction §5：publish 闭包的**真实输入**是 claimed context 的唯一独立来源。
    publish_observer = Keyword.get(opts, :publish_observer)

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
            if publish_observer, do: publish_observer.(extra_commit_opts)
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
