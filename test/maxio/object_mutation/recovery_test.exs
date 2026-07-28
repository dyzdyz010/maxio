defmodule Maxio.ObjectMutation.RecoveryTest.PausingRestoreBackend do
  @moduledoc false
  # NEXT-3（B6 审查项 3 构造性覆盖）的同步点后端：restore_if_current 向测试进程报到并
  # 阻塞等待 {:continue, result} 指令——测试借此在 recovery「锁内、restore 之后、收敛
  # CAS 之前」的窗口并发扰动 journal，零 sleep（同步全靠消息收发）。其余 callback 全部
  # FS 委托（test/support 各 fake backend 同款，防 behaviour 警告与误驱动）。
  @behaviour Maxio.Storage.Backend

  alias Maxio.Storage.FS

  @impl true
  def restore_if_current(_ctx, _opts) do
    test_pid = Application.fetch_env!(:maxio, :pausing_restore_backend_test_pid)
    send(test_pid, {:restore_blocked, self()})

    receive do
      {:continue, result} -> result
    end
  end

  @impl true
  def put(bucket, key, version_id, chunks, opts),
    do: FS.put(bucket, key, version_id, chunks, opts)

  @impl true
  def get(bucket, key, version_id, range, opts),
    do: FS.get(bucket, key, version_id, range, opts)

  @impl true
  def stat(bucket, key, version_id, opts),
    do: FS.stat(bucket, key, version_id, opts)

  @impl true
  def delete(bucket, key, version_id, opts),
    do: FS.delete(bucket, key, version_id, opts)

  @impl true
  def put_bucket(bucket), do: FS.put_bucket(bucket)

  @impl true
  def delete_bucket(bucket), do: FS.delete_bucket(bucket)

  @impl true
  def put_part(bucket, key, upload_id, part_number, chunks, opts),
    do: FS.put_part(bucket, key, upload_id, part_number, chunks, opts)

  @impl true
  def get_part_stream(bucket, key, upload_id, part_number, opts),
    do: FS.get_part_stream(bucket, key, upload_id, part_number, opts)

  @impl true
  def assemble(bucket, key, upload_id, part_numbers, opts),
    do: FS.assemble(bucket, key, upload_id, part_numbers, opts)

  @impl true
  def abort_upload(bucket, key, upload_id, opts),
    do: FS.abort_upload(bucket, key, upload_id, opts)

  @impl true
  def put_delete_marker(bucket, key, version_id, entry_opts, opts),
    do: FS.put_delete_marker(bucket, key, version_id, entry_opts, opts)

  @impl true
  def delete_version(bucket, key, version_id, opts),
    do: FS.delete_version(bucket, key, version_id, opts)

  @impl true
  def put_notification_ledgers(bucket, key, entries, opts),
    do: FS.put_notification_ledgers(bucket, key, entries, opts)

  @impl true
  def list_notification_ledgers(bucket, key_filter, opts),
    do: FS.list_notification_ledgers(bucket, key_filter, opts)

  @impl true
  def delete_notification_ledgers(bucket, key, ids, opts),
    do: FS.delete_notification_ledgers(bucket, key, ids, opts)

  @impl true
  def claim_epoch(target, token, operation, opts),
    do: FS.claim_epoch(target, token, operation, opts)

  @impl true
  def current_epoch(target, opts), do: FS.current_epoch(target, opts)

  @impl true
  def finalize_if_current(ctx, opts), do: FS.finalize_if_current(ctx, opts)
end

defmodule Maxio.ObjectMutation.RecoveryTest do
  @moduledoc """
  ObjectMutation Phase 1 B6 —— recovery worker 决策表与 crash 收敛验收
  （FS 后端为主 + EC partial 契约切片 + Distributed placement 漂移切片）：

    1. PG commit 后 kill（failpoint `:after_metadata_commit` = `:kill_self`，真实 put 经
       Task + monitor 等 DOWN）→ run_now → journal=finalized、新字节保留、epoch=committed
       （Phase 1 头号验收上半）；
    2. metadata 前 kill（publish 后 owner kill）→ recovery → 旧字节恢复、journal=rolled_back
       （头号验收下半；含 Control 双杀「无加速器」与 owner 单杀「rollback_pending 收敛」
       两个形态，后者即 B5 移交项 1）；
    3. finalize 失败（failpoint raise 一次）→ 请求成功、finalize_pending → run_now → finalized；
    4. lease：过期租约被 recover 接管推进，stale 持有者 transition 拿 stale_journal 且库不变；
    5. superseded：迟到 published journal → rolled_back + successor 取证（B2 审查项 2 +
       B3 审查项 2：另行 current_epoch 取证），successor 三态不变；
    6. sidecar-authority published journal（直接构造，B5 范围备忘第 2 条）：epoch
       published → 必须 finalize；epoch 缺失/损坏 → quarantined；
    7. 对象锁被占 → skipped_locked、短 backoff、租约释放，解锁后收敛（R5 第二道防线）；
    8. Scheduler：enabled: false 不调度、run_now 同步返回统计、stale timer token 忽略；
    9. 锁内收敛 CAS 失败（journal_convergence_failed → log_no_action）主动释放租约
       （NEXT-3 / B6 审查项 3，Phase 2A C1 落地）：下一 worker 同刻可 claim，不等 60s 过期。

  另落实 B6 分配项：`:object_mutation_restore` failpoint 专项驱动、fresh put crash →
  对象 API 不可见（B2 审查项 4）、EC `{:partial,...}` 形状锁定 + 证据 stringify（B3
  审查项 1 + B3 节第 2 条）、Distributed placement 漂移 → quarantine。
  全部同步用 monitor/assert_receive + run_now，零 Process.sleep（工程准则）。
  """

  use Maxio.DataCase, async: false

  alias Maxio.{Buckets, Objects, ObjectMutation, Storage}
  alias Maxio.Cluster.Paths
  alias Maxio.Cluster.Topology
  alias Maxio.Cluster.Transport.InProcess
  alias Maxio.Failpoint
  alias Maxio.ObjectMutation.Commit
  alias Maxio.ObjectMutation.Journal
  alias Maxio.ObjectMutation.Recovery
  alias Maxio.ObjectMutation.Recovery.Scheduler
  alias Maxio.ObjectMutation.RecoveryTest.PausingRestoreBackend
  alias Maxio.Storage.{EpochStore, ErasureCoded, MutationBackup, MutationContext, ObjectEpoch}

  @key "obj.bin"
  @fingerprint %{
    "etag" => "abc",
    "size" => 3,
    "sidecar_sha256" => String.duplicate("ab", 32)
  }

  setup do
    dir = Path.join(System.tmp_dir!(), "maxio_omr_#{System.unique_integer([:positive])}")
    File.rm_rf(dir)
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)

    bucket = "omr-#{System.unique_integer([:positive])}"
    {:ok, _bucket} = Buckets.create(bucket, "arn:aws:iam:::root")

    %{dir: dir, bucket: bucket}
  end

  # ── 断言 1（头号验收上半）：PG commit 后 kill → finalize、新字节保留 ──

  test "PG commit 后 kill：run_now → journal=finalized、新字节保留、epoch=committed", ctx do
    old = "old content"
    {:ok, _} = Storage.put(ctx.bucket, @key, "null", [old], data_dir: ctx.dir)

    Failpoint.arm(:object_mutation_after_metadata_commit, :kill_self)
    on_exit(fn -> Failpoint.disarm(:object_mutation_after_metadata_commit) end)

    parent = self()
    new_content = "new content after pg commit"

    {:ok, owner} = Task.start(fn -> protocol_put(ctx, new_content, notify: parent) end)
    owner_ref = Process.monitor(owner)

    assert_receive {:write_info, %{object_commit_control: control}}, 5_000
    control_ref = Process.monitor(control)

    # 真实 put 在 PG 提交后被硬杀（:kill 不可捕获）；Control guard 判 metadata_committed
    # 拒绝回滚（{:halt}），只清 staging 后正常退出——新字节的终局收敛完全交给 recovery。
    assert_receive {:DOWN, ^owner_ref, :process, ^owner, :killed}, 5_000
    assert_receive {:DOWN, ^control_ref, :process, ^control, :normal}, 5_000
    Failpoint.disarm(:object_mutation_after_metadata_commit)

    journal = journal_for(ctx, @key)
    assert journal.phase == "metadata_committed"

    # crash 时刻三态：新字节已发布、epoch=published、PG 行已提交（分裂窗口的输入）
    assert File.read!(Path.join(final_dir(ctx), "part.0")) == new_content

    assert {:ok, %ObjectEpoch{phase: "published"}} =
             Storage.current_epoch(target(ctx), data_dir: ctx.dir)

    assert {:ok, %Objects.Object{}} = Objects.get_metadata(ctx.bucket, @key)
    refute mutation_dirs(ctx) == []

    stats = run_now!(now: future(), storage_opts: [data_dir: ctx.dir])

    assert %{
             claimed: 1,
             finalized: 1,
             rolled_back: 0,
             superseded: 0,
             quarantined: 0,
             retried: 0,
             skipped_locked: 0
           } = stats

    journal = ObjectMutation.get(journal.id)
    assert journal.phase == "finalized"
    assert not is_nil(journal.finalized_at)
    assert is_nil(journal.lease_owner)

    # 新字节保留、epoch=committed（同一 token）、PG 行不变、backup 已丢弃
    assert File.read!(Path.join(final_dir(ctx), "part.0")) == new_content

    assert {:ok, %ObjectEpoch{phase: "committed"} = epoch} =
             Storage.current_epoch(target(ctx), data_dir: ctx.dir)

    assert epoch.token == %{"generation" => journal.generation, "mutation_id" => journal.id}
    assert {:ok, %Objects.Object{}} = Objects.get_metadata(ctx.bucket, @key)
    assert mutation_dirs(ctx) == []
  end

  # ── 断言 2（头号验收下半）：metadata 前 kill → 旧字节恢复 ──

  test "metadata 前 kill（publish 后 control+owner 双杀，无加速器）：recovery 恢复旧字节", ctx do
    old = "old content"
    {:ok, _} = Storage.put(ctx.bucket, @key, "null", [old], data_dir: ctx.dir)

    parent = self()
    arm_pause(:object_mutation_before_metadata_commit)

    {:ok, owner} = Task.start(fn -> protocol_put(ctx, "new content", notify: parent) end)
    assert_receive {:write_info, %{object_commit_control: control}}, 5_000
    assert_receive {:paused, ^owner}, 5_000
    Failpoint.disarm(:object_mutation_before_metadata_commit)

    journal = journal_for(ctx, @key)
    assert journal.phase == "published"

    # 先杀 Control（加速器整体消失——它不承担 correctness），再杀 owner：published
    # journal 的终局决定完全由 recovery 依 journal + durable epoch 作出。
    control_ref = Process.monitor(control)
    Process.exit(control, :kill)
    assert_receive {:DOWN, ^control_ref, :process, ^control, :killed}, 5_000
    owner_ref = Process.monitor(owner)
    Process.exit(owner, :kill)
    assert_receive {:DOWN, ^owner_ref, :process, ^owner, :killed}, 5_000

    # crash 后中间态：新字节在 final、epoch=published、backup 保留、PG 无行
    assert File.read!(Path.join(final_dir(ctx), "part.0")) == "new content"
    assert {:error, :not_found} = Objects.get_metadata(ctx.bucket, @key)
    refute mutation_dirs(ctx) == []

    stats = run_now!(now: future(), storage_opts: [data_dir: ctx.dir])
    assert %{claimed: 1, rolled_back: 1, finalized: 0, superseded: 0, quarantined: 0} = stats

    # 旧字节逐字恢复、journal/epoch 双双 rolled_back、backup 清空、PG 仍无行
    journal = ObjectMutation.get(journal.id)
    assert journal.phase == "rolled_back"
    assert File.read!(Path.join(final_dir(ctx), "part.0")) == old

    assert {:ok, %ObjectEpoch{phase: "rolled_back"}} =
             Storage.current_epoch(target(ctx), data_dir: ctx.dir)

    assert {:error, :not_found} = Objects.get_metadata(ctx.bucket, @key)
    assert mutation_dirs(ctx) == []
  end

  test "Control-DOWN 停 rollback_pending（B5 移交项 1）：recovery 收敛 rolled_back", ctx do
    old = "old content"
    {:ok, _} = Storage.put(ctx.bucket, @key, "null", [old], data_dir: ctx.dir)

    parent = self()
    arm_pause(:object_mutation_before_metadata_commit)

    {:ok, owner} = Task.start(fn -> protocol_put(ctx, "new content", notify: parent) end)
    assert_receive {:write_info, %{object_commit_control: control}}, 5_000
    assert_receive {:paused, ^owner}, 5_000
    Failpoint.disarm(:object_mutation_before_metadata_commit)

    # 只杀 owner：Control guard 经 request_rollback 把 journal 停在 rollback_pending
    # 且 best-effort restore 已回位旧字节；rolled_back 终态收敛归 recovery。
    owner_ref = Process.monitor(owner)
    control_ref = Process.monitor(control)
    Process.exit(owner, :kill)
    assert_receive {:DOWN, ^owner_ref, :process, ^owner, :killed}, 5_000
    assert_receive {:DOWN, ^control_ref, :process, ^control, :normal}, 5_000

    journal = journal_for(ctx, @key)
    assert journal.phase == "rollback_pending"
    assert File.read!(Path.join(final_dir(ctx), "part.0")) == old

    # request_rollback 已把 next_attempt_at 置 now：无需时间注入即到期
    stats = run_now!(storage_opts: [data_dir: ctx.dir])
    assert %{claimed: 1, rolled_back: 1} = stats

    journal = ObjectMutation.get(journal.id)
    assert journal.phase == "rolled_back"
    assert not is_nil(journal.rolled_back_at)
    assert File.read!(Path.join(final_dir(ctx), "part.0")) == old
  end

  test ":object_mutation_restore failpoint（:kill_self）：restore 中途硬崩由 recovery 收敛", ctx do
    old = "old content"
    {:ok, _} = Storage.put(ctx.bucket, @key, "null", [old], data_dir: ctx.dir)

    Failpoint.arm(:object_mutation_restore, :kill_self)
    on_exit(fn -> Failpoint.disarm(:object_mutation_restore) end)

    parent = self()

    {:ok, owner} =
      Task.start(fn ->
        protocol_put(ctx, "new content",
          notify: parent,
          metadata_tx: fn _journal, _published, _write_info -> {:error, :metadata_boom} end
        )
      end)

    assert_receive {:write_info, %{object_commit_control: control}}, 5_000
    owner_ref = Process.monitor(owner)
    control_ref = Process.monitor(control)

    # metadata_tx 失败 → request_rollback（journal → rollback_pending）→ attempt_restore
    # 在 failpoint 处被硬杀；Control guard 幂等放行后 best-effort restore。
    assert_receive {:DOWN, ^owner_ref, :process, ^owner, _reason}, 5_000
    assert_receive {:DOWN, ^control_ref, :process, ^control, :normal}, 5_000
    Failpoint.disarm(:object_mutation_restore)

    journal = journal_for(ctx, @key)
    assert journal.phase == "rollback_pending"

    stats = run_now!(storage_opts: [data_dir: ctx.dir])
    assert %{claimed: 1, rolled_back: 1} = stats

    journal = ObjectMutation.get(journal.id)
    assert journal.phase == "rolled_back"
    assert File.read!(Path.join(final_dir(ctx), "part.0")) == old
    assert {:error, :not_found} = Objects.get_metadata(ctx.bucket, @key)
    assert mutation_dirs(ctx) == []
  end

  # fresh put crash → rollback：PG/API 不可见与盘上 physical absence 必须一致。
  test "fresh put crash → rollback → PG/API 不可见且 final 物理不存在", ctx do
    key = "fresh.bin"

    parent = self()
    arm_pause(:object_mutation_before_metadata_commit)

    {:ok, owner} =
      Task.start(fn -> protocol_put(ctx, "fresh content", key: key, notify: parent) end)

    assert_receive {:write_info, %{object_commit_control: control}}, 5_000
    assert_receive {:paused, ^owner}, 5_000
    Failpoint.disarm(:object_mutation_before_metadata_commit)

    owner_ref = Process.monitor(owner)
    control_ref = Process.monitor(control)
    Process.exit(owner, :kill)
    assert_receive {:DOWN, ^owner_ref, :process, ^owner, :killed}, 5_000
    assert_receive {:DOWN, ^control_ref, :process, ^control, :normal}, 5_000

    journal = journal_for(ctx, key)
    assert journal.phase == "rollback_pending"

    stats = run_now!(storage_opts: [data_dir: ctx.dir])
    assert %{claimed: 1, rolled_back: 1} = stats

    journal = ObjectMutation.get(journal.id)
    assert journal.phase == "rolled_back"

    # 对象 API（PG 权威读）不可见
    assert {:error, :not_found} = Objects.get_metadata(ctx.bucket, key)

    refute File.exists?(final_dir(ctx, key))

    assert {:ok, %ObjectEpoch{phase: "rolled_back"}} =
             Storage.current_epoch(target(ctx, key), data_dir: ctx.dir)

    assert mutation_dirs(ctx) == []
  end

  # ── 断言 3：finalize 失败 → 请求成功 → recovery 收敛 finalized ──

  test "finalize 失败（failpoint raise）：请求成功、journal=finalize_pending → run_now → finalized",
       ctx do
    Failpoint.arm(:object_mutation_finalize, {:raise, "finalize boom"})
    on_exit(fn -> Failpoint.disarm(:object_mutation_finalize) end)

    content = "finalize failure content"
    assert {:ok, %{journal: journal}} = protocol_put(ctx, content)
    Failpoint.disarm(:object_mutation_finalize)

    # 请求成功返回，但 journal 停在 finalize_pending（mark_error 已记 backoff）
    journal = ObjectMutation.get(journal.id)
    assert journal.phase == "finalize_pending"
    assert journal.attempts == 1
    assert journal.last_error =~ "finalize boom"

    # mark_error backoff（60s）+ prepare 宽限（60s）：now 注入越过
    stats = run_now!(now: future(180), storage_opts: [data_dir: ctx.dir])
    assert %{claimed: 1, finalized: 1} = stats

    journal = ObjectMutation.get(journal.id)
    assert journal.phase == "finalized"
    assert File.read!(Path.join(final_dir(ctx), "part.0")) == content

    assert {:ok, %ObjectEpoch{phase: "committed"}} =
             Storage.current_epoch(target(ctx), data_dir: ctx.dir)

    assert mutation_dirs(ctx) == []
  end

  # ── 断言 4：lease 接管（集成级复验，契约测试已锁细节）──

  test "lease：过期租约被 recover 接管推进；stale 持有者 transition/mark_error 不动库", ctx do
    {:ok, journal} = ObjectMutation.prepare(prepare_attrs(ctx, "lease.bin", 1))
    t0 = DateTime.utc_now()
    assert {:ok, stale} = ObjectMutation.claim(journal, "workerA", now: t0)

    # 租约有效期内不可被接管
    assert {:error, :not_due_or_leased} =
             ObjectMutation.claim(stale, "workerB", now: DateTime.add(t0, 30, :second))

    # 租约过期后 worker B 经同一入口接管推进（prepared → rolled_back）
    t1 = DateTime.add(t0, 61, :second)

    assert {:ok, recovered} =
             Recovery.recover(journal.id,
               now: t1,
               lease_owner: "workerB",
               storage_opts: [data_dir: ctx.dir]
             )

    assert recovered.phase == "rolled_back"

    # A 的后续 transition/mark_error 均 stale_journal，库不变
    assert {:error, {:stale_journal, "rolled_back", _attempts}} =
             ObjectMutation.transition(stale, "rollback_pending", %{}, now: t1)

    assert {:error, {:stale_journal, "rolled_back", _attempts}} =
             ObjectMutation.mark_error(stale, :late_worker, %{"stage" => "test"}, now: t1)

    assert ObjectMutation.get(journal.id).phase == "rolled_back"
  end

  # ── 断言 5：superseded 收敛 + successor 取证 ──

  test "superseded：迟到 published journal → rolled_back + successor 取证，B 三态不变", ctx do
    old = "old content"
    {:ok, _} = Storage.put(ctx.bucket, @key, "null", [old], data_dir: ctx.dir)

    parent = self()
    arm_pause(:object_mutation_before_metadata_commit)

    {:ok, a_owner} = Task.start(fn -> protocol_put(ctx, "content A", notify: parent) end)
    assert_receive {:write_info, %{object_commit_control: a_control}}, 5_000
    assert_receive {:paused, ^a_owner}, 5_000
    Failpoint.disarm(:object_mutation_before_metadata_commit)

    a_journal = journal_for(ctx, @key)
    assert a_journal.phase == "published"

    # 双杀 A（先 Control 后 owner）：A 的 journal 冻结在 published
    a_control_ref = Process.monitor(a_control)
    Process.exit(a_control, :kill)
    assert_receive {:DOWN, ^a_control_ref, :process, ^a_control, :killed}, 5_000
    a_owner_ref = Process.monitor(a_owner)
    Process.exit(a_owner, :kill)
    assert_receive {:DOWN, ^a_owner_ref, :process, ^a_owner, :killed}, 5_000

    # B 完整走完（claim 越过 A 的 published epoch：generation + 1）
    assert {:ok, %{journal: b_journal}} = protocol_put(ctx, "content B")
    b_journal = ObjectMutation.get(b_journal.id)
    assert b_journal.phase == "finalized"
    assert b_journal.generation == a_journal.generation + 1

    final = final_dir(ctx)
    assert {:ok, %ObjectEpoch{} = b_epoch} = Storage.current_epoch(target(ctx), data_dir: ctx.dir)
    assert b_epoch.token["mutation_id"] == b_journal.id
    assert {:ok, %Objects.Object{} = b_row} = Objects.get_metadata(ctx.bucket, @key)

    # recovery 收敛 A：restore → :superseded → rolled_back + successor 取证
    stats = run_now!(now: future(), storage_opts: [data_dir: ctx.dir])
    assert %{claimed: 1, superseded: 1, rolled_back: 0, finalized: 0} = stats

    a_after = ObjectMutation.get(a_journal.id)
    assert a_after.phase == "rolled_back"

    # B2 审查项 2 + B3 审查项 2：superseded 证据必须落 journal（successor 经 current_epoch
    # 另行取证——backend :superseded 返回值不含 successor token）
    evidence = a_after.recovery_evidence
    assert evidence["stage"] == "restore"
    assert evidence["outcome"] == "superseded"
    assert evidence["backup_dir"] == MutationBackup.relative_dir(a_journal.id)
    assert evidence["successor_generation"] == b_journal.generation
    assert evidence["successor_mutation_id"] == b_journal.id
    assert evidence["successor_phase"] == "committed"

    # B 三态（bytes/epoch/PG）不变；A 的 backup 原地保留可取证
    assert File.read!(Path.join(final, "part.0")) == "content B"
    assert {:ok, ^b_epoch} = Storage.current_epoch(target(ctx), data_dir: ctx.dir)
    assert {:ok, %Objects.Object{etag: b_etag}} = Objects.get_metadata(ctx.bucket, @key)
    assert b_etag == b_row.etag

    a_backup = Path.join(ctx.dir, MutationBackup.relative_dir(a_journal.id))
    assert File.regular?(Path.join(a_backup, MutationBackup.manifest_name()))
  end

  # ── 断言 6：sidecar-authority published journal（直接构造）──

  describe "sidecar-authority published journal（直接构造，B5 范围备忘第 2 条）" do
    test "epoch published（本 token）→ 必须 finalize，不得回滚", ctx do
      {:ok, journal} = sidecar_published_journal(ctx, "sidecar.bin")
      {:ok, mctx} = MutationContext.from_journal(journal)
      write_epoch!(ctx, mctx, "published", @fingerprint)

      assert {:ok, recovered} = Recovery.recover(journal.id, storage_opts: [data_dir: ctx.dir])
      assert recovered.phase == "finalized"
      assert not is_nil(recovered.finalized_at)
      # sidecar 路径不落 metadata_committed_at（PG index 仍是 best-effort）
      assert is_nil(recovered.metadata_committed_at)

      assert {:ok, %ObjectEpoch{phase: "committed"}} =
               Storage.current_epoch(mctx.target, data_dir: ctx.dir)
    end

    test "epoch 缺失/损坏 → quarantined（不猜测、不破坏）", ctx do
      # (a) epoch absent：journal 声称 published quorum 已达成，证据缺失即矛盾
      {:ok, j1} = sidecar_published_journal(ctx, "sidecar-absent.bin")
      assert {:ok, q1} = Recovery.recover(j1.id, storage_opts: [data_dir: ctx.dir])
      assert q1.phase == "quarantined"
      assert q1.recovery_evidence["stage"] == "sidecar_finalize"
      assert q1.recovery_evidence["reason"] == "epoch_absent"
      assert q1.last_error =~ "sidecar_epoch_missing"

      # (b) epoch 损坏（FS 读侧 {:corrupt,...}——quorum 证据不可用的单盘形态）
      {:ok, j2} = sidecar_published_journal(ctx, "sidecar-corrupt.bin")
      {:ok, mctx2} = MutationContext.from_journal(j2)
      corrupt_epoch!(ctx, mctx2.target)

      assert {:ok, q2} = Recovery.recover(j2.id, storage_opts: [data_dir: ctx.dir])
      assert q2.phase == "quarantined"
      assert q2.recovery_evidence["stage"] == "sidecar_finalize"
      assert q2.last_error =~ "sidecar_epoch_unreadable"
      assert q2.last_error =~ "corrupt"
    end
  end

  # ── 决策表：prepared / claimed 分支 ──

  test "prepared journal（epoch absent）：零存储副作用直接收敛 rolled_back", ctx do
    {:ok, journal} = ObjectMutation.prepare(prepare_attrs(ctx, "prepared.bin", 1))

    assert {:ok, recovered} = Recovery.recover(journal.id, storage_opts: [data_dir: ctx.dir])
    assert recovered.phase == "rolled_back"
    assert recovered.recovery_evidence["reason"] == "epoch_missing_before_claim"

    # 不产生任何盘上副作用（epoch 根从未被创建）
    refute File.exists?(Path.join(ctx.dir, ".maxio-object-epochs"))
  end

  test "claimed journal：restore 翻转 claimed epoch → rolled_back", ctx do
    {:ok, journal} = ObjectMutation.prepare(prepare_attrs(ctx, "claimed.bin", 1))
    {:ok, journal} = ObjectMutation.transition(journal, "claimed")
    {:ok, mctx} = MutationContext.from_journal(journal)
    write_epoch!(ctx, mctx, "claimed", nil)

    assert {:ok, recovered} = Recovery.recover(journal.id, storage_opts: [data_dir: ctx.dir])
    assert recovered.phase == "rolled_back"

    assert {:ok, %ObjectEpoch{phase: "rolled_back"}} =
             Storage.current_epoch(mctx.target, data_dir: ctx.dir)
  end

  # ── 断言 7：对象锁第二道防线 ──

  test "对象锁被占：skipped_locked、短 backoff、租约释放；解锁后收敛", ctx do
    key = "locked.bin"
    {:ok, journal} = ObjectMutation.prepare(prepare_attrs(ctx, key, 1))

    parent = self()

    {:ok, _holder_task} =
      Task.start(fn ->
        Maxio.Lock.with_object_lock({ctx.bucket, key}, fn ->
          send(parent, {:lock_held, self()})

          receive do
            :release -> :ok
          end
        end)

        send(parent, :lock_released)
      end)

    assert_receive {:lock_held, holder}, 5_000

    t0 = DateTime.utc_now()
    stats = run_now!(now: t0, locked_backoff_ms: 1_000, storage_opts: [data_dir: ctx.dir])
    assert %{claimed: 1, skipped_locked: 1, rolled_back: 0, retried: 0} = stats

    # journal 未被误动（phase 不变）、短 backoff 已记、租约已释放
    skipped = ObjectMutation.get(journal.id)
    assert skipped.phase == "prepared"
    assert skipped.attempts == 1
    assert is_nil(skipped.lease_owner)
    assert skipped.recovery_evidence["reason"] == "object_locked"
    assert DateTime.compare(skipped.next_attempt_at, t0) == :gt

    send(holder, :release)
    assert_receive :lock_released, 5_000

    # 解锁 + backoff 过后同一入口收敛
    assert {:ok, recovered} =
             Recovery.recover(journal.id,
               now: DateTime.add(t0, 2, :second),
               storage_opts: [data_dir: ctx.dir]
             )

    assert recovered.phase == "rolled_back"
  end

  # ── 断言 8：Scheduler ──

  describe "Scheduler" do
    test "enabled: false 不调度；run_now 同步返回统计；stale timer token 忽略" do
      pid = start_supervised!({Scheduler, name: nil, enabled: false})

      assert %{enabled: false, scheduled?: false, draining?: false, last_result: nil} =
               Scheduler.status(pid)

      assert {:ok, stats} = Scheduler.run_now(pid, [])

      assert stats == %{
               claimed: 0,
               finalized: 0,
               rolled_back: 0,
               superseded: 0,
               quarantined: 0,
               retried: 0,
               skipped_locked: 0
             }

      assert %{last_result: {:ok, ^stats}} = Scheduler.status(pid)

      # stale/未知 timer 消息被忽略（timer token 防线，抄 replication scheduler 语义）
      send(pid, {:drain, make_ref()})
      send(pid, :drain)
      _ = :sys.get_state(pid)
      assert %{scheduled?: false} = Scheduler.status(pid)
    end

    test "enabled: true 才调度周期 drain" do
      pid =
        start_supervised!(
          {Scheduler,
           name: nil, enabled: true, initial_delay_ms: 3_600_000, interval_ms: 3_600_000}
        )

      assert %{enabled: true, scheduled?: true} = Scheduler.status(pid)
    end

    # B6 审查项 1（B7 补测）：定时触发的 drain 路径（handle_info {:drain, token} 命中
    # timer_token → spawn_monitor drain → finish_drain 重排下一轮）。enabled: false 的
    # stale-token 测试对该路径不具区分力——此处用 initial_delay_ms: 0 真实驱动。
    test "enabled + initial_delay_ms: 0：自动 drain 收敛到期 journal 并重排下一轮", ctx do
      {:ok, journal} = ObjectMutation.prepare(prepare_attrs(ctx, "sched-auto.bin", 1))

      pid =
        start_supervised!(
          {Scheduler,
           name: nil,
           enabled: true,
           initial_delay_ms: 0,
           interval_ms: 3_600_000,
           storage_opts: [data_dir: ctx.dir]}
        )

      assert_eventually(fn -> ObjectMutation.get(journal.id).phase == "rolled_back" end)

      assert_eventually(fn ->
        match?(
          %{enabled: true, scheduled?: true, last_result: {:ok, %{claimed: claimed}}}
          when claimed >= 1,
          Scheduler.status(pid)
        )
      end)
    end
  end

  # ── 断言 9（NEXT-3 / B6 审查项 3，Phase 2A C1）：锁内收敛 CAS 失败 → 立即释放租约 ──

  describe "锁内收敛 CAS 失败（journal_convergence_failed）" do
    setup do
      previous = Application.get_env(:maxio, :storage_backend)
      Application.put_env(:maxio, :storage_backend, PausingRestoreBackend)
      Application.put_env(:maxio, :pausing_restore_backend_test_pid, self())

      on_exit(fn ->
        Application.put_env(:maxio, :storage_backend, previous)
        Application.delete_env(:maxio, :pausing_restore_backend_test_pid)
      end)

      :ok
    end

    test "并发扰动令 rolled_back CAS 失败 → 租约即刻释放，下一 worker 同刻 claim 并收敛", ctx do
      t0 = DateTime.utc_now()
      {:ok, journal} = ObjectMutation.prepare(prepare_attrs(ctx, "next3.bin", 1), now: t0)
      {:ok, journal} = ObjectMutation.transition(journal, "rollback_pending", %{}, now: t0)

      # workerA：claim（租约到 t0+60s）→ object lock → renew → restore 停在同步点
      worker_a =
        Task.async(fn ->
          Recovery.recover(journal.id,
            now: t0,
            lease_owner: "workerA",
            storage_opts: [data_dir: ctx.dir]
          )
        end)

      assert_receive {:restore_blocked, restorer}, 5_000
      assert ObjectMutation.get(journal.id).lease_owner == "workerA"

      # 并发扰动（模拟任意交错写者对 journal 的推进）：bump attempts → 锁内 conclude 的
      # rolled_back transition CAS（attempts 精确匹配）必然 stale
      {1, _} =
        Repo.update_all(from(j in Journal, where: j.id == ^journal.id), inc: [attempts: 1])

      send(restorer, {:continue, {:ok, :restored}})

      assert {:error, {:journal_convergence_failed, {:stale_journal, "rollback_pending", _}}} =
               Task.await(worker_a, 5_000)

      # 租约已被主动释放（不等 60s 过期）、phase 未被误动
      released = ObjectMutation.get(journal.id)
      assert released.phase == "rollback_pending"
      assert is_nil(released.lease_owner)
      assert is_nil(released.lease_expires_at)

      # 下一 worker 在同一逻辑时刻 t0（< workerA 租约原到期点 t0+60s）经同一入口 claim
      # 成功并收敛——若租约未被主动释放，claim CAS（lease_expires_at <= now）必拒。
      worker_b =
        Task.async(fn ->
          Recovery.recover(journal.id,
            now: t0,
            lease_owner: "workerB",
            storage_opts: [data_dir: ctx.dir]
          )
        end)

      assert_receive {:restore_blocked, restorer_b}, 5_000
      send(restorer_b, {:continue, {:ok, :restored}})

      assert {:ok, %Journal{phase: "rolled_back"}} = Task.await(worker_b, 5_000)
      assert is_nil(ObjectMutation.get(journal.id).lease_owner)
    end
  end

  # ── EC partial 契约切片（B3 审查项 1 + B3 节第 2 条）──

  describe "ErasureCoded partial" do
    setup ctx do
      previous = Application.get_env(:maxio, :storage_backend)
      Application.put_env(:maxio, :storage_backend, Maxio.Storage.ErasureCoded)

      base = Path.join(System.tmp_dir!(), "maxio_omr_ec_#{System.unique_integer([:positive])}")
      drives = for i <- 0..5, do: Path.join(base, "d#{i}")
      Enum.each(drives, &File.mkdir_p!/1)

      on_exit(fn ->
        Application.put_env(:maxio, :storage_backend, previous)
        File.rm_rf(base)
      end)

      Map.put(ctx, :drives, drives)
    end

    # 6 盘（4+2）→ epoch_quorum=4：3 盘 manifest 损坏时全局裁决可过（epoch 全盘可读），
    # per-endpoint restore 3 盘失败 → applied=3 < 4 → {:partial, evidence}。
    test "restore partial：{:partial, evidence} 形状锁定 + recovery 证据 stringify", ctx do
      o = [drives: ctx.drives, data_shards: 4, parity_shards: 2, block_size: 1024]
      :ok = ErasureCoded.put_bucket(ctx.bucket, o)
      {:ok, _} = ErasureCoded.put(ctx.bucket, @key, "null", ["old-bytes"], o)

      # journal 先行（mutation_id/generation 即协议身份）；EC put 冻结在 published 中间态
      {:ok, journal} =
        ObjectMutation.prepare(
          Map.put(prepare_attrs(ctx, @key, 1), :backend, "Maxio.Storage.ErasureCoded")
        )

      {:ok, journal} = ObjectMutation.transition(journal, "claimed")
      {:ok, mctx} = MutationContext.from_journal(journal)

      parent = self()

      {:ok, owner} =
        Task.start(fn ->
          ErasureCoded.put(
            ctx.bucket,
            @key,
            "null",
            ["new-bytes"],
            o ++
              [
                around_object_commit: fn prepared, publish ->
                  {:ok, _} = ErasureCoded.claim_epoch(mctx.target, mctx.token, "put", o)

                  {:ok, published} =
                    publish.(version_id: "null", object_meta: %{}, object_mutation: mctx)

                  send(
                    parent,
                    {:published, Map.fetch!(prepared, :object_commit_control),
                     published.epoch_fingerprint}
                  )

                  receive do
                    :never -> {:error, :never}
                  end
                end
              ]
          )
        end)

      assert_receive {:published, control, fingerprint}, 15_000

      {:ok, journal} =
        ObjectMutation.transition(journal, "published", %{published_fingerprint: fingerprint})

      # 双杀（先 Control 后 owner）：无加速器收敛，终局交 recovery
      control_ref = Process.monitor(control)
      Process.exit(control, :kill)
      assert_receive {:DOWN, ^control_ref, :process, ^control, :killed}, 5_000
      owner_ref = Process.monitor(owner)
      Process.exit(owner, :kill)
      assert_receive {:DOWN, ^owner_ref, :process, ^owner, :killed}, 5_000

      # 3 盘 backup manifest 损坏：epoch 仍全盘可读（全局裁决通过），per-endpoint 失败
      [_d0, _d1, _d2, d3, d4, d5] = ctx.drives

      Enum.each([d3, d4, d5], fn drive ->
        manifest =
          Path.join([drive, MutationBackup.relative_dir(journal.id), "manifest.json"])

        assert File.regular?(manifest)
        File.write!(manifest, "{corrupt")
      end)

      # B3 审查项 1：EC partial 错误形状锁定（防契约漂移）
      assert {:error, {:partial, %{applied: 3, superseded: 0, epoch_quorum: 4, errors: errors}}} =
               ErasureCoded.restore_if_current(mctx, o)

      assert length(errors) == 3

      assert Enum.all?(errors, fn {drive, reason} ->
               is_binary(drive) and match?({:corrupt, _}, reason)
             end)

      # recovery：published(pg) → rollback_pending → restore partial → mark_error（retried）；
      # 证据落库前 stringify（B3 节第 2 条：journal changeset 拒 atom key / 原始 term）
      stats = run_now!(storage_opts: o)
      assert %{claimed: 1, retried: 1, quarantined: 0, rolled_back: 0} = stats

      after_journal = ObjectMutation.get(journal.id)
      assert after_journal.phase == "rollback_pending"
      assert after_journal.attempts == 1
      assert is_nil(after_journal.lease_owner)
      assert after_journal.last_error =~ "partial"

      evidence = after_journal.recovery_evidence
      assert evidence["stage"] == "restore"
      assert evidence["applied"] == 3
      assert evidence["superseded"] == 0
      assert evidence["epoch_quorum"] == 4
      assert [%{"endpoint" => endpoint, "reason" => reason} | _] = evidence["endpoint_errors"]
      assert is_binary(endpoint)
      assert is_binary(reason)
      assert reason =~ "corrupt"

      # 损坏盘 backup 与旧值保留：不猜测、不破坏，journal 保持可重试
      Enum.each([d3, d4, d5], fn drive ->
        assert File.regular?(
                 Path.join([drive, MutationBackup.relative_dir(journal.id), "part.0"])
               )
      end)
    end
  end

  # ── Distributed placement 漂移切片（B4 契约 → quarantine）──

  describe "Distributed placement 漂移" do
    setup ctx do
      InProcess.setup!()
      previous = Application.get_env(:maxio, :storage_backend)
      Application.put_env(:maxio, :storage_backend, Maxio.Storage.Distributed)

      base = Path.join(System.tmp_dir!(), "maxio_omr_dist_#{System.unique_integer([:positive])}")

      endpoints =
        for i <- 0..5 do
          {:"maxio@n#{rem(i, 3)}", Path.join(base, "n#{rem(i, 3)}_d#{div(i, 3)}")}
        end

      topology =
        Topology.parse_and_validate!(
          data_shards: 4,
          parity_shards: 2,
          block_size: 1024,
          allow_colocated_endpoints: true,
          pools: [%{id: 0, sets: [%{id: 0, endpoints: endpoints}]}]
        )

      on_exit(fn ->
        Application.put_env(:maxio, :storage_backend, previous)
        File.rm_rf(base)
      end)

      Map.put(ctx, :topology, topology)
    end

    test "topology_hash 漂移：restore 拒绝 {:placement_drift,...} → quarantined，不触任何端点",
         ctx do
      o = [topology: ctx.topology, transport: InProcess]

      {:ok, journal} =
        ObjectMutation.prepare(
          Map.put(prepare_attrs(ctx, "drift.bin", 1), :backend, "Maxio.Storage.Distributed")
        )

      {:ok, journal} =
        ObjectMutation.transition(journal, "claimed", %{
          placement_snapshot: %{
            "set_id" => 0,
            "pool_id" => 0,
            "topology_hash" => "drifted-hash"
          }
        })

      {:ok, journal} =
        ObjectMutation.transition(journal, "published", %{published_fingerprint: @fingerprint})

      stats = run_now!(storage_opts: o)
      assert %{claimed: 1, quarantined: 1, retried: 0, rolled_back: 0} = stats

      after_journal = ObjectMutation.get(journal.id)
      assert after_journal.phase == "quarantined"
      assert not is_nil(after_journal.quarantined_at)
      assert after_journal.last_error =~ "placement_drift"

      drift = after_journal.recovery_evidence["placement_drift"]
      assert drift["set_id"] == 0
      assert drift["snapshot_topology_hash"] == "drifted-hash"
      assert is_binary(drift["current_topology_hash"])
      assert drift["current_topology_hash"] != "drifted-hash"
    end
  end

  # ── helpers ──

  # 经真实 Storage.put + ObjectCommit seam 驱动协议化提交（与 commit_test / handler
  # around 同形）。
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

  # 暂停型 failpoint：命中进程向测试进程报到后阻塞（被 kill 前绝不前进），零 sleep 同步。
  defp arm_pause(name) do
    parent = self()

    Failpoint.arm(
      name,
      {:fun,
       fn ->
         send(parent, {:paused, self()})

         receive do
           :never -> :ok
         end
       end}
    )

    on_exit(fn -> Failpoint.disarm(name) end)
  end

  # 每次新起独立 Scheduler（name: nil + 唯一 child id）经 run_now 同步 drain。
  defp run_now!(opts) do
    pid =
      start_supervised!(
        {Scheduler, [name: nil, enabled: false]},
        id: {:recovery_scheduler, System.unique_integer([:positive])}
      )

    assert {:ok, stats} = Scheduler.run_now(pid, opts)
    stats
  end

  defp sidecar_published_journal(ctx, key) do
    {:ok, journal} =
      ObjectMutation.prepare(Map.put(prepare_attrs(ctx, key, 1), :authority_mode, "sidecar"))

    {:ok, journal} = ObjectMutation.transition(journal, "claimed")
    ObjectMutation.transition(journal, "published", %{published_fingerprint: @fingerprint})
  end

  # 直接写 durable epoch（构造 sidecar / claimed 盘上事实；claim expect 不约束 phase）。
  defp write_epoch!(ctx, mctx, phase, fingerprint) do
    attrs = %{
      operation: "put",
      phase: phase,
      value_type: "object",
      updated_at: DateTime.utc_now()
    }

    attrs = if fingerprint, do: Map.put(attrs, :fingerprint, fingerprint), else: attrs
    {:ok, epoch} = ObjectEpoch.new(mctx.target, mctx.token, attrs)
    assert {:ok, :applied} = EpochStore.cas(ctx.dir, epoch, {:claim, mctx.token})
  end

  defp corrupt_epoch!(ctx, target) do
    {:ok, rel} = ObjectEpoch.relative_path(target)
    path = Path.join(ctx.dir, rel)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, "{corrupt")
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

  defp target(ctx, key \\ @key) do
    {:ok, target} = ObjectEpoch.object_target(ctx.bucket, key, "null")
    target
  end

  defp final_dir(ctx, key \\ @key) do
    {:ok, rel} = Paths.object_rel(ctx.bucket, key, "null")
    Path.join(ctx.dir, rel)
  end

  defp journal_for(ctx, key) do
    Repo.one!(
      from j in Maxio.ObjectMutation.Journal,
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

  defp future(seconds \\ 120), do: DateTime.add(DateTime.utc_now(), seconds, :second)

  # 10ms receive 轮询（test-infra 报告既有模式，零 Process.sleep）：定时 drain 在
  # scheduler 的独立 spawn_monitor 进程内异步完成，收敛用条件等待同步。
  defp assert_eventually(fun, timeout_ms \\ 5_000) when is_function(fun, 0) do
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
