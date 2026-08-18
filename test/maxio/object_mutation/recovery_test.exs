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

  @impl true
  def verify_published(ctx, opts), do: FS.verify_published(ctx, opts)
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

  import ExUnit.CaptureLog

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
  alias Maxio.ObjectMutation.StorageDisposition
  alias Maxio.Storage.{EpochStore, ErasureCoded, MutationBackup, MutationContext, ObjectEpoch}
  alias Maxio.Storage.PublishedProof
  alias Maxio.Test.RecoveryScriptRepo, as: ScriptRepo
  alias Maxio.Test.RejectingObjectMutationRepo, as: RejectingRepo
  alias Maxio.Test.StoragePublishedProofScriptBackend, as: Script

  @key "obj.bin"
  @fingerprint %{
    "etag" => "abc",
    "size" => 3,
    "sidecar_sha256" => String.duplicate("ab", 32)
  }

  # ── G3 Batch A（tests-only RED）冻结常量 ──
  #
  # 结构化日志捕获：只取 blueprint §6 允许的有界标量字段，raw term 一旦泄漏即被 sentinel
  # 断言抓到。
  @g3_capture_opts [
    format: "$metadata$message\n",
    metadata: [:action, :outcome, :reason, :mutation_phase]
  ]

  # 只可能出现在被注入的 backend 结果里的 raw sentinel：绝不允许进入 journal evidence、
  # last_error 或结构化日志。两者都在下面被**真实注入**，因此相应的 refute 非空洞。
  @g3_current_epoch_sentinel "g3_current_epoch_raw_sentinel"
  @g3_sidecar_detail_sentinel "g3_sidecar_detail_sentinel"
  @g3_restore_sentinel "g3_restore_raw_sentinel"
  @g3_exception_sentinel "g3_exception_raw_sentinel"
  @g3_lease_thief "g3_lease_thief_worker"

  # bucket validator 必拒的形态（大写 + 过短），但满足 journal 的 DB nonblank /
  # target-shape 约束，因此可由窄 update_all 播种成「无法派生 context」的行。
  @g3_invalid_bucket "A"

  @g3_pg_entry_phases ~w(metadata_committed finalize_pending)
  @g3_integrity_classes ~w(mismatch corrupt placement_drift)

  # ── Task 3 G3 终审纠偏（Phase A tests-only RED，handoff §5-§6）冻结常量 ──

  # §3.1 稳定运维闭集里本批直接断言的四个 binary code。
  @correction_claim_failed "object_mutation:claim_failed"
  @correction_lease_renewal_failed "object_mutation:lease_renewal_failed"
  @correction_convergence_failed "object_mutation:journal_convergence_failed"
  @correction_object_locked "object_mutation:object_locked"

  # §4 mode → contract-violation code 的唯一映射。
  @correction_proof_contract_violation "published_proof_contract_violation:proof"
  @correction_finalize_contract_violation "published_proof_contract_violation:finalize"

  # renew invoke wrapper 的三个异常域 sentinel。它们**只**出现在被注入的 repo action 里，
  # 因此每格都先正向证明 sentinel 真的在输入中，之后的 refute 全部非空洞。
  @correction_renew_raise_sentinel "recovery_script_repo:renew_raise_sentinel"
  @correction_renew_exit_sentinel "recovery_script_repo:renew_exit_sentinel"
  @correction_renew_throw_sentinel "recovery_script_repo:renew_throw_sentinel"

  # §5.3 第 6 格：确定性 attempts sentinel。CAS loser 的原始
  # `{:stale_journal, phase, attempts}` 必然携带它；稳定 code 必然不含。
  @correction_attempts_sentinel 987_654_321

  # §5.4 merge rejection oracle：durable JSON 的**单个 integer token** 上限为 1,024 bytes。
  # aggregate 语义允许任意正整数 `required`，因此 1,025 位十进制 `required` 能通过
  # `validate_callback_result/2` 与 `StorageDisposition`，却在
  # `merge_failure/3 -> journal_evidence/3 -> DurableJSON.validate/2` 被精确拒绝。
  # 同构的 1,024 位是每格的边界正控：证明 RED 来自 token 边界，而不是非法 fixture，
  # 更不是近 60-KiB 的整体 wrapper 超限。
  @correction_required_1025 String.to_integer(String.duplicate("9", 1_025))
  @correction_required_1024 String.to_integer(String.duplicate("9", 1_024))

  # 1,025 位十进制 token 的稳定长前缀，用作正向 raw sentinel。
  @correction_token_prefix String.duplicate("9", 64)

  # ── 【R7】固定 canonical 契约常量（必须在测试 cell 之前定义）──
  #
  # owner/6 = (journal, target_phase, summary, mode, opts, continuation)，续延固定 pos 5。
  @correction_owner_arity 6
  @correction_owner_continuation_pos 5
  @correction_owner_param_names ~w(journal target_phase summary mode opts continuation)a

  # mode→code seam 固定为 exact `pg_contract_code/1`：恰好两个无 guard 子句 `:proof`/
  # `:finalize`。静态只锁这一个 seam，不复制业务值。
  @correction_contract_code_mfa {:pg_contract_code, 1}

  # mode → **必须返回的精确 module attribute 名**。oracle 检查的是这两个属性的 AST 身份，
  # 不接受任意属性，也不接受等值的字符串字面量（那样会把业务值复制进静态断言）。
  @correction_contract_code_clauses [
    {:proof, :stable_proof_contract_violation},
    {:finalize, :stable_finalize_contract_violation}
  ]
  @correction_journal_opts_mfa {:journal_opts, 1}

  # 三个固定 caller 契约。
  @correction_caller_specs %{
    pg_merged_pending_retry: %{
      arity: 5,
      params: ~w(journal summary code mode opts)a,
      target: "finalize_pending",
      mode_pos: 3
    },
    pg_merged_terminal: %{
      arity: 6,
      params: ~w(journal summary code outcome mode opts)a,
      target: "finalized",
      mode_pos: 4
    },
    pg_merged_quarantine: %{
      arity: 5,
      params: ~w(journal summary code mode opts)a,
      target: "quarantined",
      mode_pos: 3
    }
  }

  # callsite 分组：宿主函数 → {期望调用数, 期望 mode 字面量}。
  # 【R7.1 / gap 5】宿主是**精确 MFA**（含 arity），不是裸名字。
  @correction_callsite_groups [
    {{:apply_pg_proof_disposition, 4}, 3, :proof},
    {{:apply_pg_finalize_disposition, 3}, 4, :finalize}
  ]

  # 【R3】AST oracle 的两个精确 MFA 锚点：模块语义身份 + 函数名 + arity。
  # 别名可以归一，但语义模块必须精确相等——`Fake.*` 与同名错 arity 一律拒绝。
  @correction_preserving_mfa {[:Maxio, :ObjectMutation], :quarantine_preserving_evidence, 3}
  @correction_merge_failure_mfa {[:Maxio, :Storage, :PublishedProof], :merge_failure, 3}

  # 【R2】merge 拒绝隔离唯一被契约授权改动的持久化字段。其余每一个
  # `Journal.__schema__(:fields)` 字段都必须逐字不变。
  @correction_quarantine_authorized_fields [
    :phase,
    :lease_owner,
    :lease_expires_at,
    :last_error,
    :quarantined_at,
    :updated_at
  ]

  # 【R1】可被逐字 refute 的 lease owner 标识：本 worker 与「另一个 owner」。
  # 稳定运维边界绝不允许把它们当作诊断对外暴露。
  @correction_lease_owner_probe "g3c-lease-owner-probe"
  @correction_self_owner "g3c-self-owner"
  @correction_other_owner "g3c-other-owner-probe"

  # §5.4 六个独立 merge-rejection cell：{mode, 实际 disposition, merge target}。
  @correction_merge_cells [
    {"proof", "unavailable", "finalize_pending"},
    {"proof", "superseded", "finalized"},
    {"proof", "corrupt", "quarantined"},
    {"finalize", "unavailable", "finalize_pending"},
    {"finalize", "superseded", "finalized"},
    {"finalize", "corrupt", "quarantined"}
  ]

  # §5.3 第 2-5 格：四个 renew 故障 action 各自独立成格。
  @correction_renew_cells [
    {"normal_error", "a normal cas error"},
    {"raise", "a raised sentinel"},
    {"exit", "an exited sentinel"},
    {"throw", "a thrown sentinel"}
  ]

  # ── Task 3 G3 Phase B 终审纠偏（tests-only RED）冻结常量 ──
  #
  # 两条独立静态终审 REJECT 各自的稳定契约值。它们必须被**逐字**命中：
  #
  #   I1 `operational_error/3` 的 CAS 失败臂把没有落库的收敛写报告成
  #      `{:ok, :retried, _}`，而不是 §3.2 唯一的稳定 convergence 结果；
  #   I2 sidecar finalize 的 1,025 位 `required` 投影在 `validate_sidecar_write/5`
  #      被 durable 校验拒绝后，raw `{:sidecar_evidence_contract, :finalize}` tuple
  #      被转发给只接 binary 的 `log_no_action/2`，抛 FunctionClauseError 而不是
  #      给出稳定结果。
  #
  # I1 的期望值直接复用既有 `@correction_convergence_failed`；I2 复用 sidecar
  # contract-violation disposition 既有的 mode-specific 稳定 code。
  @phase_b_sidecar_contract_violation "sidecar_finalize:contract_violation"

  # DurableJSON 的**单个 integer token** 上限恰为 1,024 bytes。两个边界值逐字由
  # `String.duplicate(<<57>>, n)` 构造（`<<57>>` 即十进制数字 "9" 的字节），并在格内
  # 正向断言与既有 §5.4 常量 `===`，因此两批断言用的是同一个数值边界。
  @phase_b_required_1025 String.to_integer(String.duplicate(<<57>>, 1_025))
  @phase_b_required_1024 String.to_integer(String.duplicate(<<57>>, 1_024))

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

    # 【G3 review correction §2】唯一被授权迁移的既有 deferred 断言：G2 已把这个私有编排
    # 异常收敛为精确稳定 code，raw 异常文本绝不允许持久化。该断言在 Recovery 之前求值，
    # 因此 recovery.ex 无法改变它——只能在此迁移。
    assert journal.last_error == "object_mutation_finalize:orchestration_error",
           "编排异常必须收敛为精确稳定 code"

    refute String.contains?(journal.last_error, "finalize boom"),
           "raw 异常文本绝不能被持久化"

    # mark_error backoff（60s）+ prepare 宽限（60s）：now 注入越过
    stats = run_now!(now: future(180), storage_opts: [data_dir: ctx.dir])
    assert %{claimed: 1, finalized: 1} = stats

    journal = ObjectMutation.get(journal.id)
    assert journal.phase == "finalized"
    assert File.read!(Path.join(final_dir(ctx), "part.0")) == content

    assert {:ok, %ObjectEpoch{phase: "committed"}} =
             Storage.current_epoch(target(ctx), data_dir: ctx.dir)

    # 端到端终态清洁度。它**不**声称本次 Recovery 执行了删除：请求成功返回后，冻结的
    # `ObjectCommit.Control` 完成路径会重放 backend 拥有的 finalize 闭包，可能在 journal
    # 仍是 finalize_pending 时就已经清掉物理 backup。物理 backup 的保留/删除权威见报告
    # 里的正交划分（crash/rollback 校准 + 冻结的 epoch_store_published_proof_test.exs）。
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
      key = "sidecar.bin"
      content = "sidecar published content"

      # 【G3 sidecar fixture correction】本格原先只造 journal + 手写 published epoch，
      # 盘上既无 final part.0/meta.json、也无 durable mutation manifest，还用死写的
      # `@fingerprint`——proof-aware finalize 对它返回 `corrupt` 是**正确**的完整性判定，
      # 于是 G3 正确地 quarantine 了它。修正方式是把 fixture 换成真实 FS 协议产物：经真实
      # `Storage.put/5` + `around_object_commit` 用**同一 sidecar token** claim epoch 并
      # publish，再用 publish 真实回传的 fingerprint 推进 journal。生产 recovery.ex 一行不改。
      {:ok, journal, mctx, fingerprint} = sidecar_published_fixture(ctx, key, content)

      # 正向证明 fixture 是真品（而非「因为断言过了所以想必是真的」）：终局字节、canonical
      # meta.json sidecar、durable epoch（本 token + 真实 fingerprint）、durable manifest。
      assert File.read!(Path.join(final_dir(ctx, key), "part.0")) == content
      assert File.regular?(Path.join(final_dir(ctx, key), "meta.json"))

      assert {:ok, %ObjectEpoch{phase: "published"} = published_epoch} =
               Storage.current_epoch(mctx.target, data_dir: ctx.dir)

      assert published_epoch.token == mctx.token
      assert published_epoch.fingerprint == fingerprint
      assert journal.published_fingerprint == fingerprint

      assert File.regular?(
               Path.join([
                 ctx.dir,
                 MutationBackup.relative_dir(journal.id),
                 MutationBackup.manifest_name()
               ])
             )

      # 唯一一次 test-only 标定：backend 对**这个精确 context** 给出规范化的 verified
      # disposition。它证明 fixture 可被取证，**不**是 recovery 独立 verify 的授权
      # （sidecar 路径绝不自行 verify，见 §5 sidecar matrix）。
      assert {:ok, {:verified, _summary}} =
               Storage.verify_published(mctx, data_dir: ctx.dir)

      assert {:ok, recovered} = Recovery.recover(journal.id, storage_opts: [data_dir: ctx.dir])
      assert recovered.phase == "finalized"
      assert not is_nil(recovered.finalized_at)
      # sidecar 路径不落 metadata_committed_at（PG index 仍是 best-effort）
      assert is_nil(recovered.metadata_committed_at)

      assert {:ok, %ObjectEpoch{phase: "committed"}} =
               Storage.current_epoch(mctx.target, data_dir: ctx.dir)
    end

    # 【blueprint §7.1 授权的唯一机械迁移】原「epoch 缺失/损坏 → quarantined」这一格把
    # absent 与 corrupt 两个 class 塞进同一个 test：第一格的 assert 一旦失败，后一格根本
    # 不会执行。G3 把它拆成两个独立的 exact-contract 用例，见下方
    # `G3 RED: sidecar current-epoch pre-adapter` 的 missing / unavailable 两格。
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

      # 【R3 迁移】§3.1 稳定运维边界：收敛 CAS 失败对外只能是精确稳定 binary code，
      # 绝不携带 raw `{:stale_journal, phase, attempts}`。原断言与该边界必然冲突，
      # 因此迁移为精确稳定 code（当前冻结生产上是 intentional RED）。
      # 下方 DB 赢家/租约断言与更底层的 ObjectMutation raw-cause 对照全部原样保留。
      assert Task.await(worker_a, 5_000) == {:error, @correction_convergence_failed}

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

  # ── Task 3 / G3 Batch A：tests-only genuine RED（blueprint §7.2 PG authority matrix）──
  #
  # 全部标 `:task3_g3_recovery_red`，针对**入口生产**运行以捕获真实能力缺口：入口
  # `Recovery.finalize_flow/3` 仍直接匹配已退役的 `{:ok, :finalized}` / `{:ok, :superseded}`
  # 原子结果，既不做 durable proof 验证、也从不调用 `Storage.verify_published/2`，更不消费
  # `StorageDisposition`。因此下面每一格都是能力 RED，而不是断言口味差异。
  #
  # 每一格都是**独立生成**的 ExUnit test（blueprint §7 明令）：绝不把多格塞进一个运行期
  # 循环——否则第一格的 assert 会直接中止该测试，后续格根本不会执行也不会消费各自的脚本
  # 条目，从而被静默掩盖。

  defp g3_script_backend(ctx) do
    previous = Application.fetch_env!(:maxio, :storage_backend)
    Application.put_env(:maxio, :storage_backend, Script)
    on_exit(fn -> Application.put_env(:maxio, :storage_backend, previous) end)

    start_supervised!(Script)
    Map.put(ctx, :previous_backend, previous)
  end

  # --- §4.1 durable gate：任何端点 I/O 之前 ---

  describe "G3 RED: PG durable proof gate" do
    setup :g3_script_backend

    for entry <- @g3_pg_entry_phases, wrapper <- ~w(missing malformed) do
      @tag :task3_g3_recovery_red
      test "g3 red: pg #{entry} with a #{wrapper} durable wrapper quarantines with zero storage io",
           ctx do
        entry = unquote(entry)
        wrapper = unquote(wrapper)
        key = "g3-durable-#{wrapper}-#{entry}.bin"

        journal = pg_journal(ctx, key, entry, wrapper: g3_wrapper(wrapper))
        snapshot = g3_snapshot(journal)

        {_result, fresh, _log} = g3_recover(ctx, journal)

        # durable 门在 I/O 之前：四个受控操作**全部**零调用。
        assert_pg_counts!("#{entry}/#{wrapper}", 0, 0)

        assert fresh.phase == "quarantined",
               "#{entry}/#{wrapper}：非法 durable 证据必须 evidence-preserving 隔离"

        assert fresh.last_error == "published_proof_invalid:durable",
               "#{entry}/#{wrapper}：必须写入精确的 durable 稳定 code"

        refute String.contains?(fresh.last_error, "\"")

        # 绝不裁剪、修复、规范化或替换非法证据。
        assert fresh.recovery_evidence === snapshot.wrapper,
               "#{entry}/#{wrapper}：非法证据的 term 必须逐字保留"

        assert Jason.encode!(fresh.recovery_evidence) == snapshot.wrapper_bytes
        assert fresh.published_fingerprint === snapshot.fingerprint
      end
    end
  end

  # --- §4.2 defensive proof：verify 恰好一次 + StorageDisposition 恰好一次 ---

  describe "G3 RED: PG proof dispositions" do
    setup :g3_script_backend

    for entry <- @g3_pg_entry_phases,
        proof <- ~w(unavailable mismatch corrupt placement_drift superseded contract_violation) do
      @tag :task3_g3_recovery_red
      test "g3 red: pg #{entry} proof #{proof} converges with the exact code and zero finalize",
           ctx do
        entry = unquote(entry)
        proof = unquote(proof)
        key = "g3-proof-#{proof}-#{entry}.bin"

        journal = pg_journal(ctx, key, entry)
        snapshot = g3_snapshot(journal)

        # 【correction §4】先绑定被脚本化的规范化结果，再据此在**调用 Recovery 之前**
        # 用生产权威按精确 API 顺序算出期望 wrapper，并冻结 term 与编码字节。
        scripted = g3_proof_result(proof)
        {expected_phase, expected_code} = g3_proof_expectation(proof)

        # contract violation 没有 canonical summary（退役 atom 结果），按 §4 保留整份
        # 原 wrapper，不做 merge 期望。
        expected =
          if proof == "contract_violation",
            do: nil,
            else: g3_expected_merge(expected_phase, snapshot, scripted)

        Script.script(:verify_published, {:return, scripted})

        {_result, fresh, _log} = g3_recover(ctx, journal)

        # proof 失败/后继一律**零 finalize**；PG 路径的 current_epoch / restore 恒零。
        assert_pg_counts!("#{entry}/proof:#{proof}", 1, 0)
        assert Script.remaining(:verify_published) == 0, "脚本条目必须被精确消费"

        assert fresh.phase == expected_phase, "#{entry}/proof:#{proof}：期望 #{expected_phase}"

        assert fresh.last_error == expected_code,
               "#{entry}/proof:#{proof}：必须写入精确未加引号的稳定 code"

        refute String.contains?(fresh.last_error, "\"")

        if proof == "contract_violation" do
          # 无 canonical summary：绝不 merge，wrapper 与 fingerprint 逐字保留。
          assert fresh.recovery_evidence === snapshot.wrapper
          assert Jason.encode!(fresh.recovery_evidence) == snapshot.wrapper_bytes
        else
          assert_exact_merge!(fresh, snapshot, expected, "#{entry}/proof:#{proof}")
        end

        assert fresh.published_fingerprint === snapshot.fingerprint
      end
    end
  end

  # --- §4.3 pending fence + §4.4 finalize ---

  describe "G3 RED: PG finalize dispositions after a passed proof" do
    setup :g3_script_backend

    # proof 通过（verified 与 degraded 两种 class 各自独立成格）后 finalize 成功终结。
    for entry <- @g3_pg_entry_phases, proof <- ~w(verified degraded) do
      @tag :task3_g3_recovery_red
      test "g3 red: pg #{entry} proof #{proof} then finalize finalized terminates", ctx do
        entry = unquote(entry)
        proof = unquote(proof)
        key = "g3-pass-#{proof}-#{entry}.bin"

        journal = pg_journal(ctx, key, entry)
        snapshot = g3_snapshot(journal)

        Script.script(:verify_published, {:return, g3_proof_result(proof)})
        Script.script(:finalize_if_current, {:return, g3_finalize_result("finalized")})

        {result, fresh, _log} = g3_recover(ctx, journal)

        assert {:ok, _} = result
        assert_pg_counts!("#{entry}/pass:#{proof}", 1, 1)
        assert Script.remaining_all().verify_published == 0
        assert Script.remaining_all().finalize_if_current == 0

        assert fresh.phase == "finalized"
        refute is_nil(fresh.finalized_at)
        assert is_nil(fresh.lease_owner), "终态必须清租约"

        # 成功只可清掉陈旧的 canonical last_failure，绝不替换或重编码 published_proof。
        assert_proof_preserved!(fresh, snapshot, "#{entry}/pass:#{proof}")
      end
    end

    for entry <- @g3_pg_entry_phases,
        finalize <-
          ~w(cleanup_pending unavailable mismatch corrupt placement_drift superseded contract_violation) do
      @tag :task3_g3_recovery_red
      test "g3 red: pg #{entry} finalize #{finalize} converges with the exact code", ctx do
        entry = unquote(entry)
        finalize = unquote(finalize)
        key = "g3-finalize-#{finalize}-#{entry}.bin"

        journal = pg_journal(ctx, key, entry)
        snapshot = g3_snapshot(journal)

        # 【correction §4】先绑定被脚本化的规范化结果，再在调用 Recovery 之前用生产权威
        # 算出期望 wrapper 并冻结 term/字节。
        scripted = g3_finalize_result(finalize)
        {expected_phase, expected_code} = g3_finalize_expectation(finalize)

        expected =
          if finalize == "contract_violation",
            do: nil,
            else: g3_expected_merge(expected_phase, snapshot, scripted)

        Script.script(:verify_published, {:return, g3_proof_result("verified")})
        Script.script(:finalize_if_current, {:return, scripted})

        {_result, fresh, _log} = g3_recover(ctx, journal)

        # pending fence 之后 finalize 恰好一次；PG 路径绝不 restore、绝不读 current_epoch。
        assert_pg_counts!("#{entry}/finalize:#{finalize}", 1, 1)
        assert Script.remaining(:finalize_if_current) == 0, "脚本条目必须被精确消费"

        assert fresh.phase == expected_phase, "#{entry}/finalize:#{finalize}：期望 #{expected_phase}"
        assert fresh.last_error == expected_code
        refute String.contains?(fresh.last_error, "\"")

        if finalize == "contract_violation" do
          assert fresh.recovery_evidence === snapshot.wrapper
          assert Jason.encode!(fresh.recovery_evidence) == snapshot.wrapper_bytes
        else
          assert_exact_merge!(fresh, snapshot, expected, "#{entry}/finalize:#{finalize}")
        end

        assert fresh.published_fingerprint === snapshot.fingerprint

        # metadata 之后绝不回滚。
        refute fresh.phase in ["rollback_pending", "rolled_back"],
               "#{entry}/finalize:#{finalize}：PG metadata 之后绝不允许回滚"
      end
    end
  end

  # ── blueprint §7.3 sidecar matrix ──
  #
  # sidecar 绝不调用 PG 的 PublishedProof durable validator / merge，只写**有界的通用标量
  # 投影**；它也绝不做独立 verify。下面每一格都独立断言精确调用次数、精确 evidence 形状
  # （strict `===` 到完整键集合）与精确未加引号的稳定 code。

  # --- §5.1 published current-epoch pre-adapter ---

  describe "G3 RED: sidecar current-epoch pre-adapter" do
    setup :g3_script_backend

    for observed <- ~w(missing unavailable conflict contract_violation) do
      @tag :task3_g3_recovery_red
      test "g3 red: sidecar published current-epoch #{observed} quarantines with exact three-key evidence",
           ctx do
        observed = unquote(observed)
        key = "g3-sidecar-epoch-#{observed}.bin"

        journal = sidecar_journal(ctx, key, "published")
        snapshot = g3_snapshot(journal)

        # 【correction §5.1】先绑定被脚本化的输入，并对注入了 sentinel 的两格**正向**
        # 证明该 sentinel 确实出现在这个输入里——否则后面的 refute 只是空洞的。
        scripted = g3_current_epoch_result(observed, journal)

        if observed in ~w(unavailable contract_violation) do
          assert String.contains?(inspect(scripted), @g3_current_epoch_sentinel),
                 "#{observed}：被脚本化的 current-epoch 输入必须真的携带 raw sentinel"
        end

        Script.script(:current_epoch, {:return, scripted})

        {_result, fresh, log} = g3_recover(ctx, journal)

        # pre-adapter 失败：finalize / verify / restore 全部零调用。
        assert_sidecar_counts!("current_epoch:#{observed}", 1, 0)
        assert Script.remaining(:current_epoch) == 0, "脚本条目必须被精确消费"

        {outcome, expected_code} = g3_current_epoch_expectation(observed)

        assert fresh.phase == "quarantined",
               "current_epoch:#{observed}：所有 pre-adapter 失败一律隔离并保留 backup"

        assert fresh.last_error == expected_code,
               "current_epoch:#{observed}：必须写入精确未加引号的稳定 code"

        refute String.contains?(fresh.last_error, "\"")

        # 恰好三键，且不含 target / token / generation / mutation id / endpoint /
        # node / drive / path / placement / raw term / inspect 后的 reason。
        assert fresh.recovery_evidence ===
                 %{
                   "authority_mode" => "sidecar",
                   "stage" => "current_epoch",
                   "outcome" => outcome
                 },
               "current_epoch:#{observed}：证据必须严格等于精确的三键形态"

        assert fresh.published_fingerprint === snapshot.fingerprint

        # 只有真正注入了 sentinel 的两格才断言泄漏（其余格由上面的 strict === 覆盖）。
        if observed in ~w(unavailable contract_violation) do
          refute String.contains?(
                   Jason.encode!(fresh.recovery_evidence),
                   @g3_current_epoch_sentinel
                 ),
                 "raw current_epoch 原因绝不能落库"

          refute String.contains?(fresh.last_error, @g3_current_epoch_sentinel)
          refute String.contains?(log, @g3_current_epoch_sentinel), "raw current_epoch 原因绝不进日志"
        end
      end
    end
  end

  # --- §5.2 shared sidecar finalize adapter（两个合法 entry 各自独立成格）---

  describe "G3 RED: sidecar finalize adapter" do
    setup :g3_script_backend

    for entry <- ~w(published finalize_pending),
        finalize <-
          ~w(finalized cleanup_pending superseded unavailable mismatch corrupt placement_drift contract_violation) do
      @tag :task3_g3_recovery_red
      test "g3 red: sidecar #{entry} finalize #{finalize} writes the exact bounded projection",
           ctx do
        entry = unquote(entry)
        finalize = unquote(finalize)
        key = "g3-sidecar-#{finalize}-#{entry}.bin"

        journal = sidecar_ready_journal(ctx, key, entry)
        snapshot = g3_snapshot(journal)
        scripted = g3_sidecar_finalize_result(finalize)

        # 【correction §5.2】对本该注入 detail sentinel 的每一格，安装脚本之前先**正向**
        # 证明：被脚本化的 callback term 与从中提取出的 canonical summary **两者**都真的
        # 携带该 sentinel。只有这样，后面的证据/日志 refute 才具备真实区分力。
        if finalize in ~w(cleanup_pending unavailable mismatch corrupt placement_drift) do
          assert String.contains?(inspect(scripted), @g3_sidecar_detail_sentinel),
                 "#{finalize}：被脚本化的 finalize term 必须真的携带 detail sentinel"

          summary = g3_summary_of(scripted)

          assert is_map(summary), "#{finalize}：必须能从被脚本化结果提取 canonical summary"

          assert String.contains?(Jason.encode!(summary), @g3_sidecar_detail_sentinel),
                 "#{finalize}：canonical summary 本身也必须真的携带 detail sentinel"
        end

        Script.script(:finalize_if_current, {:return, scripted})

        {_result, fresh, log} = g3_recover(ctx, journal)

        # published entry 先读一次 current_epoch；finalize_pending entry 直接进 adapter。
        expected_current_epoch = if entry == "published", do: 1, else: 0
        assert_sidecar_counts!("#{entry}/finalize:#{finalize}", expected_current_epoch, 1)
        assert Script.remaining(:finalize_if_current) == 0, "脚本条目必须被精确消费"

        {expected_phase, expected_code, outcome, class} = g3_sidecar_expectation(finalize)

        assert fresh.phase == expected_phase,
               "#{entry}/finalize:#{finalize}：期望 #{expected_phase}，实际 #{fresh.phase}"

        assert fresh.last_error === expected_code,
               "#{entry}/finalize:#{finalize}：必须写入精确未加引号的稳定 code"

        if is_binary(fresh.last_error), do: refute(String.contains?(fresh.last_error, "\""))

        expected_evidence =
          if finalize == "contract_violation" do
            %{
              "authority_mode" => "sidecar",
              "stage" => "finalize",
              "outcome" => "contract_violation"
            }
          else
            g3_sidecar_finalize_evidence(outcome, class, g3_summary_of(scripted))
          end

        # 完整键集合 strict `===`：既不许缺任何 canonical 标量，也不许多出任何键
        # （scope / observed_owned / degraded / orphan_hints / detail / endpoint / token…）。
        assert fresh.recovery_evidence === expected_evidence,
               "#{entry}/finalize:#{finalize}：证据必须严格等于精确的有界投影"

        assert fresh.published_fingerprint === snapshot.fingerprint

        # canonical summary 的 detail 级 sentinel 绝不允许被投影进 journal 或日志。
        if finalize in ~w(cleanup_pending unavailable mismatch corrupt placement_drift) do
          refute String.contains?(
                   Jason.encode!(fresh.recovery_evidence),
                   @g3_sidecar_detail_sentinel
                 ),
                 "#{entry}/finalize:#{finalize}：detail sentinel 绝不能落库"

          refute String.contains?(log, @g3_sidecar_detail_sentinel),
                 "#{entry}/finalize:#{finalize}：detail sentinel 绝不进日志"
        end
      end
    end
  end

  # --- §5.3 impossible sidecar phase ---

  describe "G3 RED: sidecar impossible phase" do
    setup :g3_script_backend

    # 【correction 2】这一格必须证明 authority/phase 预路由发生在**通用 context 派生之前**。
    # 为此除了播种「不可能状态」，还同时把 locator 播种成不可派生的形态：如果生产先派生
    # context，它只会得到 context-invalid 的结论（错误的 code），只有真正把
    # `{sidecar, metadata_committed}` 预路由排在 `MutationContext.from_journal/1` 之前的
    # 实现，才能给出下面这个精确结论。
    @tag :task3_g3_recovery_red
    test "g3 red: sidecar metadata_committed pre-routes ahead of context derivation with zero storage io",
         ctx do
      key = "g3-sidecar-impossible.bin"

      # sidecar published 的合法目标只有 finalize_pending / quarantined，因此该状态无法经
      # 公开 API 到达——用测试进程的窄 update_all 直接播种这个「不可能状态」，并在**同一次**
      # 窄写入里把 bucket 换成 validator 必拒的形态。
      journal = sidecar_journal(ctx, key, "published")

      {:ok, seeded} =
        g3_seed_row!(journal, phase: "metadata_committed", bucket_name: @g3_invalid_bucket)

      snapshot = g3_snapshot(seeded)

      # 正向前提：这一行**确实**无法派生 context。因此「先派生 context」的实现绝无可能
      # 得出下面的 sidecar 结论——本格对预路由具有真实区分力，而不是重复 §5.3 的既有断言。
      assert {:error, _reason} = MutationContext.from_journal(seeded),
             "本格前提：该行必须真的无法派生 mutation context"

      {_result, fresh, log} = g3_recover(ctx, seeded)

      # 所有 Storage I/O 之前就必须收口。
      assert_sidecar_counts!("sidecar/metadata_committed", 0, 0)

      assert fresh.phase == "quarantined"

      assert fresh.last_error == "sidecar_phase:metadata_committed",
             "不可能状态必须写入精确的稳定 code（而不是 context-invalid 的结论）"

      refute String.contains?(fresh.last_error, "\"")

      # 预路由赢下判定的反证：绝不允许收敛成通用 context 结论。
      refute fresh.last_error == "object_mutation:context_invalid",
             "预路由必须排在通用 context 派生之前"

      # evidence-preserving：term、JSON 字节与 fingerprint 逐字不变；租约必须清空。
      assert fresh.recovery_evidence === snapshot.wrapper
      assert Jason.encode!(fresh.recovery_evidence) == snapshot.wrapper_bytes
      assert fresh.published_fingerprint === snapshot.fingerprint
      assert is_nil(fresh.lease_owner), "隔离必须清租约"
      assert is_nil(fresh.lease_expires_at)

      # 被播种的非法 locator 绝不允许作为 raw 诊断落库或进日志。
      refute String.contains?(log, @g3_invalid_bucket), "raw locator 绝不能进日志"
    end
  end

  # ── blueprint §7.4 ordering and races ──
  #
  # 全部用 script gate / ref / 消息 / monitor / Ecto query telemetry 做确定性同步：
  # 零 Process.sleep、零轮询、零 Application-env 脚本状态、零新增生产 failpoint。
  # 每个竞态各自独立成格。

  describe "G3 RED: ordering gates" do
    setup :g3_script_backend

    # 竞态 1：verify 仍在进行时，journal 绝不能被提前推进出 metadata_committed。
    @tag :task3_g3_recovery_red
    test "g3 race: while the pg verify gate is held the journal stays metadata_committed", ctx do
      key = "g3-race-verify-gate.bin"
      journal = pg_journal(ctx, key, "metadata_committed")
      ref = make_ref()

      Script.script(
        :verify_published,
        {:gate, self(), ref, {:return, g3_proof_result("verified")}}
      )

      Script.script(:finalize_if_current, {:return, g3_finalize_result("finalized")})
      task = Task.async(fn -> Recovery.recover(journal.id, storage_opts: [data_dir: ctx.dir]) end)

      entered = g3_await_gate!(ref, "verify_published")
      assert entered.operation == :verify_published

      # proof 未定论之前既不得 CAS 进 finalize_pending，也不得触碰 finalize。
      assert ObjectMutation.get(journal.id).phase == "metadata_committed",
             "verify 未返回前绝不能推进 journal"

      assert Script.call_count(:finalize_if_current) == 0, "verify 未返回前绝不能 finalize"

      send(entered.caller, {:script_backend_release, ref})
      assert {:ok, _} = Task.await(task, 15_000)
      assert ObjectMutation.get(journal.id).phase == "finalized"
    end

    # 竞态 2：finalize 只能发生在 pending fence 之后，且 proof 必须已经通过。
    @tag :task3_g3_recovery_red
    test "g3 race: the pg finalize gate is only reached after a passed proof and the pending fence",
         ctx do
      key = "g3-race-finalize-gate.bin"
      journal = pg_journal(ctx, key, "metadata_committed")
      ref = make_ref()

      Script.script(:verify_published, {:return, g3_proof_result("verified")})

      Script.script(
        :finalize_if_current,
        {:gate, self(), ref, {:return, g3_finalize_result("finalized")}}
      )

      task = Task.async(fn -> Recovery.recover(journal.id, storage_opts: [data_dir: ctx.dir]) end)

      entered = g3_await_gate!(ref, "finalize_if_current")

      # 破坏性 finalize 的授权前提：proof 恰好一次 + journal 已经过 pending fence。
      assert Script.call_count(:verify_published) == 1,
             "finalize 之前 verify 必须恰好被调用一次（pending fence 的授权前提）"

      assert ObjectMutation.get(journal.id).phase == "finalize_pending",
             "finalize 只能发生在 pending CAS 之后"

      send(entered.caller, {:script_backend_release, ref})
      assert {:ok, _} = Task.await(task, 15_000)
      assert ObjectMutation.get(journal.id).phase == "finalized"
    end

    # 竞态 3：sidecar current-epoch 仍在进行时，journal 必须仍是 published。
    @tag :task3_g3_recovery_red
    test "g3 race: while the sidecar current-epoch gate is held the journal stays published",
         ctx do
      key = "g3-race-sidecar-epoch-gate.bin"
      journal = sidecar_journal(ctx, key, "published")
      ref = make_ref()

      Script.script(
        :current_epoch,
        {:gate, self(), ref, {:return, g3_published_epoch(journal)}}
      )

      Script.script(:finalize_if_current, {:return, g3_sidecar_finalize_result("finalized")})
      task = Task.async(fn -> Recovery.recover(journal.id, storage_opts: [data_dir: ctx.dir]) end)

      entered = g3_await_gate!(ref, "current_epoch")
      assert entered.operation == :current_epoch

      assert ObjectMutation.get(journal.id).phase == "published",
             "current-epoch 未返回前绝不能推进 journal"

      assert Script.call_count(:finalize_if_current) == 0

      send(entered.caller, {:script_backend_release, ref})
      assert {:ok, _} = Task.await(task, 15_000)
      assert ObjectMutation.get(journal.id).phase == "finalized"
    end

    # 竞态 4：sidecar finalize gate 必须在 pending fence 之后，且**从不**独立 verify。
    @tag :task3_g3_recovery_red
    test "g3 race: the sidecar finalize gate is reached at finalize_pending with zero verify",
         ctx do
      key = "g3-race-sidecar-finalize-gate.bin"
      journal = sidecar_ready_journal(ctx, key, "finalize_pending")
      ref = make_ref()

      Script.script(
        :finalize_if_current,
        {:gate, self(), ref, {:return, g3_sidecar_finalize_result("finalized")}}
      )

      task = Task.async(fn -> Recovery.recover(journal.id, storage_opts: [data_dir: ctx.dir]) end)

      entered = g3_await_gate!(ref, "finalize_if_current")

      assert ObjectMutation.get(journal.id).phase == "finalize_pending"
      assert Script.call_count(:verify_published) == 0, "sidecar adapter 绝不做独立 verify"
      assert Script.call_count(:current_epoch) == 0, "finalize_pending entry 不读 current-epoch"

      send(entered.caller, {:script_backend_release, ref})
      assert {:ok, _} = Task.await(task, 15_000)
      assert ObjectMutation.get(journal.id).phase == "finalized"
    end
  end

  describe "G3 RED: CAS-loss races" do
    setup :g3_script_backend

    # 竞态 5：proof 已返回，但 pending CAS 输给并发赢家——绝不 finalize。
    @tag :task3_g3_recovery_red
    test "g3 race: a lost pending fence after a returned proof performs zero finalize", ctx do
      key = "g3-race-pending-loss.bin"
      journal = pg_journal(ctx, key, "metadata_committed")
      ref = make_ref()

      Script.script(
        :verify_published,
        {:gate, self(), ref, {:return, g3_proof_result("verified")}}
      )

      task = Task.async(fn -> Recovery.recover(journal.id, storage_opts: [data_dir: ctx.dir]) end)

      entered = g3_await_gate!(ref, "verify_published")

      # 在 pending CAS 之前确定性地制造赢家（attempts 精确匹配必然落空）。
      winner = g3_bump_attempts!(journal)

      send(entered.caller, {:script_backend_release, ref})
      result = Task.await(task, 15_000)

      # 【R3 迁移】§3.1：outward reason 只能是精确稳定 code（intentional RED，见报告 R3.5）。
      assert result == {:error, @correction_convergence_failed},
             "pending fence 输掉时必须收敛为精确稳定 convergence code：#{inspect(result)}"

      # fence 就是破坏性 finalize 的授权：它没通过，finalize 必须为零。
      assert Script.call_count(:finalize_if_current) == 0, "pending fence 失败后绝不允许 finalize"

      fresh = ObjectMutation.get(journal.id)
      assert fresh.phase == winner.phase, "绝不覆盖赢家"
      assert fresh.attempts == winner.attempts
      assert fresh.recovery_evidence === winner.recovery_evidence
      assert is_nil(fresh.lease_owner), "必须主动释放本 worker 自己的租约"
      assert is_nil(fresh.lease_expires_at)
    end

    # 竞态 6：proof unavailable 的第一次 CAS 成功、第二次 mark_operational_error CAS 输掉。
    # 用同步的 Ecto query telemetry 在两次 CAS 之间阻塞 Recovery 进程——不新增生产
    # failpoint，也不 sleep/轮询。
    @tag :task3_g3_recovery_red
    test "g3 race: a lost second cas after the proof-unavailable pending write keeps the winner",
         ctx do
      key = "g3-race-second-cas-loss.bin"
      journal = pg_journal(ctx, key, "metadata_committed")
      ref = make_ref()
      gate_ref = make_ref()
      owner = self()

      Script.script(
        :verify_published,
        {:gate, self(), ref, {:return, g3_proof_result("unavailable")}}
      )

      task = Task.async(fn -> Recovery.recover(journal.id, storage_opts: [data_dir: ctx.dir]) end)

      entered = g3_await_gate!(ref, "verify_published")
      recovery_pid = entered.caller
      handler_id = {:g3_second_cas_gate, gate_ref}

      # 只拦截 Recovery 进程对 object_mutations 的**第一条** UPDATE（= pending 转换），
      # handler 内先自摘再阻塞，因此后续 CAS 不会被再次拦下。
      :telemetry.attach(
        handler_id,
        [:maxio, :repo, :query],
        fn _event, _measurements, metadata, _config ->
          if self() == recovery_pid and String.starts_with?(metadata.query, "UPDATE") and
               String.contains?(metadata.query, "object_mutations") do
            :telemetry.detach({:g3_second_cas_gate, gate_ref})
            send(owner, {:g3_first_cas_done, gate_ref, self()})

            receive do
              {:g3_second_cas_release, ^gate_ref} -> :ok
            after
              5_000 -> :ok
            end
          end
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)
      send(entered.caller, {:script_backend_release, ref})

      # 第一次 CAS 的 SQL 已完成，Recovery 阻塞在 handler 内，第二次 CAS 尚未发出。
      assert_receive {:g3_first_cas_done, ^gate_ref, ^recovery_pid}, 5_000

      after_first = ObjectMutation.get(journal.id)

      assert after_first.phase == "finalize_pending",
             "第一次 CAS 必须原子写入 pending + 合并证据 + 稳定 code"

      # 在第二次 CAS 之前制造赢家。
      winner = g3_bump_attempts!(after_first)
      send(recovery_pid, {:g3_second_cas_release, gate_ref})
      _result = Task.await(task, 15_000)

      fresh = ObjectMutation.get(journal.id)

      # 崩在两次 CAS 之间只会留下一个安全、可立即重试的 pending 行；绝不授权回滚。
      assert fresh.phase == "finalize_pending"
      refute fresh.phase in ["rollback_pending", "rolled_back"]
      assert Script.call_count(:finalize_if_current) == 0, "proof 未通过时 finalize 恒为零"

      # 赢家的 pending 证据与 code 保持权威，绝不被输家覆盖。
      assert fresh.recovery_evidence === winner.recovery_evidence, "绝不覆盖赢家的证据"
      assert fresh.last_error === winner.last_error
      assert fresh.attempts == winner.attempts
      assert is_nil(fresh.lease_owner), "只释放本 worker 自己的租约"
    end

    # 竞态 7：sidecar current-epoch 成功，但 published→pending CAS 输掉。
    @tag :task3_g3_recovery_red
    test "g3 race: a lost sidecar published to pending cas performs zero finalize", ctx do
      key = "g3-race-sidecar-pending-loss.bin"
      journal = sidecar_journal(ctx, key, "published")
      ref = make_ref()

      Script.script(
        :current_epoch,
        {:gate, self(), ref, {:return, g3_published_epoch(journal)}}
      )

      task = Task.async(fn -> Recovery.recover(journal.id, storage_opts: [data_dir: ctx.dir]) end)

      entered = g3_await_gate!(ref, "current_epoch")
      winner = g3_bump_attempts!(journal)

      send(entered.caller, {:script_backend_release, ref})
      result = Task.await(task, 15_000)

      # 【R3 迁移】§3.1：outward reason 只能是精确稳定 code（intentional RED，见报告 R3.5）。
      assert result == {:error, @correction_convergence_failed},
             "sidecar pending fence 输掉时必须收敛为精确稳定 convergence code：#{inspect(result)}"

      assert Script.call_count(:finalize_if_current) == 0, "pending fence 失败后绝不允许 finalize"

      fresh = ObjectMutation.get(journal.id)
      assert fresh.phase == winner.phase, "赢家必须保持不变"
      assert fresh.attempts == winner.attempts
      assert fresh.recovery_evidence === winner.recovery_evidence
      assert is_nil(fresh.lease_owner), "只释放本 worker 自己的租约"
    end

    # 竞态 8：finalize 已返回但终态 CAS 输掉——绝不谎报成功；第二个 worker 幂等收敛。
    @tag :task3_g3_recovery_red
    test "g3 race: a lost terminal cas never reports success and a second worker converges",
         ctx do
      key = "g3-race-terminal-loss.bin"
      journal = pg_journal(ctx, key, "metadata_committed")
      ref = make_ref()

      Script.script(:verify_published, {:return, g3_proof_result("verified")})

      Script.script(
        :finalize_if_current,
        {:gate, self(), ref, {:return, g3_finalize_result("finalized")}}
      )

      task = Task.async(fn -> Recovery.recover(journal.id, storage_opts: [data_dir: ctx.dir]) end)

      entered = g3_await_gate!(ref, "finalize_if_current")

      assert Script.call_count(:verify_published) == 1,
             "finalize 之前 proof 必须恰好通过一次"

      # 终态 CAS 之前制造赢家。
      pending = ObjectMutation.get(journal.id)
      assert pending.phase == "finalize_pending"
      _winner = g3_bump_attempts!(pending)

      send(entered.caller, {:script_backend_release, ref})
      result = Task.await(task, 15_000)

      # 【R3 迁移】§3.1：outward reason 只能是精确稳定 code（intentional RED，见报告 R3.5）。
      assert result == {:error, @correction_convergence_failed},
             "终态 CAS 输掉时绝不允许谎报成功，且只能报精确稳定 code：#{inspect(result)}"

      lost = ObjectMutation.get(journal.id)
      refute lost.phase == "finalized", "输家绝不能把 journal 写成终态"
      assert is_nil(lost.lease_owner), "输家必须释放自己的租约"

      # 第二个 worker 经同一入口重新取证并幂等收敛（不等租约过期）。
      Script.script(:verify_published, {:return, g3_proof_result("verified")})
      Script.script(:finalize_if_current, {:return, g3_finalize_result("finalized")})

      assert {:ok, converged} =
               Recovery.recover(lost.id,
                 lease_owner: "g3-worker-b",
                 storage_opts: [data_dir: ctx.dir]
               )

      assert converged.phase == "finalized"
      assert Script.call_count(:verify_published) == 2, "第二个 worker 必须重新取证"
      assert Script.call_count(:finalize_if_current) == 2
      assert is_nil(ObjectMutation.get(lost.id).lease_owner)
    end
  end

  # ── blueprint §7.5 evidence-preservation sentinels ──
  #
  # 每一格都遵循同一个非空洞模式：
  #   1. 先**正向**证明 raw sentinel 真的存在于本次注入的输入里（或被保护的 wrapper 真的
  #      是非 nil 的 canonical 值）；
  #   2. 再分别证明它**不在**持久化结果（evidence term / JSON 字节 / last_error）与结构化
  #      日志里；
  #   3. 同时证明受保护的 term、`Jason.encode!/1` 字节与 fingerprint 逐字不变。
  # 运维失败绝不允许伪装成 proof 失败，也绝不允许覆盖既有证据。

  describe "G3 RED: evidence preservation sentinels" do
    setup :g3_script_backend

    # §6：非 nil 受保护证据 + 对象锁被占 → mark_operational_error，证据 byte-for-term 不变。
    #
    # 【终审纠偏 §5.3 第 7 格】本格原先捕获了 `log` 却从未消费，因此既留下未使用变量警告，
    # 也让「warning-free」的声明不准确。现在真正消费它：断言固定 message 与稳定 metadata，
    # 并 refute 任何受保护 proof 内容进入日志。稳定 reason 的权威断言仍然是行上的精确
    # `last_error`；本批不为日志额外扩张 metadata。
    @tag :task3_g3_recovery_red
    @tag :task3_g3_final_review_correction
    test "g3 sentinel: an object-lock failure preserves a protected pg wrapper", ctx do
      key = "g3-sentinel-object-lock.bin"
      journal = pg_journal(ctx, key, "finalize_pending")
      snapshot = g3_snapshot(journal)

      # 正向前提：受保护的 canonical wrapper 真的存在（否则下面的保全断言是空洞的）。
      refute is_nil(snapshot.wrapper), "本格必须以非 nil 的 canonical wrapper 为前提"
      assert %{"published_proof" => _} = snapshot.wrapper

      parent = self()

      {:ok, _holder} =
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

      {result, log} =
        with_log(@g3_capture_opts, fn ->
          Recovery.recover(journal.id, storage_opts: [data_dir: ctx.dir])
        end)

      assert {:error, :locked} = result
      fresh = ObjectMutation.get(journal.id)

      # 运维失败：只涨 attempts / 推迟重试 / 释放租约，绝不改 phase，绝不覆盖证据。
      assert fresh.phase == snapshot.phase, "对象锁失败绝不改 phase"

      assert fresh.recovery_evidence === snapshot.wrapper,
             "受保护的 canonical wrapper 必须 byte-for-term 保留"

      assert Jason.encode!(fresh.recovery_evidence) == snapshot.wrapper_bytes
      assert fresh.published_fingerprint === snapshot.fingerprint

      assert fresh.last_error == @correction_object_locked,
             "必须写入精确的二进制稳定 code"

      refute String.contains?(fresh.last_error, "\""), "稳定 code 绝不能被 inspect 加引号"
      assert is_nil(fresh.lease_owner), "必须释放本 worker 自己的租约"
      assert_pg_counts!("sentinel/object_lock", 0, 0)

      # 【correction §5.3 第 7 格】真正消费捕获到的 `log`：固定 message + 稳定 metadata。
      assert log =~ "object mutation recovery skipped: object lock held",
             "对象锁跳过必须打出固定 message"

      assert log =~ "action=object_mutation_recovery_decision"
      assert log =~ "outcome=skipped_locked"

      # 受保护的 proof 内容绝不进日志（日志只承载有界白名单标量）。
      refute log =~ "published_proof", "受保护的 proof 键名绝不能进日志"
      refute log =~ snapshot.wrapper_bytes, "完整 wrapper JSON 绝不能进日志"

      refute log =~ Jason.encode!(snapshot.proof),
             "受保护的 proof summary JSON 绝不能进日志"

      # 【correction §5.3】本格**不**注入任何 raw sentinel，因此绝不能靠一条与输入无关的
      # 字符串 refute 充当非空洞性证明。它的权威是上面「非 nil canonical wrapper 正向
      # 快照 → 严格 term/JSON 字节/fingerprint 保全 + 精确稳定 code」这条链。
      send(holder, :release)
      assert_receive :lock_released, 5_000
    end

    # §6：rollback 行已带受保护证据时，restore 失败是 log-only 的次生运维失败。
    @tag :task3_g3_recovery_red
    test "g3 sentinel: a restore failure preserves a protected rollback-pending wrapper", ctx do
      key = "g3-sentinel-restore-failure.bin"
      journal = pg_rollback_pending_journal(ctx, key)
      snapshot = g3_snapshot(journal)

      scripted = {:error, {:unavailable, @g3_restore_sentinel}}

      # 正向：sentinel 真的存在于本次注入的 backend 结果里。
      assert String.contains?(inspect(scripted), @g3_restore_sentinel),
             "注入的 restore 结果必须真的携带 sentinel"

      refute is_nil(snapshot.wrapper)
      Script.script(:restore_if_current, {:return, scripted})

      {_result, fresh, log} = g3_recover(ctx, journal)

      assert Script.call_count(:restore_if_current) == 1
      assert Script.call_count(:verify_published) == 0
      assert Script.call_count(:finalize_if_current) == 0

      assert fresh.phase == "rollback_pending", "restore 失败不得推进或改写主状态"

      assert fresh.recovery_evidence === snapshot.wrapper,
             "受保护证据必须 byte-for-term 保留，绝不被次生运维失败改写"

      assert Jason.encode!(fresh.recovery_evidence) == snapshot.wrapper_bytes
      assert fresh.published_fingerprint === snapshot.fingerprint

      assert fresh.last_error == "object_mutation:restore_failed",
             "必须写入精确的二进制稳定 code"

      refute String.contains?(fresh.last_error, "\"")

      # 反向：raw 原因绝不落库、绝不进日志。
      refute String.contains?(Jason.encode!(fresh.recovery_evidence), @g3_restore_sentinel),
             "raw restore 原因绝不能落库"

      refute String.contains?(fresh.last_error, @g3_restore_sentinel)
      refute String.contains?(log, @g3_restore_sentinel), "raw restore 原因绝不能进日志"
    end

    # §6：租约在 claim 与 renew 之间易主 —— 绝不把诊断信息写到新 owner 头上。
    #
    # 【R1】本格属于**已被独立批准的 G3 批次**（`task3_g3_recovery_red` 69/69 是冻结门），
    # 因此它的 no-action / 不覆盖赢家语义在此原样保留、继续 Green。它对 outward reason 只做
    # 弱断言这一缺口，由纠偏批次的独立新格
    # `g3 correction: a renew ownership loss folds without exposing the new owner` 覆盖：
    # 那一格精确要求稳定 lease code，raw `{:lease_lost, owner}` 无法通过。
    @tag :task3_g3_recovery_red
    test "g3 sentinel: a lease-renewal ownership loss is no-action and never overwrites the winner",
         ctx do
      key = "g3-sentinel-lease-loss.bin"
      journal = pg_journal(ctx, key, "finalize_pending")
      snapshot = g3_snapshot(journal)
      refute is_nil(snapshot.wrapper)

      gate_ref = make_ref()
      owner = self()
      handler_id = {:g3_lease_gate, gate_ref}

      task =
        Task.async(fn ->
          Recovery.recover(journal.id,
            lease_owner: "g3-worker-a",
            storage_opts: [data_dir: ctx.dir]
          )
        end)

      task_pid = task.pid

      # 拦截 recover 进程对 object_mutations 的**第一条** UPDATE（= claim CAS），
      # handler 内先自摘再阻塞，因此后续语句不会被再次拦下。
      :telemetry.attach(
        handler_id,
        [:maxio, :repo, :query],
        fn _event, _measurements, metadata, _config ->
          # claim CAS 是唯一会 `SET ... lease_owner ...` 的语句；renew 只写
          # lease_expires_at/updated_at。据此精确锁定 claim 与 renew 之间的窗口。
          if self() == task_pid and String.starts_with?(metadata.query, "UPDATE") and
               String.contains?(metadata.query, "object_mutations") and
               String.contains?(metadata.query, "lease_owner") do
            :telemetry.detach({:g3_lease_gate, gate_ref})
            send(owner, {:g3_claimed, gate_ref, self()})

            receive do
              {:g3_lease_release, ^gate_ref} -> :ok
            after
              5_000 -> :ok
            end
          end
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      {result, log} =
        with_log(@g3_capture_opts, fn ->
          assert_receive {:g3_claimed, ^gate_ref, ^task_pid}, 5_000

          # claim 已落库、renew 尚未发出：此刻租约被另一个 worker 抢走。
          thief = g3_steal_lease!(journal)
          assert thief.lease_owner == @g3_lease_thief, "正向：租约必须真的已经易主"

          send(task_pid, {:g3_lease_release, gate_ref})
          {Task.await(task, 15_000), thief}
        end)

      {recover_result, thief} = result

      # 注意：带自定义消息的 `assert` 不会做模式重写，因此这里用 `match?/2`。
      assert match?({:error, _reason}, recover_result),
             "租约易主后必须无动作返回，实际：#{inspect(recover_result)}"

      fresh = ObjectMutation.get(journal.id)

      # 绝不把任何诊断写到新 owner 头上，也绝不释放别人的租约。
      assert fresh.lease_owner == @g3_lease_thief, "绝不覆盖新 owner 的租约"
      assert fresh.lease_expires_at === thief.lease_expires_at
      assert fresh.phase == snapshot.phase
      assert fresh.attempts == thief.attempts, "无动作分支绝不涨 attempts"
      assert fresh.last_error === thief.last_error, "绝不把诊断写在赢家行上"

      assert fresh.recovery_evidence === snapshot.wrapper,
             "受保护证据必须 byte-for-term 保留"

      assert Jason.encode!(fresh.recovery_evidence) == snapshot.wrapper_bytes
      assert fresh.published_fingerprint === snapshot.fingerprint
      assert_pg_counts!("sentinel/lease_loss", 0, 0)
      refute String.contains?(log, @g3_lease_thief), "新 owner 标识绝不能作为诊断进日志"
    end

    # §6：Storage trust boundary **之外**的 backend/编排异常（restore 是纯委派，raise
    # 会一路逃到 Recovery 的 rescue）。它绝不允许把异常消息写进 journal 或日志。
    @tag :task3_g3_recovery_red
    test "g3 sentinel: an exception outside the storage trust boundary never leaks its message",
         ctx do
      key = "g3-sentinel-exception.bin"
      journal = pg_rollback_pending_journal(ctx, key)
      snapshot = g3_snapshot(journal)
      refute is_nil(snapshot.wrapper)

      action = {:raise, @g3_exception_sentinel}

      # 正向：sentinel 真的就是本次注入的异常消息。
      assert {:raise, @g3_exception_sentinel} = action
      Script.script(:restore_if_current, action)

      {_result, fresh, log} = g3_recover(ctx, journal)

      assert Script.call_count(:restore_if_current) == 1

      assert fresh.last_error == "object_mutation:recovery_exception",
             "编排异常必须写入精确的二进制稳定 code"

      refute String.contains?(fresh.last_error, "\"")

      assert fresh.recovery_evidence === snapshot.wrapper,
             "编排异常绝不允许覆盖受保护证据"

      assert Jason.encode!(fresh.recovery_evidence) == snapshot.wrapper_bytes
      assert fresh.published_fingerprint === snapshot.fingerprint

      # 反向：异常消息 / inspect 输出绝不落库、绝不进日志。
      refute String.contains?(Jason.encode!(fresh.recovery_evidence), @g3_exception_sentinel),
             "异常消息绝不能落库"

      refute String.contains?(fresh.last_error, @g3_exception_sentinel)
      refute String.contains?(log, @g3_exception_sentinel), "异常消息绝不能进日志"
    end

    # §6：无法派生 mutation context 的行 —— 在**任何** Storage I/O 之前隔离取证。
    #
    # 该行由测试进程的窄 update_all 播种：`bucket_name` 换成 bucket validator 必拒的形态
    # （满足 DB 的 nonblank / target-shape 约束，但 `MutationContext.from_journal/1` 无法
    # 派生 target）。blueprint §6 规定的收敛动作是
    # `ObjectMutation.quarantine_preserving_evidence/3`——它走窄 update_all CAS，**不经**
    # `Journal.changeset/2`，因此这一行完全可写；而入口生产用的是 evidence-writing 的
    # `quarantine/4`（经 changeset 且覆盖证据），这正是本格要锁死的能力差异。
    @tag :task3_g3_recovery_red
    test "g3 sentinel: an invalid mutation context quarantines before any storage io", ctx do
      key = "g3-sentinel-context.bin"
      journal = pg_journal(ctx, key, "finalize_pending")

      {:ok, seeded} = g3_seed_row!(journal, bucket_name: @g3_invalid_bucket)
      snapshot = g3_snapshot(seeded)

      # 正向：这一行**确实**无法派生 context（否则本格测的就不是 context-invalid）。
      assert {:error, _reason} = MutationContext.from_journal(seeded),
             "本格前提：该行必须真的无法派生 mutation context"

      refute is_nil(snapshot.wrapper)

      {_result, fresh, log} = g3_recover(ctx, seeded)

      # context 判定属于 authority/phase 预路由之后、任何端点 I/O 之前。
      assert_pg_counts!("sentinel/context_invalid", 0, 0)

      assert fresh.phase == "quarantined",
             "context 无效必须经 preserving quarantine 收敛，实际 #{fresh.phase}"

      assert fresh.last_error == "object_mutation:context_invalid",
             "必须写入精确的二进制稳定 code"

      refute String.contains?(fresh.last_error, "\"")
      assert is_nil(fresh.lease_owner), "隔离必须清租约"
      assert is_nil(fresh.lease_expires_at)

      # evidence-preserving：term、JSON 字节与 fingerprint 逐字不变。
      assert fresh.recovery_evidence === snapshot.wrapper,
             "context-invalid 隔离必须 evidence-preserving"

      assert Jason.encode!(fresh.recovery_evidence) == snapshot.wrapper_bytes
      assert fresh.published_fingerprint === snapshot.fingerprint

      # 被播种的非法 locator 绝不允许作为 raw 诊断落库或进日志。
      refute String.contains?(Jason.encode!(fresh.recovery_evidence), @g3_invalid_bucket)
      refute String.contains?(fresh.last_error, @g3_invalid_bucket)
      refute String.contains?(log, @g3_invalid_bucket), "raw locator 绝不能进日志"
    end

    # 【blueprint §7.5 结尾 + review correction §3】Recovery 绝不依赖
    # `ObjectCommit.Control` 或任何加速器。正确的边界是**AST 感知**的静态断言：裸文本
    # 搜索会把 Recovery **文档里**提到的 Control 误判成依赖（假 RED）。这里先剥掉
    # `@moduledoc` / `@doc` 子树，再只在**可执行**语法上判定 alias/import/require、
    # 远程调用与模块引用，以及 `:accelerate` 的构造/匹配；注释、文档与字符串一律不算。
    #
    # 修正之后本格按设计即 Green：它是架构边界锁，而不是能力缺失 RED。
    @tag :task3_g3_recovery_red
    test "g3 static: recovery has no control or accelerator dependency" do
      recovery = executable_ast!("lib/maxio/object_mutation/recovery.ex")
      commit = executable_ast!("lib/maxio/object_mutation/commit.ex")

      # 正对照：同一探测器必须在已知的加速器 owner（Commit）上真的报出依赖，
      # 否则下面三条 refute 只是空洞的。
      assert control_dependencies(commit) != [],
             "对照组：探测器必须在 Commit 上真的检出 ObjectCommit.Control 依赖"

      assert accelerator_nodes(commit) != [],
             "对照组：探测器必须在 Commit 上真的检出可执行的 :accelerate 语义"

      assert mark_committed_calls(commit) != [],
             "对照组：探测器必须在 Commit 上真的检出 mark_committed 调用"

      # 被测边界：Recovery 的**可执行**语法里零依赖。
      assert control_dependencies(recovery) == [],
             "Recovery 绝不允许在可执行语法里引用 ObjectCommit.Control"

      assert accelerator_nodes(recovery) == [],
             "Recovery 绝不允许构造或匹配 :accelerate"

      assert mark_committed_calls(recovery) == [],
             "Recovery 绝不允许调用 mark_committed 加速器"
    end
  end

  # ══ Task 3 G3 终审纠偏 — Phase A tests-only RED（handoff §5.3 / §5.4）══
  #
  # 全部标 `:task3_g3_final_review_correction`，针对**冻结的入口生产** `2FE164...` 运行。
  # 每格独立生成、独立可选、非空洞：先用公共 API 正向证明注入的输入确实携带 raw
  # sentinel（或确实是合法的 canonical 前提），再证明它绝不出现在 result / log /
  # last_error / evidence 里。

  # ── §5.2 仪器标定（**不是** capability RED）──
  #
  # 四个 renew RED 格的 count/ordering 断言在冻结生产上不可达（outward 断言先失败，或异常
  # 直接逃逸），因此 `RecoveryScriptRepo` 的 operation 识别必须**单独**被正向标定，否则
  # reviewer 无从判断那些计数断言本身是否可信。本格用一次真实的、零故障的 `Recovery.recover/2`
  # 驱动全 delegate 路径，证明四类 operation 依 `set` 精确 key 集合被正确识别与计数。
  @tag :task3_g3_final_review_correction
  test "g3 correction calibration: the script repo recognises claim/renew/release by exact key set",
       ctx do
    start_supervised!(ScriptRepo)
    {:ok, journal} = ObjectMutation.prepare(prepare_attrs(ctx, "g3c-calibration.bin", 1))

    # 零故障：全部 delegate，真实生产语义不变（prepared + epoch absent → rolled_back）。
    assert {:ok, recovered} =
             Recovery.recover(journal.id, repo: ScriptRepo, storage_opts: [data_dir: ctx.dir])

    assert recovered.phase == "rolled_back"

    driven = ScriptRepo.counts()

    assert driven.claim == 1, "claim 必须被精确识别一次（lease_owner/lease_expires_at/updated_at 非 nil）"
    assert driven.renew == 1, "renew 必须被精确识别一次（恰为 lease_expires_at/updated_at）"
    assert driven.journal_write >= 1, "其余 journal 写必须落到 journal_write"

    # 顺序与执行进程：claim 在测试进程，renew 在对象锁的独立 worker 进程内——这正是
    # 四个 RED 格用来证明「故障命中 renew 而不是 claim」的同一条取证链。
    calls = ScriptRepo.calls()
    claim_call = Enum.find(calls, &(&1.operation == :claim))
    renew_call = Enum.find(calls, &(&1.operation == :renew))

    assert claim_call.index < renew_call.index
    assert claim_call.caller == self(), "claim 由 Recovery 调用方进程发出"
    refute renew_call.caller == self(), "renew 在 Lock 的独立 worker 进程内发出"

    # `:release` 在这条终局路径上不出现（终态 transition 在同一次写里清租约），因此单独
    # 用公共 API 正向标定它：同一 key 集合、owner/expiry 均为 nil → 必须识别为 :release，
    # 而不是 :claim。这也证明分类器确实按 value 形状而非 key 集合单独判定。
    {:ok, other} = ObjectMutation.prepare(prepare_attrs(ctx, "g3c-calibration-release.bin", 1))
    before_release = ScriptRepo.counts()

    assert {:ok, claimed} = ObjectMutation.claim(other, "g3c-calibrator", repo: ScriptRepo)
    assert {:ok, released} = ObjectMutation.release_lease(claimed, repo: ScriptRepo)
    assert is_nil(released.lease_owner)

    after_release = ScriptRepo.counts()

    assert after_release.claim == before_release.claim + 1,
           "非 nil owner/expiry 的同一 key 集合必须识别为 :claim"

    assert after_release.release == before_release.release + 1,
           "全 nil owner/expiry 的同一 key 集合必须识别为 :release"

    assert after_release.renew == before_release.renew, "release 绝不能被误判为 renew"

    # 未配置任何 action：脚本队列必须全空，全部走 delegate。
    assert ScriptRepo.remaining_all() == %{claim: 0, renew: 0, release: 0, journal_write: 0}

    # 【R2】完整持久化行不变量机器的正向标定。零写入格与 merge 隔离格里的行断言在冻结
    # 生产上都不可达（outward 断言先失败），因此这套投影/掩码/差分机器必须**单独**被证明
    # 可用，否则 reviewer 无从判断它们是真断言还是坏 fixture。
    schema_fields = Journal.__schema__(:fields)
    projection = correction_row_snapshot(recovered)

    # 投影覆盖 schema 全部持久化字段，且按构造排除非持久化 struct 元数据。
    assert Map.keys(projection) |> Enum.sort() == Enum.sort(schema_fields)
    refute Map.has_key?(projection, :__meta__), "非持久化 struct 元数据必须被按构造排除"

    # 正向：几个关键列真的在不变量里（防止 schema 反射静默退化成空集合）。
    for field <- [
          :id,
          :bucket_name,
          :object_key,
          :version_id,
          :generation,
          :operation,
          :authority_mode,
          :backend,
          :placement_snapshot,
          :previous_epoch,
          :attempts,
          :next_attempt_at,
          :recovery_evidence,
          :published_fingerprint,
          :updated_at
        ] do
      assert Map.has_key?(projection, field), "完整行投影必须包含持久化字段 #{field}"
    end

    # 未改动的行：完整比较（含 updated_at）必须通过，且差分为空。
    assert_correction_row_unchanged!(recovered, projection, "calibration/unchanged")
    assert correction_row_diff(projection, projection) == []

    # 负向：任意单字段改动都必须被差分抓到，且未授权时必须被掩码断言拒绝。
    mutated = %Journal{recovered | attempts: recovered.attempts + 1}
    mutated_projection = correction_row_snapshot(mutated)

    assert correction_row_diff(mutated_projection, projection) == [:attempts],
           "差分器必须精确定位被改动的持久化字段"

    assert_raise ExUnit.AssertionError, fn ->
      assert_only_authorized_fields_changed!(
        mutated,
        projection,
        @correction_quarantine_authorized_fields,
        "calibration/unauthorized"
      )
    end

    # 正向：把同一改动列为授权字段时必须通过——证明掩码不是恒假。
    assert_only_authorized_fields_changed!(
      mutated,
      projection,
      [:attempts],
      "calibration/authorized"
    )
  end

  # ── §5.3 稳定错误动态矩阵 ──

  describe "G3 correction RED: stable operational boundary" do
    setup :g3_script_backend

    # 第 1 格：claim 的底层 rescue 会把 `Exception.message/1` 放进 outward reason。
    @tag :task3_g3_final_review_correction
    test "g3 correction: a claim exception folds to the stable claim code without leaking its message",
         ctx do
      key = "g3c-claim-exception.bin"
      journal = pg_journal(ctx, key, "finalize_pending")
      snapshot = g3_snapshot(journal)
      row = correction_row_snapshot(journal)

      # 正向前提：受保护的 canonical wrapper 真的存在。
      refute is_nil(snapshot.wrapper)

      # 传 struct（而不是 id）：`recover/2` 的 id 子句会先经同一个 repo 读，
      # 那条路径不在本格的被测边界内。
      {result, log} =
        with_log(@g3_capture_opts, fn ->
          Recovery.recover(journal, repo: RejectingRepo, storage_opts: [data_dir: ctx.dir])
        end)

      # 正向证明 claim 的 SQL seam 真的被越过（否则本格是空洞的）。
      repo_tag = RejectingRepo.message_tag()
      assert_received {^repo_tag, :update_all}

      assert result == {:error, @correction_claim_failed},
             "claim 的任何非 :not_found/:not_due_or_leased 失败都必须折叠成精确稳定 code：" <>
               inspect(result)

      # 【R1】结构化日志必须携带**精确**的稳定 reason，而不是任何 raw 文本。
      assert log =~ "reason=#{@correction_claim_failed}",
             "claim 失败的结构化日志 reason 必须是精确稳定 code：" <> log

      # raw 异常文本绝不进 result / log / journal（含整行 inspect 与全部持久化字段）。
      refute String.contains?(inspect(result), RejectingRepo.sentinel())
      refute String.contains?(log, RejectingRepo.sentinel())
      refute String.contains?(log, "journal_claim_failed")
      refute String.contains?(inspect(result), "journal_claim_failed")

      fresh = ObjectMutation.get(journal.id)
      refute String.contains?(inspect(fresh), RejectingRepo.sentinel()), "整行绝不允许携带 sentinel"
      refute String.contains?(Jason.encode!(fresh.recovery_evidence), RejectingRepo.sentinel())
      refute String.contains?(to_string(fresh.last_error || ""), RejectingRepo.sentinel())

      # 【R1】claim 在 SQL 边界前就爆掉：这条路径允许的写为零，整行逐字不变。
      assert_correction_row_unchanged!(fresh, row, "correction/claim_exception")

      # 受保护 term / JSON 字节 / fingerprint 逐字不变。
      assert fresh.recovery_evidence === snapshot.wrapper
      assert Jason.encode!(fresh.recovery_evidence) == snapshot.wrapper_bytes
      assert fresh.published_fingerprint === snapshot.fingerprint
      assert_pg_counts!("correction/claim_exception", 0, 0)
    end

    # 【R1 新增独立格】claim CAS 写成功但读回的那一行属于**另一个 owner**。
    #
    # 冻结生产在 `recovery.ex:154-155` 把 `other.lease_owner` 直接放进 outward tuple
    # （`{:stale, {:lease_lost, other.lease_owner}}`），因此本格必然 RED：它同时泄漏
    # observed owner 与 raw tuple，且完全不打稳定 reason 日志。§3.1 要求这条路径对外
    # 只能是 `object_mutation:claim_failed`，绝不返回 observed owner。
    @tag :task3_g3_final_review_correction
    test "g3 correction: a claim readback owned by another worker folds without exposing the owner",
         ctx do
      key = "g3c-claim-other-owner.bin"
      start_supervised!(ScriptRepo)
      journal = pg_journal(ctx, key, "finalize_pending")

      # 真实地让另一个 worker 持有租约（不是伪造的字符串）。
      t0 = DateTime.utc_now()
      assert {:ok, other} = ObjectMutation.claim(journal, @correction_other_owner, now: t0)
      assert other.lease_owner == @correction_other_owner, "正向：另一 owner 必须真的持租"

      other_row = correction_row_snapshot(other)
      snapshot = g3_snapshot(other)
      refute is_nil(snapshot.wrapper)

      # 确定性地伪造「CAS 报告写中 1 行」，而实际零写入：读回必然是另一 owner 的行。
      ScriptRepo.script(:claim, {:return, {1, nil}})

      {result, log} =
        with_log(@g3_capture_opts, fn ->
          Recovery.recover(journal.id,
            repo: ScriptRepo,
            now: DateTime.add(t0, 5, :second),
            lease_owner: @correction_self_owner,
            storage_opts: [data_dir: ctx.dir]
          )
        end)

      # 正向：脚本条目被精确消费，claim 恰好一次。
      assert ScriptRepo.counts().claim == 1
      assert ScriptRepo.remaining(:claim) == 0, "脚本条目必须被精确消费"

      assert result == {:error, @correction_claim_failed},
             "claim 读回他人租约必须只报稳定 code，绝不返回 observed owner：" <> inspect(result)

      assert log =~ "reason=#{@correction_claim_failed}",
             "该路径必须打出精确稳定 reason：" <> log

      # observed owner 与 raw tuple 绝不出现在任何对外面。
      refute String.contains?(inspect(result), @correction_other_owner),
             "outward result 绝不允许暴露 observed owner"

      refute String.contains?(log, @correction_other_owner), "日志绝不允许暴露 observed owner"
      refute String.contains?(inspect(result), "lease_lost")
      refute String.contains?(log, "lease_lost")

      # 零写入：renew/release/journal_write 全零，另一 owner 的行逐字不变。
      counts = ScriptRepo.counts()
      assert counts.renew == 0, "读回他人租约后绝不允许 renew"
      assert counts.release == 0, "绝不允许释放别人的租约"
      assert counts.journal_write == 0, "绝不允许把任何诊断写到别人的行上"

      fresh = ObjectMutation.get(journal.id)
      assert fresh.lease_owner == @correction_other_owner, "绝不覆盖另一 owner"
      assert_correction_row_unchanged!(fresh, other_row, "correction/claim_other_owner")
      refute String.contains?(inspect(fresh), @correction_self_owner)
      assert_pg_counts!("correction/claim_other_owner", 0, 0)
    end

    # 边界正控：既有公共控制结果绝不被新的折叠改写（§3.1 明令保留）。
    @tag :task3_g3_final_review_correction
    test "g3 correction: the claim fold never rewrites not_found or not_due_or_leased", ctx do
      assert Recovery.recover(Ecto.UUID.generate(), storage_opts: [data_dir: ctx.dir]) ==
               {:error, :not_found}

      key = "g3c-claim-preserved.bin"
      journal = pg_journal(ctx, key, "finalize_pending")
      t0 = DateTime.utc_now()

      # 先由 workerA 持有有效租约，workerB 在租期内即 :not_due_or_leased。
      assert {:ok, _leased} = ObjectMutation.claim(journal, "g3c-worker-a", now: t0)

      assert Recovery.recover(journal.id,
               now: DateTime.add(t0, 5, :second),
               lease_owner: "g3c-worker-b",
               storage_opts: [data_dir: ctx.dir]
             ) == {:error, :not_due_or_leased}

      assert_pg_counts!("correction/claim_preserved", 0, 0)
    end

    # 第 2-5 格：renew 的四个故障域，各自独立成格。
    for {variant, phrase} <- @correction_renew_cells do
      @tag :task3_g3_final_review_correction
      test "g3 correction: renew #{variant} folds to the stable lease code (#{phrase})", ctx do
        variant = unquote(variant)
        key = "g3c-renew-#{variant}.bin"

        start_supervised!(ScriptRepo)
        journal = pg_journal(ctx, key, "finalize_pending")
        snapshot = g3_snapshot(journal)
        refute is_nil(snapshot.wrapper)

        action = correction_renew_action(variant)

        # 正向：故障 action 真的携带本格的 raw sentinel（normal_error 格没有 sentinel，
        # 它的非空洞性由「真实 CAS/refetch 产出携带 phase/attempts 的原始 reason」保证）。
        case correction_renew_sentinel(variant) do
          nil ->
            assert action == {:return, {0, nil}},
                   "normal_error 格必须让真实 `renew_lease` 经 CAS/refetch 产出正常 error"

          sentinel ->
            assert String.contains?(inspect(action), sentinel),
                   "#{variant}：被注入的 renew action 必须真的携带 raw sentinel"
        end

        ScriptRepo.script(:renew, action)

        {result, log} =
          with_log(@g3_capture_opts, fn ->
            Recovery.recover(journal.id,
              repo: ScriptRepo,
              lease_owner: @correction_lease_owner_probe,
              storage_opts: [data_dir: ctx.dir]
            )
          end)

        assert result == {:error, @correction_lease_renewal_failed},
               "#{variant}：renew 的任何失败域都必须折叠成同一个精确 lease 稳定 code：" <>
                 inspect(result)

        # 故障精确命中 renew，而不是 claim：claim 先被调用且逐字 delegate 成功。
        counts = ScriptRepo.counts()
        assert counts.claim == 1, "#{variant}：claim 必须恰好一次且 delegate 成功"
        assert counts.renew == 1, "#{variant}：renew 必须恰好一次"
        assert counts.journal_write == 1, "#{variant}：evidence-preserving 运维写恰好一次"
        assert counts.release == 1, "#{variant}：本 worker 必须主动释放自己的租约"

        assert ScriptRepo.remaining_all() == %{
                 claim: 0,
                 renew: 0,
                 release: 0,
                 journal_write: 0
               },
               "#{variant}：脚本条目必须被精确消费"

        calls = ScriptRepo.calls()
        claim_call = Enum.find(calls, &(&1.operation == :claim))
        renew_call = Enum.find(calls, &(&1.operation == :renew))

        assert claim_call.index < renew_call.index,
               "#{variant}：故障必须发生在 claim 之后的 renew 上"

        # 【R1】结构化日志的 reason 必须是**精确**稳定 lease code。
        assert log =~ "reason=#{@correction_lease_renewal_failed}",
               "#{variant}：结构化日志 reason 必须是精确稳定 lease code：" <> log

        # 运维失败绝不泄漏 sentinel / owner / stale tuple。
        sentinel = correction_renew_sentinel(variant)

        fresh = ObjectMutation.get(journal.id)

        # 【R1】result / log / 整行 journal 三个面统一 refute 同一组泄漏形态。
        leak_surfaces = [inspect(result), log, inspect(fresh)]

        for surface <- leak_surfaces do
          if sentinel do
            refute String.contains?(surface, sentinel),
                   "#{variant}：raw sentinel 绝不允许出现在 result/log/journal"
          end

          refute String.contains?(surface, "stale_journal"),
                 "#{variant}：raw stale tuple 绝不允许出现在 result/log/journal"

          refute String.contains?(surface, "lease_lost"),
                 "#{variant}：raw lease_lost tuple 绝不允许出现在 result/log/journal"

          refute String.contains?(surface, @correction_lease_owner_probe),
                 "#{variant}：lease owner 绝不允许作为诊断出现在 result/log/journal"
        end

        # attempts 数字与 entry phase 绝不作为 raw 诊断进入 result 或 log。
        refute String.contains?(inspect(result), "finalize_pending"),
               "#{variant}：outward reason 绝不允许携带 phase"

        refute String.contains?(Jason.encode!(fresh.recovery_evidence), "stale_journal")

        # 受保护 wrapper / fingerprint 逐字不变；稳定 code 落库；租约释放。
        assert fresh.recovery_evidence === snapshot.wrapper
        assert Jason.encode!(fresh.recovery_evidence) == snapshot.wrapper_bytes
        assert fresh.published_fingerprint === snapshot.fingerprint
        assert fresh.last_error == @correction_lease_renewal_failed
        refute String.contains?(fresh.last_error, "\"")
        assert is_nil(fresh.lease_owner), "#{variant}：必须只释放本 worker 自己的租约"

        # 运维失败绝不伪装成 proof 失败：storage 四个受控操作恒零。
        assert_pg_counts!("correction/renew:#{variant}", 0, 0)
      end
    end

    # 【R1 coordinator correction】§3.2 的 **renew fresh-row owner-changed** 分支：
    # 与上面的 claim-readback 格是**不同的生产分支**（`recovery.ex:196-204`，而不是
    # `:154-155`）。精确窗口：claim 成功 → renew 恰好一次且 CAS 未命中 → **在其后的
    # `cas_result` fresh 读之前**租约被另一个 owner 装上 → `lease_renewal_failed/3` 的
    # fresh 读看到 owner 已变更 → §3.2 要求「零写入 + 同一稳定 lease code」。
    #
    # 同步点用脚本 repo 的 `{:run, fun}`：fun 在 caller 进程内、恰好替换那一次 renew
    # `update_all` 执行，因此扰动必然落在 CAS 判定与 fresh 读之间。零 sleep、零轮询、
    # 零 telemetry。
    @tag :task3_g3_final_review_correction
    test "g3 correction: a renew owner change folds to the stable lease code with zero writes",
         ctx do
      key = "g3c-renew-owner-changed.bin"
      start_supervised!(ScriptRepo)
      journal = pg_journal(ctx, key, "finalize_pending")
      snapshot = g3_snapshot(journal)
      refute is_nil(snapshot.wrapper)

      parent = self()
      gate = make_ref()

      # renew 的 CAS 判定为未命中（返回 `{0, nil}`），但在**返回之前**先把控制权交回测试
      # 进程：测试进程（sandbox 连接的持有者）在这个窗口里装上另一个 owner，然后放行。
      # 于是扰动必然落在「renew CAS 未命中」与「其后的 cas_result fresh 读」之间。
      ScriptRepo.script(
        :renew,
        {:run,
         fn ->
           send(parent, {:g3c_renew_window, gate, self()})

           receive do
             {:g3c_window_done, ^gate} -> :ok
           after
             5_000 -> :ok
           end

           {0, nil}
         end}
      )

      # 正向：脚本条目真的登记成功（否则 renew 计数会被空队列的 delegate 满足，
      # 断言就变成空洞的）。
      assert ScriptRepo.remaining(:renew) == 1, "renew 脚本条目必须真的登记"

      task =
        Task.async(fn ->
          with_log(@g3_capture_opts, fn ->
            Recovery.recover(journal.id,
              repo: ScriptRepo,
              lease_owner: @correction_self_owner,
              storage_opts: [data_dir: ctx.dir]
            )
          end)
        end)

      # 正向：renew 窗口真的被进入（证明故障点精确落在 renew 上，而不是 claim）。
      assert_receive {:g3c_renew_window, ^gate, renew_pid}, 5_000

      thief = g3_steal_lease!(journal)
      assert thief.lease_owner == @g3_lease_thief, "正向：renew 窗口内租约必须真的已经易主"

      send(renew_pid, {:g3c_window_done, gate})
      {result, log} = Task.await(task, 15_000)

      # 正向：claim 成功且 renew 恰好一次（故障命中 renew，不是 claim）。
      counts = ScriptRepo.counts()

      assert counts.claim == 1,
             "claim 必须恰好一次且 delegate 成功（counts=#{inspect(counts)} result=#{inspect(result)}）"

      assert counts.renew == 1,
             "renew 必须被恰好调用一次（counts=#{inspect(counts)} result=#{inspect(result)}）"

      assert ScriptRepo.remaining(:renew) == 0, "脚本条目必须被精确消费"

      calls = ScriptRepo.calls()
      claim_call = Enum.find(calls, &(&1.operation == :claim))
      renew_call = Enum.find(calls, &(&1.operation == :renew))
      assert claim_call.index < renew_call.index, "扰动必须发生在 claim 之后的 renew 上"

      assert result == {:error, @correction_lease_renewal_failed},
             "renew 的 owner-changed 分支必须只报稳定 lease code，绝不返回 raw lease_lost：" <>
               inspect(result)

      assert log =~ "reason=#{@correction_lease_renewal_failed}",
             "owner-changed 分支的结构化日志 reason 必须是精确稳定 code：" <> log

      for surface <- [inspect(result), log] do
        refute String.contains?(surface, "lease_lost"),
               "raw lease_lost tuple 绝不允许出现在 result/log"

        refute String.contains?(surface, "stale_journal")

        refute String.contains?(surface, @g3_lease_thief),
               "新 owner 绝不允许作为诊断出现在 result/log"

        refute String.contains?(surface, @correction_self_owner),
               "本 worker 的 lease owner 同样绝不允许作为诊断出现"
      end

      # §3.2：owner 已变更 → **零写入**，赢家行逐字不变。
      assert counts.journal_write == 0, "owner 已变更时绝不允许任何 journal 写"
      assert counts.release == 0, "绝不允许释放别人的租约"

      fresh = ObjectMutation.get(journal.id)
      assert fresh.lease_owner == @g3_lease_thief, "绝不覆盖新 owner 的租约"
      assert fresh.lease_expires_at === thief.lease_expires_at
      assert fresh.attempts == thief.attempts, "owner 已变更时绝不涨 attempts"
      assert fresh.last_error === thief.last_error, "绝不把诊断写在赢家行上"
      assert fresh.recovery_evidence === snapshot.wrapper
      assert Jason.encode!(fresh.recovery_evidence) == snapshot.wrapper_bytes
      assert fresh.published_fingerprint === snapshot.fingerprint
      assert_pg_counts!("correction/renew_owner_changed", 0, 0)
    end

    # 第 6 格：锁内收敛 CAS 输掉时，原 reason 携带 phase/attempts，稳定 code 绝不含。
    @tag :task3_g3_final_review_correction
    test "g3 correction: a lost convergence cas reports only the stable code without attempts",
         ctx do
      key = "g3c-convergence-sentinel.bin"
      journal = sidecar_journal(ctx, key, "published")
      ref = make_ref()

      Script.script(
        :current_epoch,
        {:gate, self(), ref, {:return, g3_published_epoch(journal)}}
      )

      task =
        Task.async(fn ->
          with_log(@g3_capture_opts, fn ->
            Recovery.recover(journal.id, storage_opts: [data_dir: ctx.dir])
          end)
        end)

      entered = g3_await_gate!(ref, "current_epoch")

      # 在 pending CAS 之前把赢家的 attempts 确定性设为明显 sentinel。
      winner = correction_set_attempts!(journal, @correction_attempts_sentinel)
      assert winner.attempts == @correction_attempts_sentinel

      # 正向证明：底层公共 API 对同一 stale 行**确实**产出携带 phase/attempts 的原始
      # reason（这次 CAS 必然落空，因此不写库、不污染 fixture）。
      assert {:error, {:stale_journal, "published", @correction_attempts_sentinel}} =
               ObjectMutation.transition(journal, "finalize_pending", %{}),
             "非空洞前提：CAS loser 的原始 reason 本会携带 phase 与 attempts"

      send(entered.caller, {:script_backend_release, ref})
      {result, log} = Task.await(task, 15_000)

      sentinel_text = Integer.to_string(@correction_attempts_sentinel)

      assert result == {:error, @correction_convergence_failed},
             "收敛 CAS 输掉必须只报稳定 code：#{inspect(result)}"

      # 【R1】正向：`log_no_action` 的 reason 必须是**精确**稳定 convergence code。
      assert log =~ "reason=#{@correction_convergence_failed}",
             "`log_no_action` 的 reason 必须是精确稳定 code：" <> log

      refute String.contains?(inspect(result), sentinel_text),
             "outward reason 绝不允许携带 attempts"

      refute String.contains?(log, sentinel_text),
             "`log_no_action` 的 reason 绝不允许携带 attempts"

      refute String.contains?(log, "stale_journal"), "结构化日志绝不允许泄漏 raw tuple"
      refute String.contains?(inspect(result), "stale_journal")
      assert Script.call_count(:finalize_if_current) == 0, "pending fence 失败后绝不 finalize"

      # 赢家逐字不变；本 worker 只释放自己的租约。
      fresh = ObjectMutation.get(journal.id)
      assert fresh.phase == winner.phase
      assert fresh.attempts == winner.attempts
      assert fresh.recovery_evidence === winner.recovery_evidence
      assert fresh.published_fingerprint === winner.published_fingerprint
      assert is_nil(fresh.lease_owner)
    end
  end

  # ── §5.4 merge rejection oracle：公共 API 真实可达的 1,024/1,025 integer-token 边界 ──

  describe "G3 correction RED: mode-aware pg merge adapter" do
    setup :g3_script_backend

    for {mode, kind, target} <- @correction_merge_cells do
      @tag :task3_g3_final_review_correction
      test "g3 correction: #{mode} #{kind} merge rejection quarantines with the #{mode} contract code",
           ctx do
        mode = unquote(mode)
        kind = unquote(kind)
        target = unquote(target)
        mode_atom = String.to_existing_atom(mode)
        key = "g3c-merge-#{mode}-#{kind}.bin"

        # 【R1】proof-mode 三格从 `metadata_committed` 进入——那是 proof caller 的真实
        # 入口相位，也是唯一能证明「拒绝时绝不先推进 finalize_pending」的相位；
        # finalize-mode 三格保持 `finalize_pending`（finalize caller 的真实入口）。
        entry_phase = correction_merge_entry_phase(mode)
        start_supervised!(ScriptRepo)
        journal = pg_journal(ctx, key, entry_phase)
        snapshot = g3_snapshot(journal)
        row = correction_row_snapshot(journal)

        # 【R1】用既有 FS 协议 helper 播一份**真实且可解码**的 durable backup，
        # 之后正向证明 evidence-preserving 隔离绝不删除它。
        backup = correction_seed_backup!(ctx, journal)

        assert {:ok, _decoded} = MutationBackup.decode(File.read!(backup.manifest)),
               "#{mode}/#{kind}：播下的 backup manifest 必须是真实合法的协议产物"

        # 正控 1：old wrapper 对 entry 与 merge target 都通过 durable validator。
        assert PublishedProof.validate_durable_evidence(entry_phase, snapshot.wrapper) == :ok
        assert PublishedProof.validate_durable_evidence(target, snapshot.wrapper) == :ok

        # 正控 2：1,025 位 callback 通过公共 facade。
        rejected = correction_callback(mode, kind, @correction_required_1025)
        assert PublishedProof.validate_callback_result(mode_atom, rejected) == :ok

        rejected_summary = correction_summary_of(rejected)

        # 正向 raw sentinel：1,025 位十进制 token 真的在这个 summary 里。
        assert String.contains?(Jason.encode!(rejected_summary), @correction_token_prefix),
               "#{mode}/#{kind}：被注入的 summary 必须真的携带超限 integer token"

        # 正控 3：StorageDisposition 给出表中精确 disposition，且 summary 严格同一。
        assert correction_disposition(mode, rejected) ===
                 correction_expected_disposition(kind, rejected_summary)

        # 正控 4：同一 target 上 merge 被精确拒绝——这就是 RED 的根因。
        assert PublishedProof.merge_failure(target, snapshot.wrapper, rejected_summary) ==
                 {:error, :invalid_proof_evidence}

        # 正控 5：同构 1,024 位仍 facade-valid，且对同一 old wrapper / target 合并成功并
        # 通过 target durable validator——证明拒绝来自精确 integer-token 边界，而不是
        # 非法 fixture，也不是近 60-KiB 的整体 wrapper 超限。
        accepted = correction_callback(mode, kind, @correction_required_1024)
        assert PublishedProof.validate_callback_result(mode_atom, accepted) == :ok

        assert {:ok, merged} =
                 PublishedProof.merge_failure(
                   target,
                   snapshot.wrapper,
                   correction_summary_of(accepted)
                 )

        assert PublishedProof.validate_durable_evidence(target, merged) == :ok

        # 经真实 Recovery 入口取证：finalize caller 必须先让 proof 通过。
        if mode == "finalize" do
          Script.script(:verify_published, {:return, g3_proof_result("verified")})
          Script.script(:finalize_if_current, {:return, rejected})
        else
          Script.script(:verify_published, {:return, rejected})
        end

        {result, log} =
          with_log(@g3_capture_opts, fn ->
            Recovery.recover(journal.id, repo: ScriptRepo, storage_opts: [data_dir: ctx.dir])
          end)

        fresh = ObjectMutation.get(journal.id)
        label = "correction/merge:#{mode}/#{kind}"

        # merge 拒绝 = 内部 durable 契约违约：从当前原 journal 直接 evidence-preserving
        # 隔离，绝不写入被拒绝的 merged value，绝不先推进 finalize_pending。
        assert {:ok, %Journal{phase: "quarantined"}} = result
        assert fresh.phase == "quarantined"

        # 【R1】结构化的「恰好一次隔离写」证明：整条路径只允许一次 journal 写。
        # 任何中间 pending/retry 写都会让计数变成 2 或以上。
        counts = ScriptRepo.counts()

        assert counts.journal_write == 1,
               "#{label}：拒绝必须从原 journal 直接一次 evidence-preserving 隔离写，" <>
                 "绝不允许中间 pending/retry 写（实际 #{counts.journal_write}）"

        # 【R2】完整持久化行不变量：**只有**契约授权的 6 个字段可以改变，其余每一个
        # `Journal.__schema__(:fields)` 字段（locator/target、generation、operation、
        # authority_mode、backend、placement_snapshot、previous_epoch、attempts、
        # next_attempt_at、evidence、fingerprint、未授权时间戳……）必须逐字 `===`。
        # 这同时覆盖了旧版手挑的 attempts / next_attempt_at / metadata_committed_at 断言。
        assert_only_authorized_fields_changed!(
          fresh,
          row,
          @correction_quarantine_authorized_fields,
          label
        )

        # 【R2】逐个断言授权字段的**精确目标语义**（掩码不等于放行）。
        assert fresh.phase == "quarantined", "#{label}：授权字段 phase 的目标态必须是 quarantined"
        assert is_nil(fresh.lease_owner), "#{label}：终态必须清空 lease_owner"
        assert is_nil(fresh.lease_expires_at), "#{label}：终态必须清空 lease_expires_at"

        assert fresh.last_error == correction_contract_code(mode),
               "#{label}：必须写入 mode-specific 的精确 contract code"

        refute String.contains?(fresh.last_error, "\"")

        assert is_nil(row.quarantined_at), "#{label}：正向前提——入口行尚未被隔离"
        refute is_nil(fresh.quarantined_at), "#{label}：隔离必须落 quarantined_at"

        assert DateTime.compare(fresh.updated_at, row.updated_at) in [:gt, :eq],
               "#{label}：updated_at 只能前进"

        # 【R1】proof-mode 从 metadata_committed 进入：绝不允许被先推进到 finalize_pending。
        # （`metadata_committed_at` 不在授权集合里，已由上面的完整行不变量覆盖。）
        if entry_phase == "metadata_committed" do
          refute fresh.phase == "finalize_pending"
        end

        # 【R1】backup 必须原地保留（隔离保留取证物，绝不清理）。
        assert File.regular?(backup.manifest), "#{label}：隔离绝不允许删除 backup manifest"
        assert File.read!(backup.manifest) == backup.manifest_bytes, "#{label}：manifest 必须逐字保留"
        assert File.read!(backup.part) == backup.part_bytes, "#{label}：backup 字节必须逐字保留"

        # 被拒绝的 summary 绝不持久化；old evidence term / JSON 字节 / fingerprint 逐字不变。
        assert fresh.recovery_evidence === snapshot.wrapper
        assert Jason.encode!(fresh.recovery_evidence) == snapshot.wrapper_bytes
        assert fresh.published_fingerprint === snapshot.fingerprint

        refute String.contains?(Jason.encode!(fresh.recovery_evidence), @correction_token_prefix),
               "#{label}：被拒绝的超限 token 绝不能落库"

        refute String.contains?(inspect(result), @correction_token_prefix)
        refute String.contains?(log, @correction_token_prefix)
        refute String.contains?(fresh.last_error, @correction_token_prefix)

        # verify/finalize 次数符合实际 caller；PG 路径 restore 恒为 0。
        if mode == "finalize" do
          assert_pg_counts!(label, 1, 1)
        else
          assert_pg_counts!(label, 1, 0)
        end
      end
    end

    # 【R4】结构化 adapter 边界 oracle。不硬编码任何被选定的 adapter/helper 名字，只检查：
    #   1. 精确远程 MFA 锚点（模块语义身份 + 函数名 + arity），拒绝 `Fake.*` 与同名错 arity；
    #   2. 精确**本地** MFA 身份 `{name, arity}` —— 同名不同 arity 的重载对**每一个**探测器
    #      都不可见；preserving MFA 仅当其**所有**子句都直连公共 `/3` API 才合格；
    #   3. owner 的**每一个子句**都必须：自带以精确 merge_failure/3 为 scrutinee/generator
    #      的构造、结构化声明唯一续延参数、成功臂 tail-call `continuation.(merged)`、
    #      拒绝臂 tail-return 精确 preserving；
    #   4. 三个 pg_merged_* caller 的唯一 MFA 契约：每个子句都直接 tail-call 精确 owner MFA，
    #      并在续延位置传显式一元 fn；且不得绑定/分支 owner 结果或自行处理拒绝。
    #
    # 【证据顺序，R3-D / R4-D】所有发现、精确锚点与合成 GOOD/BAD 标定都是**先执行并通过**
    # 的真实断言；随后把真实 owner/caller/tag 缺陷**无早退地**全量收集，最后由唯一一条
    # 聚合断言如实列出。缺陷条数不硬编码。它**不**替代上面六格动态 oracle。
    @tag :task3_g3_final_review_correction
    test "g3 correction: one structural adapter owns merge_failure and every pg_merged path routes through it" do
      recovery = executable_ast!("lib/maxio/object_mutation/recovery.ex")
      aliases = correction_alias_prelude(recovery)
      index = correction_local_index(recovery)
      callers = ~w(pg_merged_pending_retry pg_merged_terminal pg_merged_quarantine)a

      # ── 阶段 1：精确远程 MFA 锚点标定（正 + 负）──
      #
      # 【R7 / A】alias 表现在是 `%{short => MapSet(full_parts)}`，且只取 defmodule 直接
      # body 中、首个 def/defp 之前的 prelude。

      assert Map.get(aliases, :PublishedProof) ==
               MapSet.new([[:Maxio, :Storage, :PublishedProof]]),
             "alias prelude 必须把 PublishedProof 归一为 singleton 完整模块 parts"

      assert Map.get(aliases, :ObjectMutation) == MapSet.new([[:Maxio, :ObjectMutation]]),
             "alias prelude 必须把 ObjectMutation 归一为 singleton 完整模块 parts"

      # 【R7 / A】alias 控制：单一 roster 驱动同一个循环，计数由该 roster 派生。
      alias_controls = [
        {:alias_conflict_fake_and_real, false, "同一 short alias 同时绑定 Fake 与真实模块 → 歧义，不得展开"},
        {:alias_after_prelude_decoy, false,
         "真实模块的 alias 在函数体内 / prelude 之后，只有首个 def/defp 之前的才算数"},
        {:alias_sequential_fake_root, false,
         "`alias Fake, as: Maxio` 之后的 `Maxio.Storage.PublishedProof` 语义上是 Fake 根"},
        {:alias_absolute_elixir_root, true,
         "`Elixir.Maxio.Storage.PublishedProof` 绝对根必须被剥离并命中真实模块"}
      ]

      for {sample, expect_hit, why} <- alias_controls do
        s = correction_synthetic(sample)

        hit? =
          correction_exact_remote_calls(s.ast, s.aliases, @correction_merge_failure_mfa) != []

        assert hit? == expect_hit,
               "alias 控制 #{sample}（#{why}）必须#{if expect_hit, do: "命中", else: "不命中"}" <>
                 "精确 merge_failure/3 锚点"
      end

      assert correction_exact_remote_calls(recovery, aliases, @correction_merge_failure_mfa) != [],
             "正对照：精确锚点必须在 Recovery 上真的检出 PublishedProof.merge_failure/3"

      assert correction_exact_remote_calls(recovery, aliases, @correction_preserving_mfa) != [],
             "正对照：精确锚点必须在 Recovery 上真的检出 " <>
               "ObjectMutation.quarantine_preserving_evidence/3"

      wrong_module = correction_synthetic(:owner_wrong_module)
      wrong_arity = correction_synthetic(:owner_wrong_arity)

      assert correction_exact_remote_calls(
               wrong_module.ast,
               wrong_module.aliases,
               @correction_merge_failure_mfa
             ) == [],
             "负对照：`Fake.merge_failure/3` 绝不允许被精确锚点接受"

      assert correction_exact_remote_calls(
               wrong_arity.ast,
               wrong_arity.aliases,
               @correction_merge_failure_mfa
             ) == [],
             "负对照：同模块同名但 arity 错误的调用绝不允许被精确锚点接受"

      # ── 阶段 2：preserving 精确本地 MFA 集合的正/负标定 ──

      # 【R7 / D】preserving 控制：单一 roster 驱动同一循环，期望值是**精确的合格 MFA 集合**。
      qualified = MapSet.new([{:synthetic_preserving, 3}])

      preserving_controls = [
        {:good_full_seam, qualified, "唯一 GOOD：真实 wrapper 形态（参数链 + 精确尾部）"},
        {:preserving_overload, qualified, "同名 `/1` 重载绝不允许因 `/3` 合格而被一起收进集合"},
        {:preserving_wrong_module, MapSet.new(), "错误模块的同名 quarantine_preserving_evidence"},
        {:preserving_clause_bypass, MapSet.new(), "同一 MFA 只要有一个子句不连公共 API，整体不合格"},
        {:preserving_trailing_forged, MapSet.new(),
         "R7-helper-trailing-forged：`public_call; :forged`"},
        {:preserving_forged_public_args, MapSet.new(),
         "R7-preserving-args-forged：public call 的 journal/code/opts 实参全被伪造"},
        {:preserving_forged_tail, MapSet.new(),
         "R7-preserving-forged-tail：成功臂尾部返回伪造 tag `{:forged, quarantined}`"},
        {:preserving_throw_prelude, MapSet.new(),
         "R7.1-gap2：成功臂 prelude 是 `throw(:forged)` 而非白名单的 `Log.error/2`"}
      ]

      for {sample, expected, why} <- preserving_controls do
        s = correction_synthetic(sample)

        assert correction_preserving_mfas(s.index, s.aliases) == expected,
               "preserving 控制 #{sample}（#{why}）的合格集合必须是 " <>
                 inspect(MapSet.to_list(expected))
      end

      # 【R7 amendment 4】mapper 控制：GOOD 必须返回精确属性；任意属性/等值字面量必须被拒。
      mapper_controls = [
        {:good_full_seam, true, "mapper 两子句分别返回精确 stable contract-violation 属性"},
        {:arbitrary_mapper_codes, false, "R7-arbitrary-mapper：任意属性 / 等值字符串字面量"},
        {:mapper_extra_catchall, false, "R7.1-gap3：多出 `_other` catchall 第三子句（totality）"}
      ]

      for {sample, expect_clean, why} <- mapper_controls do
        s = correction_synthetic(sample)

        assert correction_contract_code_deficits(s.index) == [] == expect_clean,
               "mapper 控制 #{sample}（#{why}）必须判定为 " <>
                 "#{if expect_clean, do: "合规", else: "违约"}"
      end

      # 【R7.1 / gap 5】callsite 宿主控制：精确 MFA 分组必须区分真实宿主与同名错 arity decoy。
      callsite_controls = [
        {:callsite_exact_hosts, true, "精确宿主 MFA 承载 3 个 :proof + 4 个 :finalize"},
        {:callsite_wrong_arity_decoy_host, false, "R7.1-gap5：真实宿主被清空，同名 wrong-arity decoy 承载正确数量"}
      ]

      for {sample, expect_clean, why} <- callsite_controls do
        s = correction_synthetic(sample)

        assert correction_callsite_deficits(s.index) == [] == expect_clean,
               "callsite 控制 #{sample}（#{why}）必须判定为 " <>
                 "#{if expect_clean, do: "合规", else: "违约"}，实际：" <>
                 inspect(correction_callsite_deficits(s.index))
      end

      # ── 阶段 3：owner 契约探测器的合成 GOOD/BAD 标定 ──

      # 【R6】canonical owner grammar 的正/负标定。唯一 GOOD owner seam 是 direct case；
      # 其余全部为 BAD，各自对应一种被 grammar **按构造**排除的形态。
      owner_controls = [
        {:good_full_seam, true, "唯一被承认形态：direct case + 两臂 + 单一直接调用"},
        # R6 架构裁决：`with` 不在 canonical grammar 内（R5 曾误列为 GOOD）。
        {:noncanonical_with_seam, false, "直连 `with` seam —— canonical grammar 只承认 direct case"},
        {:preserving_overload, false, "拒绝臂调用同名非 preserving /1 重载"},
        {:contains_then_alternate_tag, false, "拒绝臂 body 是 block 且最终返回替代 tag"},
        {:owner_no_continuation, false, "adapter 没有续延参数，成功行为被自己吸收"},
        {:owner_success_not_continuation, false, "成功臂 body 不是 `continuation.(merged)`"},
        # scrutinee 必须**就是**精确 remote MFA 调用，不接受序列块伪造。
        {:causal_case_sequence_forged, false,
         "case scrutinee 是序列块：调用 merge_failure 后丢弃并伪造 {:ok, :forged}"},
        {:causal_with_sequence_forged, false, "同样的序列块伪造，且外层是不被承认的 `with`"},
        {:causal_decoy_inner_then_forged_tail, false,
         "body 是 block：合规 merge case 诱饵 + 伪造尾项（body 本身不是 direct case）"},
        # 成功臂 body 必须是单一直接调用，故重绑定/遮蔽形态被按构造排除。
        {:continuation_rebound_assign, false, "成功臂 body 是 block：重绑续延后再调用"},
        {:success_arm_prelude_then_call, false,
         "成功臂 body 是 block：nested-fn/shadow prelude 后才是 `continuation.(merged)`"},
        {:merged_rebound_assign, false, "成功臂 body 是 block：重绑 merged 后再交给续延"},
        {:owner_no_success_arm, false, "两臂中没有 `{:ok, merged}` 成功臂（拒绝 + catch-all）"},
        # 【R6 / 静态终审最小反例】
        {:with_second_generator_rebind, false,
         "static I1：`with` 合规 generator 后再用第二 generator 把 merged 重绑为伪造值"},
        {:owner_early_throw_then_canonical, false,
         "static I2：owner body 是 `throw(:early); canonical_case`（canonical case 本身合规）"},
        {:guarded_success_catchall, false, "static I3：成功臂带 guard + 第二臂是 catch-all preserving"},
        {:leading_catchall_shadows_success, false, "static I3：前置 catch-all 臂遮蔽成功臂（顺序违例 + 三臂）"},
        # 【R7】reviewer 六项根因对应的可读标签
        {:identity_collision_ok_binder, false,
         "R7-identity-collision：成功 binder 与续延 head 同 identity（模式遮蔽）"},
        {:ok_binder_special_form, false, "R7-special-variable：成功 binder 是 `__MODULE__`"},
        {:head_special_form_continuation, false,
         "R7-special-variable：owner head 续延位是 special form 而非严格普通变量"},
        {:narrow_error_literal, false,
         "R7-narrow-error：`{:error, :only_this_reason}` 只覆盖单一 reason"},
        {:owner_scrutinee_forged_args, false,
         "R7-argument-chain：merge_failure/3 实参被伪造（target/evidence/summary）"},
        {:owner_preserving_forged_args, false,
         "R7-preserving-args-forged：拒绝臂 preserving 实参被伪造（journal/code/opts）"},
        {:owner_error_raw_public_api, false, "R7：拒绝臂直接调用 raw public API，未经本地 preserving helper"},
        # 【R7.1】lexical/contract final review 的 unique findings
        {:merge_arg_parens_call, false,
         "R7.1-gap1：merge arg1 是带括号的 `journal.recovery_evidence()` 零元调用"},
        {:ok_binder_shadows_head_journal, false,
         "R7.1-gap6：ok binder 复用 head `journal`，遮蔽 head 使来源有歧义"}
      ]

      for {sample, expect_clean, why} <- owner_controls do
        s = correction_synthetic(sample)
        s_preserving = correction_preserving_mfas(s.index, s.aliases)

        s_owner =
          s.index
          |> Map.keys()
          |> Enum.filter(fn mfa ->
            Enum.any?(s.index[mfa], fn clause ->
              correction_exact_remote_calls(clause.body, s.aliases, @correction_merge_failure_mfa) !=
                []
            end)
          end)

        assert length(s_owner) == 1, "合成样本 #{sample}：必须恰好有一个 owner MFA"
        [s_owner_mfa] = s_owner

        {s_deficits, _cont} =
          correction_owner_deficits(s.index[s_owner_mfa], s_owner_mfa, s.aliases, s_preserving)

        assert s_deficits == [] == expect_clean,
               "owner 契约探测器在合成样本 #{sample}（#{why}）上必须判定为 " <>
                 "#{if expect_clean, do: "合规", else: "违约"}，实际缺陷：" <> inspect(s_deficits)
      end

      # ── 阶段 4：caller 契约探测器的合成 GOOD/BAD 标定 ──

      # 【R7 / E】合成 owner 固定为 arity 6、续延 position 5。
      good_owner_mfa = {:synthetic_adapter, @correction_owner_arity}
      good_cont_pos = @correction_owner_continuation_pos

      # caller 契约：子句 body **本身**必须是对精确 owner MFA 的直接本地调用，
      # 且续延位置传显式一元 fn。block 尾项一律不再被承认。
      caller_controls = [
        {:good_full_seam, true, "body 本身就是 owner 直接调用并传显式一元 fn"},
        {:owner_overload_caller, false, "调用同名不同 arity 的 owner 重载"},
        {:caller_non_fn_continuation, false, "续延位置传的不是 fn"},
        {:caller_wrong_fn_arity, false, "续延位置传的 fn arity 错误"},
        {:caller_binds_and_branches, false, "先绑定 owner 结果再 case 解释替代 tag"},
        {:caller_with_generator, false, "`with` generator 解构 owner 结果"},
        {:caller_early_throw_then_owner, false,
         "static I2：body 是 `throw(:early); owner(...fn...)`（owner 调用本身合规）"},
        {:caller_forged_owner_args, false,
         "R7-caller-args：直接调用 owner 但 journal/target/summary/mode 实参被伪造或错位"},
        # 【R7.1 / gap 4】caller totality + 续延 fn 严格化
        {:caller_guarded_clause, false, "R7.1-gap4：caller 唯一 clause 带 guard"},
        {:caller_fn_literal_binder, false, "R7.1-gap4：续延 fn binder 是字面量"},
        {:caller_fn_guarded, false, "R7.1-gap4：续延 fn 带 guard"},
        {:caller_fn_multi_clause, false, "R7.1-gap4：续延 fn 有多个子句"},
        {:caller_fn_binder_shadows_head, false,
         "R7.1-gap4：续延 fn binder 与 caller head 同 identity（不 fresh）"}
      ]

      for {sample, expect_clean, why} <- caller_controls do
        s = correction_synthetic(sample)
        s_preserving = correction_preserving_mfas(s.index, s.aliases)

        # 合成 caller 也用固定 spec 校验前五实参链，否则「实参被伪造」这类样本无法被判违约。
        s_deficits =
          correction_caller_deficits(
            s.index,
            :synthetic_caller,
            good_owner_mfa,
            good_cont_pos,
            s_preserving,
            %{
              arity: 5,
              params: ~w(journal summary code mode opts)a,
              target: "finalized",
              mode_pos: 3
            }
          )

        assert s_deficits == [] == expect_clean,
               "caller 契约探测器在合成样本 #{sample}（#{why}）上必须判定为 " <>
                 "#{if expect_clean, do: "合规", else: "违约"}，实际缺陷：" <> inspect(s_deficits)
      end

      # ── 阶段 5：真实 Recovery 上的发现与 owner 唯一性 ──

      assert map_size(index) > 10,
             "对照组：精确本地 MFA 索引必须真的拆出 Recovery 的 def/defp 集合"

      for caller <- callers do
        assert Enum.any?(Map.keys(index), fn {name, _a} -> name == caller end),
               "对照组：#{caller} 必须真的存在于被拆解的本地 MFA 集合里"
      end

      owner_mfas =
        index
        |> Map.keys()
        |> Enum.filter(fn mfa ->
          Enum.any?(index[mfa], fn clause ->
            correction_exact_remote_calls(clause.body, aliases, @correction_merge_failure_mfa) !=
              []
          end)
        end)

      assert length(owner_mfas) == 1,
             "`PublishedProof.merge_failure/3` 必须恰好被一个本地 MFA 拥有，实际：" <>
               inspect(owner_mfas)

      [owner_mfa] = owner_mfas
      refute elem(owner_mfa, 0) in callers, "owner 必须是三个 caller 之外的独立 adapter seam"

      preserving = correction_preserving_mfas(index, aliases)

      # 【R7】真实代码里是否存在合格 preserving helper 现在是**真实缺陷项**而非控制断言：
      # R7 的 helper 语法比 R6 严格得多（精确尾部 + 参数链），冻结生产可能不满足，这属于
      # 待 Phase B 落地的能力缺口，不是 fixture 错误。探测器本身的正/负标定已在阶段 2 完成。
      preserving_presence_deficits =
        if MapSet.size(preserving) > 0,
          do: [],
          else: ["Recovery 内没有符合 R7 窄语法的 evidence-preserving quarantine helper"]

      # 【R7 amendment 5】callsite 按宿主分组精确锁定（不是全局"两种字面量都出现过"）。
      mode_literal_deficits = correction_callsite_deficits(index)

      # ── 阶段 6：真实结构缺陷的**全量收集**，随后一次聚合断言 ──
      #
      # 冻结生产的 `pg_merge/3` 没有续延参数，因此续延相关校验必须**安全求值、不提前抛出**，
      # 才能把 owner 与三个 caller 的全部缺陷一次说清。缺陷条数不硬编码。

      {owner_deficits, cont_pos} =
        correction_owner_deficits(index[owner_mfa], owner_mfa, aliases, preserving)

      caller_deficits =
        Enum.flat_map(callers, fn caller ->
          correction_caller_deficits(index, caller, owner_mfa, cont_pos, preserving)
        end)

      escaping_deficits =
        case correction_merge_rejected_nodes(recovery) do
          [] -> []
          hits -> ["存在可逃逸的 {:merge_rejected, _} 拒绝 tag：#{inspect(hits)}"]
        end

      deficits =
        preserving_presence_deficits ++
          correction_single_unguarded_clause_deficits(
            index[owner_mfa],
            correction_mfa(owner_mfa)
          ) ++
          correction_contract_code_deficits(index) ++
          owner_deficits ++ caller_deficits ++ mode_literal_deficits ++ escaping_deficits

      # roster 全部由**上面各循环实际迭代的同一个列表**派生，没有并行 magic number。
      roster =
        "roster（executable controls）：alias=#{length(alias_controls)}、" <>
          "preserving=#{length(preserving_controls)}、mapper=#{length(mapper_controls)}、" <>
          "callsite=#{length(callsite_controls)}、owner=#{length(owner_controls)}、" <>
          "caller=#{length(caller_controls)}"

      assert deficits == [],
             "adapter 边界仍有 #{length(deficits)} 项结构缺陷（全部为冻结生产的真实 " <>
               "capability 缺口，非 fixture 错误）。#{roster}：\n  - " <>
               Enum.join(deficits, "\n  - ")
    end
  end

  # ── Task 3 G3 Phase B 终审纠偏（tests-only RED）：两条独立静态 REJECT 的可执行锁定 ──
  #
  # 三格互相独立、无 runtime loop：两格是冻结生产上的 genuine capability RED，第三格是
  # 必须在生产改动**之前**就通过的边界正控（1,024 位），用来证明 1,025 位的失败来自精确的
  # integer-token 边界，而不是坏 fixture 或 aggregate 体积。

  describe "G3 Phase B review correction RED: operational + sidecar fail-closed boundaries" do
    setup :g3_script_backend

    # 【I1 / recovery.ex:940-947】受保护证据的 restore 失败 → `operational_error/3` →
    # `ObjectMutation.mark_operational_error/3` 的 CAS 输掉时，冻结生产返回
    # `{:ok, :retried, _}`：一次**根本没有落库**的收敛写被当成成功对外汇报。§3.2 要求
    # 每一个 journal CAS 失败都只折叠成同一个稳定 convergence code。
    @tag :task3_g3_phase_b_review_correction
    test "g3 phase b correction: an operational_error cas loss reports the stable convergence failure",
         ctx do
      key = "g3cb-operational-cas-loss.bin"
      start_supervised!(ScriptRepo)

      # 真实可达的受保护证据行：canonical wrapper + fingerprint，停在 rollback_pending
      # （restore_flow 的真实入口相位，因此**不需要**任何前置 phase 写）。
      journal = pg_rollback_pending_journal(ctx, key)
      snapshot = g3_snapshot(journal)
      refute is_nil(snapshot.wrapper), "正向前提：本格必须走受保护证据分支"
      assert journal.phase == "rollback_pending"

      backup = correction_seed_backup!(ctx, journal)

      # 确定性 attempts sentinel：CAS loser 的原始 reason 必然携带它。
      seeded = correction_set_attempts!(journal, @correction_attempts_sentinel)
      assert seeded.attempts == @correction_attempts_sentinel

      # 正向非空洞前提：同一条公共 API 对 stale 身份**确实**产出携带 phase + attempts 的
      # 原始 reason（这次 CAS 必然落空，因此零写入、不污染 fixture）。
      assert ObjectMutation.mark_operational_error(journal, @correction_convergence_failed) ==
               {:error, {:stale_journal, "rollback_pending", @correction_attempts_sentinel}},
             "非空洞前提：收敛写失败的原始 reason 本会携带 phase 与 attempts"

      row = correction_row_snapshot(seeded)
      sentinel_text = Integer.to_string(@correction_attempts_sentinel)

      # 真实可达的 restore 失败（非隔离类 reason）：受保护证据分支因此走运维 CAS。
      Script.script(
        :restore_if_current,
        {:return, {:error, {:unavailable, @g3_restore_sentinel}}}
      )

      # 让**恰好那一次** `mark_operational_error` 的 CAS 正常未命中（既有支持的
      # normal-failure action，不是生产 failpoint）。
      ScriptRepo.script(:journal_write, {:return, {0, nil}})
      assert ScriptRepo.remaining(:journal_write) == 1, "故障 action 必须真的登记"

      {outcome, log} =
        with_log(@g3_capture_opts, fn ->
          phase_b_recover_outcome(seeded,
            repo: ScriptRepo,
            lease_owner: @correction_self_owner,
            storage_opts: [data_dir: ctx.dir]
          )
        end)

      label = "phase_b/operational_cas_loss"

      # ── capability 断言（**必须是本格第一条 outcome 断言**）：失败的收敛写绝不允许被
      # 报告成成功。R8.1 复审要求：任何 instrumentation（计数 / 调用序 / 泄漏 refute /
      # 行不变量）都不得先于本条被选作 RED，否则 RED 可能锁在辅助断言而非能力边界上。
      assert outcome == {:error, @correction_convergence_failed},
             "#{label}：`mark_operational_error/3` 的 CAS 输掉必须折叠成同一个稳定 " <>
               "convergence code，绝不允许把没有落库的写报告成 retried 成功：" <>
               inspect(outcome)

      # ── 正向取证：故障精确命中 claim + renew **之后**的 journal_write ──
      counts = ScriptRepo.counts()
      assert counts.claim == 1, "#{label}：claim 必须恰好一次且 delegate 成功"
      assert counts.renew == 1, "#{label}：renew 必须恰好一次且 delegate 成功"
      assert counts.journal_write == 1, "#{label}：收敛写恰好一次（即被注入故障的那一次）"
      assert counts.release == 1, "#{label}：本 worker 必须只释放自己的租约"

      assert ScriptRepo.remaining_all() == %{
               claim: 0,
               renew: 0,
               release: 0,
               journal_write: 0
             },
             "#{label}：故障 action 必须被精确消费"

      calls = ScriptRepo.calls()
      claim_call = Enum.find(calls, &(&1.operation == :claim))
      renew_call = Enum.find(calls, &(&1.operation == :renew))
      write_call = Enum.find(calls, &(&1.operation == :journal_write))
      release_call = Enum.find(calls, &(&1.operation == :release))

      assert claim_call.index < renew_call.index,
             "#{label}：故障绝不允许命中 claim"

      assert renew_call.index < write_call.index,
             "#{label}：故障必须落在 claim+renew 之后的 journal_write 上，而不是 renew"

      assert write_call.index < release_call.index,
             "#{label}：故障必须落在 release 之前的收敛写上，而不是 release"

      # storage 侧：restore 恰好一次，proof/finalize/current_epoch 恒零。
      assert Script.call_count(:restore_if_current) == 1,
             "#{label}：restore_if_current 必须恰好一次"

      assert Script.remaining(:restore_if_current) == 0, "#{label}：脚本条目必须被精确消费"
      assert Script.call_count(:verify_published) == 0, "#{label}：restore 路径绝不 verify"
      assert Script.call_count(:finalize_if_current) == 0, "#{label}：restore 路径绝不 finalize"
      assert Script.call_count(:current_epoch) == 0, "#{label}：restore 路径 current_epoch 恒零"

      assert log =~ "reason=#{@correction_convergence_failed}",
             "#{label}：结构化日志 reason 必须是精确稳定 convergence code：" <> log

      # raw repo/stale/phase/attempts/owner 一律不得出现在 result 与 log 上。
      for surface <- [inspect(outcome), log] do
        refute String.contains?(surface, @g3_restore_sentinel),
               "#{label}：restore 的 raw sentinel 绝不允许外泄"

        refute String.contains?(surface, "stale_journal"),
               "#{label}：raw stale tuple 绝不允许外泄"

        refute String.contains?(surface, sentinel_text),
               "#{label}：attempts 绝不允许作为诊断外泄"

        refute String.contains?(surface, @correction_self_owner),
               "#{label}：lease owner 绝不允许作为诊断外泄"
      end

      refute String.contains?(inspect(outcome), "rollback_pending"),
             "#{label}：outward reason 绝不允许携带 phase"

      # ── 行不变量：收敛写没有落库，因此只有租约与 updated_at 可以变 ──
      fresh = ObjectMutation.get(journal.id)

      assert_only_authorized_fields_changed!(
        fresh,
        row,
        [:lease_owner, :lease_expires_at, :updated_at],
        label
      )

      assert fresh.attempts == @correction_attempts_sentinel,
             "#{label}：失败的收敛写绝不允许涨 attempts"

      assert is_nil(fresh.lease_owner), "#{label}：本 worker 必须释放自己的租约"
      assert is_nil(fresh.lease_expires_at)

      refute String.contains?(inspect(fresh), @g3_restore_sentinel),
             "#{label}：整行绝不允许携带 restore sentinel"

      # 受保护 term / JSON 字节 / fingerprint / backup 逐字不变。
      assert fresh.recovery_evidence === snapshot.wrapper
      assert Jason.encode!(fresh.recovery_evidence) == snapshot.wrapper_bytes
      assert fresh.published_fingerprint === snapshot.fingerprint
      assert File.read!(backup.manifest) == backup.manifest_bytes
      assert File.read!(backup.part) == backup.part_bytes
    end

    # 【I2】facade-valid 的 1,025 位 `required` 通过公共 callback 校验与 StorageDisposition，
    # 却让投影出的 journal 证据踩到 DurableJSON 的 1,024-byte integer-token 上限。
    #
    # 冻结生产 `lib/maxio/object_mutation/recovery.ex`（SHA AFBC7176…）上的**精确**调用链：
    #
    #   apply_sidecar_finalize_disposition({:retryable_failure, :unavailable, summary}, …)
    #                                                                       [729-744]
    #     -> sidecar_write(pending, "finalize_pending", "failed", "unavailable", …)  [734-743]
    #     -> sidecar_write/8 头部 [775-781]：sidecar_finalize_evidence/3 投影 [776]
    #     -> validate_sidecar_write(pending, :finalize, target_phase, evidence, code) [778]
    #     -> validate_sidecar_write/5 主子句 [812-828]
    #     -> `true <- Journal.json_evidence_valid?(ev)` 在 [823] 求值为 false
    #     -> else 臂 [826] 返回 raw `{:error, {:sidecar_evidence_contract, :finalize}}`
    #     -> locked_apply/2 的 `{:ok, {:error, code}}` 臂 [208-211] 把该 tuple 原样
    #        转发给 log_no_action(journal, code) [210]
    #     -> `defp log_no_action(journal, code) when is_binary(code)` [1065] 守卫不匹配
    #     -> FunctionClauseError，而不是稳定结果。
    #
    # 说明（R8.1 更正）：[769] 是 `{:contract_violation, :finalize}` 这一**另一条**分支的
    # validate 调用点；[830-831] 是 non-sidecar journal 的 form-specific 兜底子句。两者都
    # **不在**本格所走的 retryable-unavailable finalize 路径上，不得被引用为本格的根因。
    #
    # 这一格锁定的是 validator 已写明的 fail-closed、零动作写边界：内部 pre-write
    # durability 拒绝**不**要求隔离，也**不**要求任何替代写。
    @tag :task3_g3_phase_b_review_correction
    test "g3 phase b correction: a 1025-digit sidecar finalize projection fails closed with the stable contract code",
         ctx do
      key = "g3cb-sidecar-1025.bin"
      start_supervised!(ScriptRepo)

      # 真实的 sidecar finalize_pending 行（共享 finalize adapter 的合法入口）。
      journal = sidecar_ready_journal(ctx, key, "finalize_pending")
      assert journal.authority_mode == "sidecar"
      assert journal.phase == "finalize_pending"

      backup = correction_seed_backup!(ctx, journal)
      row = correction_row_snapshot(journal)
      fingerprint = journal.published_fingerprint

      # 两批断言共用同一个数值边界（`<<57>>` 即十进制数字 "9"）。
      assert @phase_b_required_1025 === @correction_required_1025

      # ── 正控 1：公共 canonical 配方 + 完整 observation list，1,025 位 required ──
      rejected = phase_b_finalize_callback(@phase_b_required_1025)

      assert PublishedProof.validate_callback_result(:finalize, rejected) == :ok,
             "1,025 位 required 必须通过公共 callback facade 校验"

      summary = correction_summary_of(rejected)
      assert summary["required"] === @phase_b_required_1025
      assert summary["scope"] == "aggregate" and summary["mode"] == "finalize"

      # ── 正控 2：StorageDisposition 精确 disposition + summary 严格同一 ──
      assert StorageDisposition.finalize(rejected) === {:retryable_failure, :unavailable, summary}

      # ── 正控 3：raw 长 token 真的被注入 ──
      assert String.contains?(Jason.encode!(summary), @correction_token_prefix),
             "被注入的 canonical summary 必须真的携带超限 integer token"

      # ── 正控 4：投影出的证据恰恰**只**因为 integer token 被 durable 校验拒绝 ──
      projected = g3_sidecar_finalize_evidence("failed", "unavailable", summary)

      refute Journal.json_evidence_valid?(projected),
             "1,025 位投影必须被 journal 的 durable 校验精确拒绝"

      assert byte_size(Jason.encode!(projected)) < 65_536,
             "拒绝根因绝不是 aggregate 体积超限（远低于 65,536 字节闸门）"

      assert Journal.json_evidence_valid?(Map.put(projected, "required", @phase_b_required_1024)),
             "同一投影只把 required 换成 1,024 位即通过：根因是精确的 integer-token 边界"

      Script.script(:finalize_if_current, {:return, rejected})

      {outcome, log} =
        with_log(@g3_capture_opts, fn ->
          phase_b_recover_outcome(journal,
            repo: ScriptRepo,
            lease_owner: @correction_self_owner,
            storage_opts: [data_dir: ctx.dir]
          )
        end)

      label = "phase_b/sidecar_1025"

      # ── capability 断言（**必须是本格第一条 outcome 断言**）：稳定 mode-specific
      # contract code，而不是 FunctionClause。R8.1 复审要求：任何 instrumentation
      # （storage/ScriptRepo 计数、泄漏 refute、行不变量）都不得先于本条被选作 RED。
      assert outcome == {:error, @phase_b_sidecar_contract_violation},
             "#{label}：sidecar finalize 的 durable 拒绝必须给出稳定 contract code，" <>
               "绝不允许 FunctionClauseError / exit / raw " <>
               "`{:sidecar_evidence_contract, :finalize}` tuple：" <> inspect(outcome)

      # ── 正向取证：finalize 恰好一次，其余 storage 操作恒零 ──
      assert_sidecar_counts!(label, 0, 1)
      assert Script.remaining(:finalize_if_current) == 0, "#{label}：脚本条目必须被精确消费"

      # ── 零动作写：内部 pre-write 拒绝绝不落任何 sidecar 证据/动作写 ──
      counts = ScriptRepo.counts()
      assert counts.claim == 1, "#{label}：claim 必须恰好一次"
      assert counts.renew == 1, "#{label}：renew 必须恰好一次"

      assert counts.journal_write == 0,
             "#{label}：durable 拒绝必须 fail closed，绝不允许任何 sidecar 证据/动作写"

      assert counts.release == 1, "#{label}：本 worker 必须只释放自己的租约"

      assert log =~ "reason=#{@phase_b_sidecar_contract_violation}",
             "#{label}：结构化日志 reason 必须是同一个稳定 binary：" <> log

      fresh = ObjectMutation.get(journal.id)

      # 超限 token 与 raw 契约 tuple 绝不出现在 result / log / last_error / evidence 上。
      for surface <- [inspect(outcome), log, inspect(fresh)] do
        refute String.contains?(surface, @correction_token_prefix),
               "#{label}：被拒绝的超限 token 绝不允许外泄"

        refute String.contains?(surface, "sidecar_evidence_contract"),
               "#{label}：raw 内部契约 tuple 绝不允许外泄"
      end

      # ── 行不变量：除本 worker 租约外逐字不变 ──
      assert_only_authorized_fields_changed!(
        fresh,
        row,
        [:lease_owner, :lease_expires_at, :updated_at],
        label
      )

      assert fresh.phase == "finalize_pending", "#{label}：fail-closed 绝不推进 phase"
      assert is_nil(fresh.recovery_evidence), "#{label}：绝不写入被拒绝的投影"
      assert is_nil(fresh.last_error)
      assert is_nil(fresh.lease_owner), "#{label}：本 worker 必须释放自己的租约"
      assert fresh.published_fingerprint === fingerprint
      assert File.read!(backup.manifest) == backup.manifest_bytes
      assert File.read!(backup.part) == backup.part_bytes
    end

    # 边界正控（必须在生产改动**之前**就 GREEN）：同构的 1,024 位 required 完整走通同一条
    # facade / disposition / 投影 / 写入路径。它证明上一格的 RED 恰恰来自 1,024→1,025 的
    # integer-token 边界，而不是非法 fixture、错误 disposition 或 aggregate 体积。
    @tag :task3_g3_phase_b_review_correction
    test "g3 phase b correction: the isomorphic 1024-digit sidecar finalize projection remains writable",
         ctx do
      key = "g3cb-sidecar-1024.bin"
      start_supervised!(ScriptRepo)

      journal = sidecar_ready_journal(ctx, key, "finalize_pending")
      assert journal.authority_mode == "sidecar"
      assert journal.phase == "finalize_pending"

      backup = correction_seed_backup!(ctx, journal)
      row = correction_row_snapshot(journal)
      fingerprint = journal.published_fingerprint

      assert @phase_b_required_1024 === @correction_required_1024

      # 与上一格逐字同构，只有 required 的位数不同。
      accepted = phase_b_finalize_callback(@phase_b_required_1024)

      assert PublishedProof.validate_callback_result(:finalize, accepted) == :ok,
             "1,024 位 required 同样必须通过公共 callback facade 校验"

      summary = correction_summary_of(accepted)
      assert summary["required"] === @phase_b_required_1024
      assert summary["scope"] == "aggregate" and summary["mode"] == "finalize"

      assert StorageDisposition.finalize(accepted) === {:retryable_failure, :unavailable, summary}

      expected_evidence = g3_sidecar_finalize_evidence("failed", "unavailable", summary)

      assert Journal.json_evidence_valid?(expected_evidence),
             "1,024 位投影必须通过 journal 的 durable 校验（边界正控）"

      Script.script(:finalize_if_current, {:return, accepted})

      {outcome, log} =
        with_log(@g3_capture_opts, fn ->
          phase_b_recover_outcome(journal,
            repo: ScriptRepo,
            lease_owner: @correction_self_owner,
            storage_opts: [data_dir: ctx.dir]
          )
        end)

      label = "phase_b/sidecar_1024"

      assert {:ok, %Journal{}} = outcome,
             "#{label}：同构 1,024 位必须完整收敛成功（否则上一格的 RED 是坏 fixture）：" <>
               inspect(outcome)

      assert_sidecar_counts!(label, 0, 1)
      assert Script.remaining(:finalize_if_current) == 0, "#{label}：脚本条目必须被精确消费"

      counts = ScriptRepo.counts()
      assert counts.claim == 1, "#{label}：claim 必须恰好一次"
      assert counts.renew == 1, "#{label}：renew 必须恰好一次"
      assert counts.journal_write == 1, "#{label}：有界投影必须恰好一次写入"
      assert counts.release == 1, "#{label}：mark_error 之后必须主动释放租约"

      fresh = ObjectMutation.get(journal.id)

      assert fresh.phase == "finalize_pending", "#{label}：retryable 失败保持 pending"
      assert fresh.last_error == "sidecar_finalize:unavailable"
      refute String.contains?(fresh.last_error, "\"")

      assert fresh.recovery_evidence === expected_evidence,
             "#{label}：证据必须严格等于精确的有界投影"

      assert fresh.recovery_evidence["outcome"] == "failed"
      assert fresh.recovery_evidence["class"] == "unavailable"
      assert fresh.recovery_evidence["required"] === @phase_b_required_1024
      assert Journal.json_evidence_valid?(fresh.recovery_evidence)

      assert_only_authorized_fields_changed!(
        fresh,
        row,
        [
          :lease_owner,
          :lease_expires_at,
          :attempts,
          :next_attempt_at,
          :last_error,
          :recovery_evidence,
          :updated_at
        ],
        label
      )

      assert fresh.attempts == row.attempts + 1, "#{label}：可重试写必须涨一次 attempts"
      assert is_nil(fresh.lease_owner), "#{label}：mark_error 之后租约必须被释放"
      assert fresh.published_fingerprint === fingerprint

      refute log =~ "reason=#{@phase_b_sidecar_contract_violation}",
             "#{label}：边界正控绝不允许出现 contract-violation 日志：" <> log

      refute String.contains?(log, "sidecar_evidence_contract")

      assert File.read!(backup.manifest) == backup.manifest_bytes
      assert File.read!(backup.part) == backup.part_bytes
    end
  end

  # ── G3 Batch A fixtures（§3 AST-aware 依赖边界）──

  # 解析源码并剥掉 `@moduledoc` / `@doc` 子树：文档里提到 Control 不是依赖。
  defp executable_ast!(path) do
    path
    |> File.read!()
    |> Code.string_to_quoted!()
    |> Macro.prewalk(fn
      {:@, _meta, [{doc, _doc_meta, _args}]} when doc in [:moduledoc, :doc, :typedoc] ->
        :__doc_stripped__

      node ->
        node
    end)
  end

  # `ObjectCommit.Control` 的真实依赖：alias/import/require 指令、远程调用与裸模块引用。
  # 字符串字面量不算（AST 里它们是 binary，不是 `__aliases__` 节点）。
  defp control_dependencies(ast) do
    collect_nodes(ast, fn
      {directive, _meta, args} when directive in [:alias, :import, :require] ->
        Enum.any?(List.wrap(args), &references_control?/1)

      {{:., _dot_meta, [target, _fun]}, _meta, _args} ->
        references_control?(target)

      {:__aliases__, _meta, _parts} = node ->
        references_control?(node)

      _node ->
        false
    end)
  end

  defp references_control?({:__aliases__, _meta, parts}) when is_list(parts) do
    tail = Enum.take(parts, -2)
    tail == [:ObjectCommit, :Control] or Enum.take(parts, -1) == [:ObjectCommit]
  end

  defp references_control?({directive, _meta, args})
       when directive in [:alias, :import, :require],
       do: Enum.any?(List.wrap(args), &references_control?/1)

  defp references_control?(list) when is_list(list), do: Enum.any?(list, &references_control?/1)

  defp references_control?({left, right}),
    do: references_control?(left) or references_control?(right)

  defp references_control?(_node), do: false

  # 可执行的 `:accelerate`：构造或模式匹配都算；文档/注释/字符串都不是 AST atom。
  defp accelerator_nodes(ast), do: collect_nodes(ast, &(&1 == :accelerate))

  defp mark_committed_calls(ast) do
    collect_nodes(ast, fn
      {{:., _dot_meta, [_target, :mark_committed]}, _meta, _args} -> true
      {:mark_committed, _meta, args} when is_list(args) -> true
      _node -> false
    end)
  end

  defp collect_nodes(ast, matcher) do
    {_ast, hits} =
      Macro.prewalk(ast, [], fn node, acc ->
        {node, if(matcher.(node), do: [Macro.to_string(node) | acc], else: acc)}
      end)

    Enum.reverse(hits)
  end

  # ── Task 3 G3 终审纠偏 fixtures（handoff §5.3 / §5.4）──

  # 确定性地把 attempts 设为精确 sentinel（不是 inc）：CAS loser 的原始 reason 因此必然
  # 携带一个可被逐字 refute 的可识别数字。
  defp correction_set_attempts!(journal, attempts) do
    {1, _} =
      Repo.update_all(from(j in Journal, where: j.id == ^journal.id), set: [attempts: attempts])

    ObjectMutation.get(journal.id)
  end

  # §5.3 第 2-5 格的 renew action 与其 raw sentinel（normal_error 格刻意没有 sentinel）。
  defp correction_renew_action("normal_error"), do: {:return, {0, nil}}
  defp correction_renew_action("raise"), do: {:raise, @correction_renew_raise_sentinel}
  defp correction_renew_action("exit"), do: {:exit, @correction_renew_exit_sentinel}
  defp correction_renew_action("throw"), do: {:throw, @correction_renew_throw_sentinel}

  defp correction_renew_sentinel("normal_error"), do: nil
  defp correction_renew_sentinel("raise"), do: @correction_renew_raise_sentinel
  defp correction_renew_sentinel("exit"), do: @correction_renew_exit_sentinel
  defp correction_renew_sentinel("throw"), do: @correction_renew_throw_sentinel

  # §5.4：六格 callback 全部只用**公共** aggregate 构造器，第二参是完整 observation list。
  defp correction_callback("proof", "unavailable", required),
    do:
      PublishedProof.classify(required, [
        {"local", PublishedProof.failed(:unavailable, "local", %{owned: true})}
      ])

  defp correction_callback("proof", "superseded", required),
    do: PublishedProof.classify(required, [{"local", PublishedProof.superseded("local")}])

  defp correction_callback("proof", "corrupt", required),
    do:
      PublishedProof.classify(required, [
        {"local", PublishedProof.failed(:corrupt, "local", %{owned: true})}
      ])

  defp correction_callback("finalize", "unavailable", required),
    do:
      PublishedProof.classify_finalize(required, [
        {"local", PublishedProof.endpoint_finalize_failed(:unavailable, "local", %{owned: true})}
      ])

  defp correction_callback("finalize", "superseded", required),
    do:
      PublishedProof.classify_finalize(required, [
        {"local", PublishedProof.endpoint_finalize_superseded("local")}
      ])

  defp correction_callback("finalize", "corrupt", required),
    do:
      PublishedProof.classify_finalize(required, [
        {"local", PublishedProof.endpoint_finalize_failed(:corrupt, "local", %{owned: true})}
      ])

  defp correction_summary_of({:ok, {_status, summary}}) when is_map(summary), do: summary

  defp correction_summary_of({:error, {:published_proof_failed, _class, summary}})
       when is_map(summary),
       do: summary

  defp correction_disposition("proof", result), do: StorageDisposition.proof(result)
  defp correction_disposition("finalize", result), do: StorageDisposition.finalize(result)

  defp correction_expected_disposition("unavailable", summary),
    do: {:retryable_failure, :unavailable, summary}

  defp correction_expected_disposition("superseded", summary), do: {:superseded, summary}

  defp correction_expected_disposition("corrupt", summary),
    do: {:integrity_failure, :corrupt, summary}

  defp correction_contract_code("proof"), do: @correction_proof_contract_violation
  defp correction_contract_code("finalize"), do: @correction_finalize_contract_violation

  # 【R2】**完整**持久化行投影：字段集合直接来自 `Journal.__schema__(:fields)`，因此
  # 未来任何新增列都自动进入不变量，绝不会因为手挑清单而漏掉。只有非持久化的 struct
  # 元数据（`__meta__` 等）被**按构造**排除——它根本不在 `:fields` 里。
  defp correction_row_snapshot(%Journal{} = journal) do
    Map.new(Journal.__schema__(:fields), fn field -> {field, Map.fetch!(journal, field)} end)
  end

  # 零写入路径：完整持久化行（含 `updated_at`）逐字不变。
  defp assert_correction_row_unchanged!(%Journal{} = fresh, row, label) do
    fresh_row = correction_row_snapshot(fresh)

    assert fresh_row === row,
           "#{label}：该路径的允许写为零，完整持久化行必须逐字不变（差异字段：" <>
             inspect(correction_row_diff(fresh_row, row)) <> "）"
  end

  # 只允许契约授权的字段发生变化；其余**全部**持久化字段必须 `===`。
  defp assert_only_authorized_fields_changed!(%Journal{} = fresh, row, authorized, label) do
    fresh_row = correction_row_snapshot(fresh)
    changed = correction_row_diff(fresh_row, row)

    # 正向：授权集合必须真的是持久化字段的子集（防止拼写错误让掩码空转）。
    schema_fields = MapSet.new(Journal.__schema__(:fields))

    assert MapSet.subset?(MapSet.new(authorized), schema_fields),
           "#{label}：授权字段集合必须全部是真实持久化字段"

    unauthorized = changed -- authorized

    assert unauthorized == [],
           "#{label}：只有契约授权的字段可以改变，未授权的改动：" <>
             inspect(Enum.map(unauthorized, &{&1, Map.get(row, &1), Map.get(fresh_row, &1)}))

    assert Map.drop(fresh_row, authorized) === Map.drop(row, authorized),
           "#{label}：掩码之外的每一个持久化字段都必须逐字不变"
  end

  defp correction_row_diff(fresh_row, row) do
    fresh_row
    |> Enum.reject(fn {field, value} -> Map.fetch!(row, field) === value end)
    |> Enum.map(&elem(&1, 0))
    |> Enum.sort()
  end

  # 【R1】proof caller 的真实入口相位是 metadata_committed；finalize caller 是 finalize_pending。
  defp correction_merge_entry_phase("proof"), do: "metadata_committed"
  defp correction_merge_entry_phase("finalize"), do: "finalize_pending"

  # 【R1】用既有 FS 协议 helper（`MutationBackup.manifest/4` + `encode/1`）播一份真实、
  # 可被 `decode/1` 完整重验的 durable backup，供「隔离必须保留取证物」正向断言。
  defp correction_seed_backup!(ctx, %Journal{} = journal) do
    {:ok, mctx} = MutationContext.from_journal(journal)
    dir = Path.join(ctx.dir, MutationBackup.relative_dir(journal.id))
    File.mkdir_p!(dir)

    part_bytes = "g3c backup bytes for #{journal.id}"
    part = Path.join(dir, "part.0")
    File.write!(part, part_bytes)

    {:ok, manifest} =
      MutationBackup.manifest(mctx.target, mctx.token, nil, [%{"name" => "part.0"}])

    {:ok, manifest_bytes} = MutationBackup.encode(manifest)
    manifest_path = Path.join(dir, MutationBackup.manifest_name())
    File.write!(manifest_path, manifest_bytes)

    %{
      dir: dir,
      part: part,
      part_bytes: part_bytes,
      manifest: manifest_path,
      manifest_bytes: manifest_bytes
    }
  end

  # ── Task 3 G3 Phase B 终审纠偏 helpers ──

  # 公共入口的唯一调用形态：把 raise / exit / throw 归一成可断言的 term。这样
  # 「稳定结果 vs FunctionClauseError / exit / raw tuple」是一条**真断言**，而不是
  # 让测试进程崩溃后被当作机械错误。归一值只用于失败签名，绝不参与任何泄漏 refute
  # （capability 断言先于全部 refute 执行）。
  defp phase_b_recover_outcome(%Journal{} = journal, opts) do
    Recovery.recover(journal.id, opts)
  rescue
    error -> {:raised, :error, error.__struct__, Exception.message(error)}
  catch
    :exit, reason -> {:raised, :exit, nil, inspect(reason)}
    :throw, value -> {:raised, :throw, nil, inspect(value)}
  end

  # 1,024 / 1,025 两格逐字同构的公共 canonical 配方：完整 observation list，
  # 只有 `required` 的位数不同。
  defp phase_b_finalize_callback(required),
    do: correction_callback("finalize", "unavailable", required)

  # 【R4】def/defp 子句 head 的三种形态（含 guard）。所有本地身份都由它派生为精确
  # `{name, arity}`；R1–R3 遗留的 name-only 抽象（`correction_functions/1`、
  # `correction_function_arities/1`、`correction_calls_local?/2` 等）已全部删除，
  # 以免同名不同 arity 的重载对任何一个探测器仍然可见。
  defp correction_clause_head({:when, _m, [inner | _guards]}), do: correction_clause_head(inner)
  defp correction_clause_head({name, _m, args}) when is_atom(name), do: {name, args}
  defp correction_clause_head(_head), do: nil

  # ── 【R7 / A】模块身份：只承认 defmodule 直接 body 中、首个 def/defp 之前的 alias prelude ──
  #
  # R6 用 `Macro.prewalk` 全模块收集 alias，因此**函数体内**或**首个函数之后**的 decoy
  # alias 也会进表；同一 short name 被绑到两个模块时还会被 `Map.merge` 静默覆盖。二者都能
  # 让 `Fake.*` 命中精确锚点。R7 改为：
  #   1. 只取 `defmodule _ do <body> end` 的**直接**语句序列；
  #   2. 顺序扫描，遇到第一个 `def`/`defp` 即停止（prelude 之后的 alias 一律不认）；
  #   3. 表形态为 `%{short => MapSet(full_parts)}`，**只有 singleton 才展开**；同一 short
  #      被绑定到多个模块视为歧义，拒绝展开（返回 nil，从而不命中任何锚点）。
  # 完全限定名（首段未被 alias 绑定）仍可直接匹配。
  # 【R7 amendment / alias 顺序解析】alias **target 本身**必须先按「该指令处已存在的 alias
  # 环境」归一，再入表；否则
  #   `alias Fake, as: Maxio` + `alias Maxio.Storage.PublishedProof`
  # 的第二条 raw parts 看起来是真实模块，实际语义是 `Fake.Storage.PublishedProof`。
  # 同时：前导 `Elixir` 视为绝对根并剥掉；歧义/自指一律 fail closed（写入 :ambiguous 使该
  # short name 永不展开）。这仍是**有界的 alias 文法**，不是通用词法分析。
  defp correction_alias_prelude(ast) do
    ast
    |> correction_module_body_statements()
    |> Enum.reduce_while(%{}, fn stmt, acc ->
      case stmt do
        {kind, _meta, _args} when kind in [:def, :defp] ->
          {:halt, acc}

        _other ->
          entries =
            stmt
            |> correction_alias_entries()
            |> Map.new(fn {short, parts} ->
              {short, correction_normalize_alias_target(parts, acc)}
            end)

          {:cont, correction_merge_alias_entries(acc, entries)}
      end
    end)
  end

  # 用当前环境归一 alias target：前导 `Elixir` 剥掉视为绝对；首段命中 singleton 绑定则展开；
  # 首段绑定歧义则返回 `:ambiguous`（fail closed）。
  defp correction_normalize_alias_target([:"Elixir" | rest], _env) when rest != [], do: rest

  defp correction_normalize_alias_target([head | rest] = parts, env) do
    case Map.get(env, head) do
      nil ->
        parts

      :ambiguous ->
        :ambiguous

      bound ->
        case MapSet.to_list(bound) do
          [:ambiguous] -> :ambiguous
          [full] when is_list(full) -> full ++ rest
          _many -> :ambiguous
        end
    end
  end

  defp correction_normalize_alias_target(parts, _env), do: parts

  # `defmodule _ do ... end` 的直接语句序列（单表达式 body 也归一成列表）。
  defp correction_module_body_statements({:defmodule, _meta, [_name, blocks]})
       when is_list(blocks) do
    case Keyword.get(blocks, :do) do
      {:__block__, _bm, stmts} when is_list(stmts) -> stmts
      nil -> []
      single -> [single]
    end
  end

  defp correction_module_body_statements(_ast), do: []

  defp correction_merge_alias_entries(acc, entries) do
    Enum.reduce(entries, acc, fn {short, parts}, inner ->
      Map.update(inner, short, MapSet.new([parts]), &MapSet.put(&1, parts))
    end)
  end

  defp correction_alias_entries({:alias, _meta, [{:__aliases__, _m, parts}]}) when is_list(parts),
    do: %{List.last(parts) => parts}

  defp correction_alias_entries({:alias, _meta, [{:__aliases__, _m, parts}, opts]})
       when is_list(parts) and is_list(opts) do
    case Keyword.get(opts, :as) do
      {:__aliases__, _am, [as_name]} -> %{as_name => parts}
      _other -> %{List.last(parts) => parts}
    end
  end

  # `alias A.B.{C, D}`
  defp correction_alias_entries(
         {:alias, _meta, [{{:., _dm, [{:__aliases__, _pm, prefix}, :{}]}, _cm, children}]}
       )
       when is_list(prefix) and is_list(children) do
    Map.new(children, fn {:__aliases__, _cm2, parts} ->
      {List.last(parts), prefix ++ parts}
    end)
  end

  defp correction_alias_entries(_node), do: %{}

  # 把 `A.B` 形态的模块 AST 归一成完整 parts。别名必须 singleton 且非 :ambiguous 才展开；
  # 前导 `Elixir` 视为绝对根。歧义一律返回 nil（不命中任何锚点）。
  defp correction_resolve_module({:__aliases__, _meta, [:"Elixir" | rest]}, _aliases)
       when rest != [],
       do: rest

  defp correction_resolve_module({:__aliases__, _meta, parts}, aliases) when is_list(parts) do
    case Map.get(aliases, hd(parts)) do
      nil ->
        parts

      bound ->
        case MapSet.to_list(bound) do
          [full] when is_list(full) -> full ++ tl(parts)
          _ambiguous_or_marked -> nil
        end
    end
  end

  defp correction_resolve_module(_node, _aliases), do: nil

  # 精确远程调用：模块语义身份 + 函数名 + arity 三者全中才算命中。
  defp correction_exact_remote_call?(node, aliases, {mod_parts, fun, arity}) do
    case node do
      {{:., _dm, [mod_ast, ^fun]}, _meta, args} when is_list(args) ->
        length(args) == arity and correction_resolve_module(mod_ast, aliases) == mod_parts

      _node ->
        false
    end
  end

  defp correction_exact_remote_calls(ast, aliases, mfa) do
    collect_nodes(ast, &correction_exact_remote_call?(&1, aliases, mfa))
  end

  # def/defp 子句 body（`[do: ast]`）里的真实表达式。
  # 【R6】tail-expression helper 已删除：canonical grammar 只承认 body **本身**的形态，
  # 不再有任何「取 block 尾项」的宽松口径。
  defp correction_do_expr(body) when is_list(body), do: Keyword.get(body, :do)
  defp correction_do_expr(body), do: body

  # ── 【R4】精确本地 MFA 身份 ──
  #
  # R3 的 owner/helper 抽象以**函数名**为键，因此同名不同 arity 的重载可以互相授权
  # （`preserving/3` 合格就等于放行 `preserving/1`；caller tail-call 任一 arity 都算命中）。
  # R4 全部改为精确本地 `{name, arity}` 身份，并保留每个子句的 head args 供续延参数推断。

  # `%{{name, arity} => [%{args: [...], body: ast}]}` —— 每个子句一条记录（含 guard 头）。
  defp correction_local_index(ast) do
    {_ast, acc} =
      Macro.prewalk(ast, %{}, fn node, acc ->
        case correction_clause_entry(node) do
          nil -> {node, acc}
          {mfa, clause} -> {node, Map.update(acc, mfa, [clause], &(&1 ++ [clause]))}
        end
      end)

    acc
  end

  # 【R7 amendment 2】保留 guard 元数据：owner / preserving helper / 三个 caller 都必须是
  # 恰好一个**无 guard**子句。
  defp correction_clause_entry({kind, _meta, [head, body]}) when kind in [:def, :defp] do
    guarded? = match?({:when, _m, _a}, head)

    case correction_clause_head(head) do
      {name, args} when is_atom(name) and is_list(args) ->
        {{name, length(args)}, %{args: args, body: correction_do_expr(body), guarded?: guarded?}}

      {name, nil} when is_atom(name) ->
        {{name, 0}, %{args: [], body: correction_do_expr(body), guarded?: guarded?}}

      _other ->
        nil
    end
  end

  defp correction_clause_entry(_node), do: nil

  # 精确本地调用：名字与**实际实参个数**同时命中。
  defp correction_exact_local_call?(node, {name, arity}) do
    case node do
      {^name, _meta, args} when is_list(args) -> length(args) == arity
      _other -> false
    end
  end

  defp correction_exact_local_calls(ast, mfa),
    do: collect_nodes(ast, &correction_exact_local_call?(&1, mfa))

  # ── 【R7 / D】合格 preserving helper 的窄语法 ──
  #
  # R6 只要求「该 MFA 每个子句的 body 里**含有**精确公共 API 调用」，于是
  # `public_call; :forged` 与 forged 实参（错 journal / 错 code / `[]`）都能取得资格。
  # R7 收紧为固定 wrapper 形态：
  #
  #     defp helper(journal, code, opts) do
  #       case ObjectMutation.quarantine_preserving_evidence(journal, code, journal_opts(opts)) do
  #         {:ok, _} -> ...
  #         {:error, _} -> ...
  #       end
  #     end
  #
  # 即：exact local /3、恰好一个 clause、三个 head 参数是两两不同的严格普通变量；body
  # **本身**是 direct case；scrutinee **本身**是精确公共 API 调用；三个实参精确为
  # `(journal, code, journal_opts(opts))`（`journal_opts/1` 为 exact local unary）；
  # case 至少有两个无 guard 的 ok/error 臂覆盖公共结果。
  #
  # 【边界，诚实声明】该静态资格只证明「这条 seam 确实把 evidence-preserving mutation
  # 连同正确参数链发出去了」。它**不**证明 outer outcome / 结构化日志 / 稳定 convergence
  # 映射——那些由既有动态 correction cells 证明。
  defp correction_preserving_mfas(index, aliases) do
    index
    |> Enum.filter(fn {mfa, clauses} ->
      correction_qualified_preserving?(mfa, clauses, aliases)
    end)
    |> Enum.map(&elem(&1, 0))
    |> MapSet.new()
  end

  defp correction_qualified_preserving?({_name, 3}, [clause], aliases) do
    with false <- clause.guarded?,
         {:ok, [journal_id, code_id, opts_id]} <- correction_preserving_head(clause.args),
         {:case, _meta, [scrutinee, blocks]} <- clause.body,
         true <- is_list(blocks),
         true <- correction_exact_remote_call?(scrutinee, aliases, @correction_preserving_mfa),
         {_dot, _cm, [a0, a1, a2]} <- scrutinee,
         true <- correction_arg_is_identity?(a0, journal_id),
         true <- correction_arg_is_identity?(a1, code_id),
         true <- correction_arg_is_local_unary_of(a2, opts_id) == @correction_journal_opts_mfa do
      correction_preserving_arms_ok?(
        Keyword.get(blocks, :do, []),
        [journal_id, code_id, opts_id],
        aliases
      )
    else
      _other -> false
    end
  end

  defp correction_qualified_preserving?(_mfa, _clauses, _aliases), do: false

  defp correction_preserving_head(args) do
    identities = Enum.map(args, &correction_plain_var_identity/1)

    if length(args) == 3 and Enum.all?(identities, &(&1 != nil)) and
         length(Enum.uniq(identities)) == 3 do
      {:ok, identities}
    else
      :error
    end
  end

  # 【R7 amendment 3】恰好两个**无 guard**臂、无 catch-all；ok/error binder 都是**新的**
  # 严格普通变量（不得遮蔽三个 head 参数）；成功臂尾部必须真的用到该 quarantined binder，
  # 错误臂必须返回携带该 reason 的 journal-convergence 结果。
  #
  # 【边界，诚实声明】允许成功臂在尾表达式前保留既有 `Log.error` 之类的结构化日志 prelude；
  # 该谓词只锁「真实 binder 被用于最终结果」这一条链，**不**证明 outer outcome / 日志内容 /
  # 稳定 convergence 语义——那些仍由动态 correction cells 全权证明。
  defp correction_preserving_arms_ok?([ok_arm, error_arm], head_ids, aliases) do
    with {:->, _m1, [[ok_pattern], ok_body]} <- ok_arm,
         {:->, _m2, [[error_pattern], error_body]} <- error_arm,
         ok_id when ok_id != nil <- correction_public_binder(ok_pattern, :ok),
         error_id when error_id != nil <- correction_public_binder(error_pattern, :error),
         false <- ok_id in head_ids,
         false <- error_id in head_ids do
      correction_preserving_ok_arm_ok?(ok_body, ok_id, aliases) and
        correction_preserving_error_arm_ok?(error_body)
    else
      _other -> false
    end
  end

  defp correction_preserving_arms_ok?(_arms, _head_ids, _aliases), do: false

  defp correction_public_binder({tag, binder}, tag), do: correction_plain_var_identity(binder)
  defp correction_public_binder(_pattern, _tag), do: nil

  # 【R7.1 / gap 2】成功臂**整体形态**白名单，不再"任意 block 只取 List.last"：
  #   (a) body 本身就是 exact tail；或
  #   (b) body 恰好是两个表达式的 block：
  #       `[exact Maxio.ObjectMutation.Log.error/2 direct call, exact tail]`。
  # 任何 `throw(...)`、赋值、第三个表达式或其它调用作为 prelude 一律拒绝。
  @correction_log_error_mfa {[:Maxio, :ObjectMutation, :Log], :error, 2}

  defp correction_preserving_ok_arm_ok?(body, binder, aliases) do
    case body do
      {:__block__, _m, [prelude, tail]} ->
        correction_exact_remote_call?(prelude, aliases, @correction_log_error_mfa) and
          correction_preserving_ok_tail?(tail, binder)

      {:__block__, _m, _other} ->
        false

      single ->
        correction_preserving_ok_tail?(single, binder)
    end
  end

  # 错误臂不允许任何 prelude：body **本身**必须就是 exact tail。
  defp correction_preserving_error_arm_ok?(body), do: correction_preserving_error_tail?(body)

  # 成功臂尾部必须**精确**是 `{:ok, :quarantined, <quarantined binder>}`。
  defp correction_preserving_ok_tail?(node, {name, ctx}),
    do: match?({:{}, _meta, [:ok, :quarantined, {^name, _vm, ^ctx}]}, node)

  # 错误臂尾部必须**精确**是 `{:error, @stable_journal_convergence_failed}` —— 即 Phase B
  # 必须落地的那个冻结 module attribute AST，而不是 raw tuple 或任何伪造形态。
  defp correction_preserving_error_tail?(node),
    do:
      match?(
        {:error, {:@, _am, [{:stable_journal_convergence_failed, _vm, ctx}]}} when is_atom(ctx),
        node
      )

  # 【R7】续延位置不再"推断"：canonical owner 契约把它固定为
  # `@correction_owner_continuation_pos`，因此 R4/R5 的 `correction_continuation_positions/1`
  # 与 `correction_dot_called_identities/1` 已被删除（固定契约覆盖了它们的能力）。

  # ── 【R7 / B】严格普通变量：全 oracle 唯一的变量 identity 口径 ──
  #
  # `{name, meta, ctx}` 且 ctx 为 atom 只说明它是「变量形状」的 AST；`__MODULE__`、
  # `__ENV__`、`__DIR__`、`__CALLER__`、`__STACKTRACE__` 等 special form 同样是这个形状，
  # 会被 R6 当成合法 head 参数/binder。R7 收紧为「严格普通变量」：
  #   * 必须是 Macro 变量 AST（第三元为 atom context）；
  #   * name 不是 `_`；
  #   * name 不是任何 `__...__` magic special form。
  # 拒绝 literal / call / field access / pin / guard 形态。
  # 续延 head 参数、成功 binder、error reason binder、helper head 参数与 dot-call 身份
  # **全部**只用这一个 predicate。
  defp correction_plain_var_identity({name, _meta, ctx}) when is_atom(name) and is_atom(ctx) do
    text = Atom.to_string(name)

    cond do
      name == :_ -> nil
      String.starts_with?(text, "__") and String.ends_with?(text, "__") -> nil
      true -> {name, ctx}
    end
  end

  defp correction_plain_var_identity(_node), do: nil

  # ── 【R7 / C】固定 owner canonical contract ──
  #
  # R6 只说「head 里某个形参被 `param.(...)` 调用」，因此 arity、参数语义与 scrutinee /
  # preserving 的**实参身份链**全部未被锁定：forged literal、错变量、错字段都能通过。
  # R7 把 owner 契约固定为唯一签名：
  #
  #     owner/6 = (journal, target_phase, summary, mode, opts, continuation)
  #
  # 六个 head 参数必须是两两不同的严格普通变量；续延固定在 position 5。
  # （固定 owner/mapper 常量集中定义在文件顶部的 R7 常量块，见 `@correction_owner_arity` 等。）

  # head 参数的 identity 列表；任一非严格普通变量或存在重复即返回 {:error, reason}。
  defp correction_owner_head_identities(args) do
    identities = Enum.map(args, &correction_plain_var_identity/1)
    bad = Enum.filter(Enum.with_index(identities), fn {id, _i} -> id == nil end)

    cond do
      length(args) != @correction_owner_arity ->
        {:error,
         "owner 必须是 arity #{@correction_owner_arity}，签名固定为 " <>
           "(#{Enum.join(@correction_owner_param_names, ", ")})（实际 arity #{length(args)}）"}

      bad != [] ->
        {:error,
         "head 参数位置 #{inspect(Enum.map(bad, &elem(&1, 1)))} 不是严格普通变量" <>
           "（`_`、`__MODULE__` 等 special form、字面量与调用一律不接受）"}

      length(Enum.uniq(identities)) != length(identities) ->
        {:error, "六个 head 参数必须两两不同（存在重复 identity）"}

      true ->
        {:ok, identities}
    end
  end

  # 实参必须与给定 head identity 完全相同的严格普通变量。
  defp correction_arg_is_identity?(arg, identity),
    do: correction_plain_var_identity(arg) == identity

  # 实参必须是 `<var>.<field>` 的字段读取，且 var 与给定 identity 相同。
  # 【R7.1 / gap 1】必须是**无括号**字段读取 `journal.recovery_evidence`。
  # 外层 metadata 的 `:no_parens` 为 true 才算字段读取；`journal.recovery_evidence()`
  # 是零元函数调用（无 `:no_parens`），语义不同，必须拒绝。
  defp correction_arg_is_field_of?({{:., _dm, [target, field]}, meta, []}, identity, field),
    do:
      Keyword.get(meta, :no_parens) == true and correction_plain_var_identity(target) == identity

  defp correction_arg_is_field_of?(_arg, _identity, _field), do: false

  # 实参必须是某个 exact local unary 调用作用在给定 identity 上（返回该 mapper 的 MFA）。
  defp correction_arg_is_local_unary_of(arg, identity) do
    case arg do
      {name, _meta, [inner]} when is_atom(name) ->
        if correction_plain_var_identity(inner) == identity, do: {name, 1}

      _other ->
        nil
    end
  end

  # 【R6】成功臂 body **本身**必须就是 `continuation.(merged)`：一元直接调用，call target
  # 与实参都按 `{name, context}` identity 对齐。
  #
  # canonical grammar 规定 arm body 是**单一直接调用**，因此不存在 prelude/block/赋值等
  # 可以插入重绑定的位置——「continuation 或 merged 被重新绑定」这一类形态是被 grammar
  # **按构造**排除的，而不是靠扫描绑定流去追踪。R5 里那套通用绑定扫描
  # （`correction_rebinds_identity?/2` 等）已随之删除：它的能力被 grammar 覆盖，且它曾被
  # 过强地表述为通用 shadow/capture 分析。
  defp correction_canonical_success_body?(body, {cont_name, cont_ctx}, {bound_name, bound_ctx}) do
    match?(
      {{:., _dm, [{^cont_name, _vm, ^cont_ctx}]}, _meta, [{^bound_name, _bm, ^bound_ctx}]},
      body
    )
  end

  # 无 guard 的精确 `{:ok, merged}` 模式，merged 必须是**严格普通变量** → 其 identity。
  # 【R7 / B】`{:ok, __MODULE__}`、`{:ok, _}`、`{:ok, :literal}` 一律不接受。
  defp correction_canonical_ok_pattern({:ok, binder}),
    do: correction_plain_var_identity(binder)

  defp correction_canonical_ok_pattern(_pattern), do: nil

  # 无 guard 的精确 `{:error, reason}` 模式，reason 必须是**严格普通变量**：这样才覆盖
  # 所有 reason。`{:error, :only_this_reason}` 这种窄字面量只覆盖单一 reason，其余
  # merge 拒绝会漏出 case，故不接受。
  defp correction_canonical_error_identity({:error, binder}),
    do: correction_plain_var_identity(binder)

  defp correction_canonical_error_identity(_pattern), do: nil

  # 【R6】caller 的每个子句 body **本身**必须就是对 owner 精确 MFA 的直接本地调用。
  # 不再接受 block 的尾项：`throw(:early); owner(...)`、`x = owner(...)`、
  # `case owner(...) do` 一律拒绝。
  defp correction_direct_calls_owner_mfa?(clauses, owner_mfa) do
    clauses != [] and
      Enum.all?(clauses, fn clause ->
        correction_exact_local_call?(clause.body, owner_mfa)
      end)
  end

  # 直接 body 调用在续延位置传入的实参（body 本身不是精确 owner 调用则 :missing）。
  defp correction_direct_continuation_arg(clause, owner_mfa, cont_pos) do
    if correction_exact_local_call?(clause.body, owner_mfa) do
      {_name, _meta, args} = clause.body
      Enum.at(args, cont_pos, :missing)
    else
      :missing
    end
  end

  # 【R7.1 / gap 4】续延实参必须是 explicit fn，且**恰好一个无 guard `->` 子句**，
  # 其唯一 binder 是 strict plain variable 且相对 caller 全部 head identity 都 fresh。
  # literal / special form / guarded / multi-clause fn 一律拒绝。
  defp correction_explicit_unary_fn?({:fn, _meta, [{:->, _m, [[param], _body]}]}, head_ids) do
    case correction_plain_var_identity(param) do
      nil -> false
      identity -> identity not in head_ids
    end
  end

  defp correction_explicit_unary_fn?(_node, _head_ids), do: false

  # ── 【R7 / E】三个固定 caller contract ──
  #
  # 目标 MFA、head 语义、固定 target literal 与 mode head 位置全部锁定；body 本身直接调用
  # exact owner /6，前五个实参必须精确为
  # `(head journal, 固定 target literal, head summary, head mode, head opts)`，
  # 第 6 个（pos 5）必须是显式一元 fn。
  # 【R4】单个 caller 的全部续延契约缺陷（不抛断言，只如实收集，供聚合断言列出）。
  defp correction_caller_deficits(index, caller_name, owner_mfa, cont_pos, preserving_mfas),
    do:
      correction_caller_deficits(
        index,
        caller_name,
        owner_mfa,
        cont_pos,
        preserving_mfas,
        Map.get(@correction_caller_specs, caller_name)
      )

  defp correction_caller_deficits(index, caller_name, owner_mfa, cont_pos, preserving_mfas, spec) do
    mfas = index |> Map.keys() |> Enum.filter(fn {name, _a} -> name == caller_name end)

    case mfas do
      [] ->
        ["#{caller_name}: 在被拆解的本地函数集合里不存在"]

      [_ | _] = many when length(many) > 1 ->
        ["#{caller_name}: 存在多个 arity 重载 #{inspect(many)}，契约必须唯一无歧义"]

      [caller_mfa] ->
        correction_caller_mfa_deficits(
          index[caller_mfa],
          caller_mfa,
          owner_mfa,
          cont_pos,
          preserving_mfas
        ) ++ correction_caller_spec_deficits(index[caller_mfa], caller_mfa, owner_mfa, spec)
    end
  end

  # 固定签名 + 前五实参身份链。spec 为 nil（合成 caller）时只跳过这部分。
  defp correction_caller_spec_deficits(_clauses, _caller_mfa, _owner_mfa, nil), do: []

  defp correction_caller_spec_deficits(clauses, caller_mfa, owner_mfa, spec) do
    label = correction_mfa(caller_mfa)

    arity =
      if elem(caller_mfa, 1) == spec.arity,
        do: [],
        else: ["#{label} 必须是 arity #{spec.arity}，签名固定为 (#{Enum.join(spec.params, ", ")})"]

    # 【R7.1 / gap 4】totality：恰好一条 clause 且该 clause `guarded? == false`。
    clause_count =
      cond do
        length(clauses) != 1 ->
          ["#{label} 必须恰好一个 clause（实际 #{length(clauses)}）"]

        Enum.any?(clauses, & &1.guarded?) ->
          ["#{label} 的唯一 clause 不允许带 guard"]

        true ->
          []
      end

    args =
      case clauses do
        [clause] -> correction_caller_arg_chain_deficits(clause, label, owner_mfa, spec)
        _many -> []
      end

    arity ++ clause_count ++ args
  end

  defp correction_caller_arg_chain_deficits(clause, label, owner_mfa, spec) do
    identities = Enum.map(clause.args, &correction_plain_var_identity/1)

    cond do
      length(clause.args) != spec.arity or Enum.any?(identities, &(&1 == nil)) or
          length(Enum.uniq(identities)) != length(identities) ->
        ["#{label} 的 head 参数必须是 #{spec.arity} 个两两不同的严格普通变量"]

      not correction_exact_local_call?(clause.body, owner_mfa) ->
        []

      true ->
        {_name, _meta, owner_args} = clause.body
        by_name = Enum.zip(spec.params, identities) |> Map.new()

        expected = [
          {0, "head 的 `#{elem(by_name.journal, 0)}`",
           correction_arg_is_identity?(Enum.at(owner_args, 0), by_name.journal)},
          {1, "固定 target 字面量 `\"#{spec.target}\"`", Enum.at(owner_args, 1) == spec.target},
          {2, "head 的 `#{elem(by_name.summary, 0)}`",
           correction_arg_is_identity?(Enum.at(owner_args, 2), by_name.summary)},
          {3, "head 的 `#{elem(by_name.mode, 0)}`（mode head pos #{spec.mode_pos}）",
           correction_arg_is_identity?(Enum.at(owner_args, 3), by_name.mode)},
          {4, "head 的 `#{elem(by_name.opts, 0)}`",
           correction_arg_is_identity?(Enum.at(owner_args, 4), by_name.opts)}
        ]

        for {pos, expectation, ok?} <- expected, not ok? do
          "#{label} 传给 owner 的实参 ##{pos} 必须是 #{expectation}，实际：" <>
            correction_compact(Macro.to_string(Enum.at(owner_args, pos, :__missing__)))
        end
    end
  end

  # 真实代码中所有 `pg_merged_*` callsite 的 mode 实参：必须是 literal `:proof | :finalize`，
  # 且两种都非空。这是有界的 callsite 扫描，不做通用跨函数数据流；具体
  # proof/finalize 路径映射仍由动态六格证明。
  # 【R7 amendment 5】callsite 必须**按宿主分组**精确成立，而不是"全局两种字面量都出现过"：
  #   * `apply_pg_proof_disposition` 的各子句内恰好 3 处 `pg_merged_*` 调用，mode 实参全为
  #     literal `:proof`；
  #   * `apply_pg_finalize_disposition` 的各子句内恰好 4 处，mode 实参全为 literal
  #     `:finalize`；
  #   * 其余任何位置 0 处。
  # 这是有界的 callsite 扫描（按 owner 函数分组），不做通用跨函数数据流。
  # 【R7.1 / gap 5】host 分组按**精确 MFA**（含 arity），不再按裸函数名：同名不同 arity 的
  # decoy host 承载了"正确数量"的 callsite 时，按名分组会把它算进合规宿主。
  defp correction_callsite_deficits(index) do
    hosts = Map.new(@correction_callsite_groups, fn {mfa, n, mode} -> {mfa, {n, mode}} end)

    grouped =
      for {host_mfa, clauses} <- index,
          clause <- clauses,
          {caller_name, spec} <- @correction_caller_specs,
          call <- correction_local_call_nodes(clause.body, caller_name),
          do: {host_mfa, caller_name, spec, call}

    per_host = Enum.group_by(grouped, fn {host_mfa, _c, _s, _call} -> host_mfa end)

    group_deficits =
      Enum.flat_map(@correction_callsite_groups, fn {host_mfa, expected, mode} ->
        calls = Map.get(per_host, host_mfa, [])
        host = correction_mfa(host_mfa)

        count =
          if length(calls) == expected,
            do: [],
            else: ["`#{host}` 内的 pg_merged_* callsite 必须恰好 #{expected} 处，实际 #{length(calls)}"]

        modes =
          for {_h, caller_name, spec, {_n, _m, args}} <- calls,
              Enum.at(args, spec.mode_pos) != mode do
            "`#{host}` 内 `#{caller_name}` callsite 的 mode 实参必须是 literal `#{inspect(mode)}`，实际：" <>
              correction_compact(Macro.to_string(Enum.at(args, spec.mode_pos, :__missing__)))
          end

        count ++ modes
      end)

    stray =
      for {host_mfa, caller_name, _spec, _call} <- grouped, not Map.has_key?(hosts, host_mfa) do
        "`#{caller_name}` 的 callsite 出现在 `#{correction_mfa(host_mfa)}` 内：" <>
          "只允许出现在两个精确 disposition 宿主 MFA 里"
      end

    group_deficits ++ Enum.uniq(stray)
  end

  # 指定名字的本地调用节点（返回真实 AST 节点，供实参检查使用）。
  defp correction_local_call_nodes(ast, name) do
    {_ast, acc} =
      Macro.prewalk(ast, [], fn node, acc ->
        case node do
          {^name, _m, args} when is_list(args) -> {node, acc ++ [node]}
          _other -> {node, acc}
        end
      end)

    acc
  end

  defp correction_caller_mfa_deficits(clauses, caller_mfa, owner_mfa, cont_pos, preserving_mfas) do
    label = correction_mfa(caller_mfa)
    bodies = Enum.map(clauses, & &1.body)

    routing =
      if Enum.any?(bodies, &(correction_exact_local_calls(&1, owner_mfa) != [])),
        do: [],
        else: ["#{label} 未经唯一 adapter seam `#{correction_mfa(owner_mfa)}` 路由"]

    direct_call =
      if correction_direct_calls_owner_mfa?(clauses, owner_mfa),
        do: [],
        else: [
          "#{label} 的子句 body **本身**不是对 `#{correction_mfa(owner_mfa)}` 的直接本地调用" <>
            "（canonical caller grammar 只承认 direct body，不接受 block 尾项）。实际 body：" <>
            correction_body_summary(bodies)
        ]

    continuation =
      correction_caller_continuation_deficits(clauses, caller_mfa, owner_mfa, cont_pos)

    bindings =
      case correction_owner_result_bindings(bodies, owner_mfa) do
        [] -> []
        hits -> ["#{label} 绑定/解构/分支了 `#{correction_mfa(owner_mfa)}` 的结果：#{inspect(hits)}"]
      end

    error_arms =
      case correction_owner_error_arms(bodies, owner_mfa) do
        [] -> []
        hits -> ["#{label} 对 adapter 结果持有本地拒绝/错误分支：#{inspect(hits)}"]
      end

    preserving_calls =
      if Enum.any?(bodies, fn body ->
           Enum.any?(preserving_mfas, &(correction_exact_local_calls(body, &1) != []))
         end),
         do: ["#{label} 调用了 evidence-preserving quarantine 精确 MFA（adapter 拒绝分支专属）"],
         else: []

    tags =
      case correction_rejection_tags(bodies) do
        [] -> []
        hits -> ["#{label} 自行构造拒绝 tag：#{inspect(hits)}"]
      end

    routing ++ direct_call ++ continuation ++ bindings ++ error_arms ++ preserving_calls ++ tags
  end

  defp correction_caller_continuation_deficits(_clauses, caller_mfa, _owner_mfa, nil),
    do: [
      "#{correction_mfa(caller_mfa)} 无法校验续延实参：adapter 未声明续延参数位置"
    ]

  defp correction_caller_continuation_deficits(clauses, caller_mfa, owner_mfa, cont_pos) do
    label = correction_mfa(caller_mfa)

    clauses
    |> Enum.with_index()
    |> Enum.flat_map(fn {clause, i} ->
      case correction_direct_continuation_arg(clause, owner_mfa, cont_pos) do
        :missing ->
          ["#{label} 子句 ##{i} 未在续延位置 #{cont_pos} 传入实参（body 本身不是精确 owner 调用）"]

        arg ->
          # 【R7.1 / gap 4】fn 必须恰好一个无 guard `->` 子句，唯一 binder 是 strict plain
          # variable 且相对该 caller 的全部 head identity 都 fresh。
          head_ids = Enum.map(clause.args, &correction_plain_var_identity/1)

          if correction_explicit_unary_fn?(arg, head_ids),
            do: [],
            else: [
              "#{label} 子句 ##{i} 在续延位置 #{cont_pos} 传入的不是合规续延 fn" <>
                "（须为恰好一个无 guard 子句、唯一 binder 为相对 head fresh 的严格普通变量）：" <>
                correction_compact(Macro.to_string(arg))
            ]
      end
    end)
  end

  defp correction_mfa({name, arity}), do: "#{name}/#{arity}"

  # 【R4】owner 契约：**每一个** owner 子句都必须
  #   (a) 自带以精确 merge_failure/3 为 scrutinee/generator 的因果构造；
  #   (b) 从 head 结构化推断出**唯一**续延参数位置，且全部子句位置一致；
  #   (c) 每条成功臂 tail-call `continuation.(merged)`，实参恰为该臂绑定的 merged；
  #   (d) 每条非成功臂 tail-return 精确 preserving MFA / 公共 API。
  # 返回 `{deficits, continuation_position | nil}`。
  defp correction_owner_deficits(clauses, owner_mfa, aliases, preserving_mfas) do
    label = correction_mfa(owner_mfa)

    per_clause =
      clauses
      |> Enum.with_index()
      |> Enum.map(fn {clause, i} ->
        correction_owner_clause_deficits(clause, i, label, aliases, preserving_mfas)
      end)

    positions = per_clause |> Enum.map(& &1.cont_pos) |> Enum.uniq()

    consistency =
      case positions do
        [_single] ->
          []

        many ->
          [
            "#{label} 的续延参数位置在各子句间不一致：#{inspect(many)}" <>
              "（续延位置必须是该 adapter 契约的稳定组成部分）"
          ]
      end

    cont_pos =
      case positions do
        [single] -> single
        _many -> nil
      end

    {Enum.flat_map(per_clause, & &1.deficits) ++ consistency, cont_pos}
  end

  # 【R7 / C】固定 owner canonical contract 逐子句判定。
  defp correction_owner_clause_deficits(clause, i, label, aliases, preserving_mfas) do
    case correction_owner_head_identities(clause.args) do
      {:error, reason} ->
        %{deficits: ["#{label} 子句 ##{i} 的 head 不符合固定 owner 签名：#{reason}"], cont_pos: nil}

      {:ok, identities} ->
        [journal_id, target_phase_id, summary_id, mode_id, opts_id, cont_id] = identities

        body =
          correction_owner_body_deficits(
            clause,
            i,
            label,
            aliases,
            preserving_mfas,
            %{
              journal: journal_id,
              target_phase: target_phase_id,
              summary: summary_id,
              mode: mode_id,
              opts: opts_id,
              continuation: cont_id
            }
          )

        %{deficits: body, cont_pos: @correction_owner_continuation_pos}
    end
  end

  defp correction_owner_body_deficits(clause, i, label, aliases, preserving_mfas, ids) do
    case correction_canonical_case(clause.body, aliases) do
      {:error, reason} ->
        [
          "#{label} 子句 ##{i} 的 body 不符合 canonical merge case grammar：#{reason}。" <>
            "实际 body：" <> correction_compact(Macro.to_string(clause.body))
        ]

      {:ok, canonical} ->
        # 【R7 amendment 1】error binder 必须与**全部六个** owner head identity 都不同，
        # 否则 `{:error, journal}` 会遮蔽原 journal，使拒绝臂的 `journal` 实参名义合规。
        shadow =
          if canonical.error_identity in Map.values(ids) do
            [
              "#{label} 子句 ##{i} 的 error binder `#{elem(canonical.error_identity, 0)}` " <>
                "与某个 owner head 形参同 identity：会遮蔽原参数，必须使用新变量"
            ]
          else
            []
          end

        shadow ++
          correction_owner_scrutinee_deficits(canonical.scrutinee_args, i, label, ids) ++
          correction_owner_success_deficits(canonical, i, label, ids) ++
          correction_owner_error_deficits(canonical, i, label, ids, preserving_mfas)
    end
  end

  # 【R7 amendment 2】固定契约函数必须是恰好一个**无 guard**子句。
  defp correction_single_unguarded_clause_deficits(clauses, label) do
    cond do
      length(clauses) != 1 ->
        ["#{label} 必须恰好一个 clause（实际 #{length(clauses)}）"]

      Enum.any?(clauses, & &1.guarded?) ->
        ["#{label} 的 clause 不允许带 guard"]

      true ->
        []
    end
  end

  # 【R7 amendment 4】`pg_contract_code/1` 的固定形态：两个无 guard 子句，头参分别是
  # `:proof` / `:finalize` 字面量。
  defp correction_contract_code_deficits(index) do
    label = correction_mfa(@correction_contract_code_mfa)

    case Map.get(index, @correction_contract_code_mfa) do
      nil ->
        ["mode→code seam `#{label}` 不存在：owner 拒绝臂无法锁定唯一 mapper"]

      clauses ->
        # 【R7.1 / gap 3】totality：必须**恰好两个** clause（第三条 / `_other` catchall 一律
        # 违约），两条都 unguarded，且每条都能成功 decode 成 `{mode_literal, 属性名}`。
        # 先前的 `for` 推导会**静默丢弃**无法 decode 的子句（catchall、字面量 body、
        # guard 子句），使集合比较仍然通过。
        decoded = Enum.map(clauses, &correction_contract_code_clause/1)

        cond do
          length(clauses) != 2 ->
            ["#{label} 必须恰好两个 clause（实际 #{length(clauses)}），不允许 catchall 或第三条"]

          Enum.any?(clauses, & &1.guarded?) ->
            ["#{label} 的子句不允许带 guard"]

          Enum.any?(decoded, &(&1 == nil)) ->
            [
              "#{label} 的每个子句都必须能 decode 成 `<mode 字面量> -> <精确属性>`，" <>
                "实际：" <> correction_compact(inspect(Enum.map(clauses, & &1.args)))
            ]

          Enum.sort(decoded) != Enum.sort(@correction_contract_code_clauses) ->
            [
              "#{label} 的子句集合必须逐字为 " <>
                "#{inspect(@correction_contract_code_clauses)}（不接受任意属性或等值字符串" <>
                "字面量），实际：#{inspect(decoded)}"
            ]

          true ->
            []
        end
    end
  end

  # 单个 mapper 子句 → `{mode 字面量, 属性名}`；任何无法 decode 的形态返回 nil
  # （catchall 变量头、非 atom 头、非属性 body 都算 undecodable）。
  defp correction_contract_code_clause(%{guarded?: false, args: [arg], body: body})
       when is_atom(arg) do
    case correction_attribute_name(body) do
      nil -> nil
      attr -> {arg, attr}
    end
  end

  defp correction_contract_code_clause(_clause), do: nil

  # `@name` 的属性名；非属性引用返回 nil（字符串字面量因此不会被接受）。
  defp correction_attribute_name({:@, _meta, [{name, _vm, ctx}]})
       when is_atom(name) and is_atom(ctx),
       do: name

  defp correction_attribute_name(_node), do: nil

  # scrutinee 三个实参必须精确为 `(target_phase, journal.recovery_evidence, summary)`。
  defp correction_owner_scrutinee_deficits([a0, a1, a2], i, label, ids) do
    checks = [
      {correction_arg_is_identity?(a0, ids.target_phase), 0,
       "必须是 head 的 `#{elem(ids.target_phase, 0)}`"},
      {correction_arg_is_field_of?(a1, ids.journal, :recovery_evidence), 1,
       "必须是 `#{elem(ids.journal, 0)}.recovery_evidence`"},
      {correction_arg_is_identity?(a2, ids.summary), 2, "必须是 head 的 `#{elem(ids.summary, 0)}`"}
    ]

    args = [a0, a1, a2]

    for {ok?, pos, expectation} <- checks, not ok? do
      "#{label} 子句 ##{i} 的 merge_failure/3 实参 ##{pos} #{expectation}，实际：" <>
        correction_compact(Macro.to_string(Enum.at(args, pos)))
    end
  end

  defp correction_owner_scrutinee_deficits(args, i, label, _ids),
    do: ["#{label} 子句 ##{i} 的 merge_failure/3 实参个数异常：#{length(args)}"]

  defp correction_owner_success_deficits(canonical, i, label, ids) do
    cond do
      # 【R7.1 / gap 6】ok binder 必须相对**全部六个** owner head identity 都 fresh，
      # 不只是不同于 continuation。
      #
      # 说明（精确）：`{:ok, journal} -> continuation.(journal)` 里那个 `journal` 绑定的
      # **就是 merge 结果**，并不是原 head journal——续延收到的值是对的。问题是它遮蔽了
      # head 同名参数：位置来源变得有歧义（读者/后续检查无法按 identity 区分"这是 merge
      # 结果还是 head 参数"），且该臂内再也拿不到原 journal。canonical grammar 因此要求
      # merged binder 必须是新变量。
      canonical.ok_identity in Map.values(ids) ->
        [
          "#{label} 子句 ##{i} 的成功 binder `#{elem(canonical.ok_identity, 0)}` 与某个 " <>
            "owner head 形参同 identity：遮蔽该 head 参数会使位置来源有歧义，" <>
            "且臂内失去对原参数的访问；merged binder 必须是新变量"
        ]

      correction_canonical_success_body?(
        canonical.ok_body,
        ids.continuation,
        canonical.ok_identity
      ) ->
        []

      true ->
        [
          "#{label} 子句 ##{i} 的成功臂 body 本身不是 " <>
            "`#{elem(ids.continuation, 0)}.(#{elem(canonical.ok_identity, 0)})` 的一元直接调用。" <>
            "实际臂 body：" <> correction_compact(Macro.to_string(canonical.ok_body))
        ]
    end
  end

  # 拒绝臂 body 必须是唯一合格 local preserving helper /3 的 direct call，
  # 参数链固定为 `(journal, <mapper>(mode), opts)`。
  defp correction_owner_error_deficits(canonical, i, label, ids, preserving_mfas) do
    case canonical.error_body do
      {name, _meta, [a0, a1, a2] = args} when is_atom(name) ->
        if MapSet.member?(preserving_mfas, {name, 3}) do
          checks = [
            {correction_arg_is_identity?(a0, ids.journal), 0,
             "必须是 head 的 `#{elem(ids.journal, 0)}`"},
            {correction_arg_is_local_unary_of(a1, ids.mode) == @correction_contract_code_mfa, 1,
             "必须是 exact `#{correction_mfa(@correction_contract_code_mfa)}` 作用于 head 的 " <>
               "`#{elem(ids.mode, 0)}`（不接受任意 unary mapper）"},
            {correction_arg_is_identity?(a2, ids.opts), 2, "必须是 head 的 `#{elem(ids.opts, 0)}`"}
          ]

          for {ok?, pos, expectation} <- checks, not ok? do
            "#{label} 子句 ##{i} 的拒绝臂 preserving 实参 ##{pos} #{expectation}，实际：" <>
              correction_compact(Macro.to_string(Enum.at(args, pos)))
          end
        else
          [
            "#{label} 子句 ##{i} 的拒绝臂调用的 `#{name}/3` 不是合格的 local preserving helper"
          ]
        end

      other ->
        [
          "#{label} 子句 ##{i} 的拒绝臂 body 本身不是合格 local preserving helper /3 的直接调用" <>
            "（不允许直接调用 raw public API：其返回形态不是 Recovery outcome normalizer）。" <>
            "实际臂 body：" <> correction_compact(Macro.to_string(other))
        ]
    end
  end

  defp correction_body_summary(nil), do: "(无子句)"

  defp correction_body_summary(bodies) when is_list(bodies) do
    bodies
    |> Enum.map(&correction_compact(Macro.to_string(&1)))
    |> Enum.join(" | ")
  end

  # 折行压成单行并显式标注截断（保持诚实：截断处有可见标记，不假装是完整表达式）。
  defp correction_compact(text) do
    compact = text |> String.replace(~r/\s+/, " ") |> String.trim()

    if String.length(compact) > 120,
      do: String.slice(compact, 0, 120) <> " …（已截断）",
      else: compact
  end

  # 【R4】caller 绝不允许把 owner 结果绑定/解构/分支：赋值、case scrutinee、with generator
  # 三种形态全部算违约。识别口径为**精确 owner MFA**，不是同名任意 arity。
  defp correction_owner_result_bindings(nil, _owner_mfa), do: []

  defp correction_owner_result_bindings(bodies, owner_mfa) when is_list(bodies) do
    Enum.flat_map(bodies, fn body ->
      collect_nodes(body, fn
        {:=, _meta, [_lhs, rhs]} ->
          correction_exact_local_calls(rhs, owner_mfa) != []

        {:<-, _meta, [_pattern, rhs]} ->
          correction_exact_local_calls(rhs, owner_mfa) != []

        {:case, _meta, [scrutinee, blocks]} when is_list(blocks) ->
          correction_exact_local_calls(scrutinee, owner_mfa) != []

        _node ->
          false
      end)
    end)
  end

  # 定位 scrutinee/generator **恰为** merge_failure/3 调用的 case/with，抽出它的成功臂与
  # 非成功臂。返回
  # `%{kind:, success_arms: [{label, bound_var, body}], non_success_arms: [{label, body}]}`。
  # 【R4】改为**逐子句**评估：owner 的每一个子句都必须自带合格的因果构造。
  # ── 【R6】canonical merge case grammar ──
  #
  # 这是本 oracle 的**唯一**被承认形态，也是它唯一声称能证明的东西。它刻意很窄：
  #
  #     <owner clause body> ::= case <exact PublishedProof.merge_failure/3 call> do
  #                               {:ok, merged_var}      -> continuation.(merged_var)
  #                               {:error, reason_pat}   -> <preserving direct call>
  #                             end
  #
  # 约束：body **本身**就是该 case（不是 block 尾项、无前置/后置表达式、无嵌套诱饵）；
  # scrutinee **本身**就是精确 remote MFA 调用；恰好两臂且顺序固定；两臂均无 guard；
  # 两臂 body 均为**单一直接调用**。
  #
  # 采用固定 grammar 而不是通用 AST/数据流分析，是 R6 的架构裁决：R2–R5 逐洞加固的
  # 「找构造 → 追绑定 → 判尾部」路线每次都还能被新的包装形态绕过。窄 grammar 把
  # sequence 伪造、nested decoy、continuation/merged 重绑、guard、catch-all、多余臂、
  # early throw 这些形态**按构造**一次性排除，代价是只承认这一种写法。
  #
  # 返回 `{:ok, %{ok_identity:, ok_body:, error_body:}}` 或 `{:error, reason}`。
  defp correction_canonical_case(nil, _aliases), do: {:error, "子句没有 body"}

  defp correction_canonical_case({:case, _meta, [scrutinee, blocks]}, aliases)
       when is_list(blocks) do
    arms = Keyword.get(blocks, :do, [])

    cond do
      not correction_exact_remote_call?(scrutinee, aliases, @correction_merge_failure_mfa) ->
        {:error, "case scrutinee 本身不是精确 `Maxio.Storage.PublishedProof.merge_failure/3` 调用"}

      length(arms) != 2 ->
        {:error, "case 必须恰好两臂（实际 #{length(arms)} 臂），不允许 catch-all 或额外臂"}

      true ->
        {_dot, _cm, scrutinee_args} = scrutinee
        correction_canonical_arms(arms, scrutinee_args)
    end
  end

  defp correction_canonical_case({:with, _meta, _args}, _aliases),
    do: {:error, "canonical grammar 只承认 direct case，不支持 `with`"}

  defp correction_canonical_case(_node, _aliases),
    do: {:error, "body 本身不是一个 direct `case`（不接受 block 尾项/前置或后置表达式）"}

  defp correction_canonical_arms([first, second], scrutinee_args) do
    with {:ok, ok_identity, ok_body} <- correction_canonical_ok_arm(first),
         {:ok, error_identity, error_body} <- correction_canonical_error_arm(second) do
      {:ok,
       %{
         ok_identity: ok_identity,
         ok_body: ok_body,
         error_identity: error_identity,
         error_body: error_body,
         scrutinee_args: scrutinee_args
       }}
    end
  end

  defp correction_canonical_ok_arm({:->, _meta, [[pattern], body]}) do
    case correction_canonical_ok_pattern(pattern) do
      nil ->
        {:error,
         "第一臂必须是无 guard 的精确 `{:ok, merged_variable}` 模式，实际：" <>
           correction_compact(Macro.to_string(pattern))}

      identity ->
        {:ok, identity, body}
    end
  end

  defp correction_canonical_ok_arm(_clause), do: {:error, "第一臂形态非法（可能带 guard）"}

  defp correction_canonical_error_arm({:->, _meta, [[pattern], body]}) do
    case correction_canonical_error_identity(pattern) do
      nil ->
        {:error,
         "第二臂必须是无 guard 的精确 `{:error, reason}` 模式且 reason 为严格普通变量" <>
           "（不允许 catch-all / 窄字面量），实际：" <> correction_compact(Macro.to_string(pattern))}

      identity ->
        {:ok, identity, body}
    end
  end

  defp correction_canonical_error_arm(_clause), do: {:error, "第二臂形态非法（可能带 guard）"}

  # caller 侧：对 `owner` 调用结果持有的**本地拒绝/错误分支**（case 非成功臂 + with else）。
  defp correction_owner_error_arms(nil, _owner), do: []

  defp correction_owner_error_arms(bodies, owner) when is_list(bodies) do
    Enum.flat_map(bodies, fn body ->
      {_ast, found} =
        Macro.prewalk(body, [], fn node, acc ->
          {node, acc ++ correction_owner_error_arms_of(node, owner)}
        end)

      found
    end)
  end

  defp correction_owner_error_arms_of({:case, _meta, [scrutinee, blocks]}, owner_mfa)
       when is_list(blocks) do
    if correction_exact_local_calls(scrutinee, owner_mfa) != [] do
      blocks
      |> Keyword.get(:do, [])
      |> Enum.reject(fn
        # 成功臂 = 无 guard 的 `{:ok, _}` 模式；其余（含 guard 形态、catch-all）都算
        # caller 本地拒绝/错误分支，作为 direct-body 权威之外的额外证据保留。
        {:->, _m, [[{:ok, _value}], _body]} -> true
        _clause -> false
      end)
      |> Enum.map(&Macro.to_string/1)
    else
      []
    end
  end

  defp correction_owner_error_arms_of({:with, _meta, args}, owner_mfa) when is_list(args) do
    {generators, blocks} = Enum.split_while(args, &(not is_list(&1)))

    routes? =
      Enum.any?(generators, fn
        {:<-, _m, [_pattern, rhs]} -> correction_exact_local_calls(rhs, owner_mfa) != []
        _node -> false
      end)

    if routes? do
      blocks |> List.flatten() |> Keyword.get(:else, []) |> Enum.map(&Macro.to_string/1)
    else
      []
    end
  end

  defp correction_owner_error_arms_of(_node, _owner_mfa), do: []

  # caller 自行构造的拒绝 tag：`{:merge_rejected, _}` 或任何 `{:error, _}` 字面量。
  defp correction_rejection_tags(nil), do: []

  defp correction_rejection_tags(bodies) when is_list(bodies) do
    Enum.flat_map(bodies, fn body ->
      collect_nodes(body, fn
        {:merge_rejected, _value} -> true
        {:error, _value} -> true
        {:{}, _meta, [tag | _rest]} when tag in [:merge_rejected, :error] -> true
        _node -> false
      end)
    end)
  end

  # 【R4】合成对照样本：完整 module（带与生产同源的 alias 指令），因此精确锚点、
  # tail-return、续延 seam 与 caller 契约四套探测器都能在**真实语法环境**下被正/负标定。
  # 一律构建**精确本地 MFA 索引**，绝不再暴露 name-only 视图。
  defp correction_synthetic(sample) do
    ast = sample |> correction_synthetic_source() |> Code.string_to_quoted!()

    %{
      ast: ast,
      aliases: correction_alias_prelude(ast),
      index: correction_local_index(ast)
    }
  end

  defp correction_synthetic_module(body) do
    """
    defmodule SyntheticSample do
      alias Maxio.ObjectMutation
      alias Maxio.ObjectMutation.Log
      alias Maxio.Storage.PublishedProof

    #{body}
    end
    """
  end

  # 【R7 / D】唯一 GOOD preserving fixture 是**真实 wrapper 形态**：direct case、
  # scrutinee 参数链 `(journal, code, journal_opts(opts))`、两个无 guard ok/error 臂、
  # 精确尾部形状。R6 的 fixture 直接返回 raw public API 结果，把它称作完整 Recovery seam
  # 是过强的。
  defp correction_synthetic_good_preserving do
    """
      @stable_journal_convergence_failed "object_mutation:journal_convergence_failed"
      @stable_proof_contract_violation "published_proof_contract_violation:proof"
      @stable_finalize_contract_violation "published_proof_contract_violation:finalize"

      defp journal_opts(opts), do: opts

      defp synthetic_preserving(journal, code, opts) do
        case ObjectMutation.quarantine_preserving_evidence(journal, code, journal_opts(opts)) do
          {:ok, quarantined} ->
            Log.error("quarantined", code)
            {:ok, :quarantined, quarantined}

          {:error, reason} ->
            {:error, @stable_journal_convergence_failed}
        end
      end
    """
  end

  # 【R7 / C】GOOD owner 固定为 arity 6、续延 position 5、参数链完整。
  # 返回**未包模块**的文本，供与 caller 片段组合。
  defp correction_synthetic_good_adapter do
    correction_synthetic_owner_text("""
          case PublishedProof.merge_failure(target_phase, journal.recovery_evidence, summary) do
            {:ok, merged} -> continuation.(merged)
            {:error, _reason} -> synthetic_preserving(journal, pg_contract_code(mode), opts)
          end
    """)
  end

  # 【R7】owner BAD 样本共用的 canonical head（arity 6、续延 pos 5）与合格 preserving，
  # 这样每个样本**只隔离自身那一个缺陷**，标签与被测缺陷一一对应。
  # `_with_body/1` 直接产出**完整模块**（含 alias prelude），`_text/1` 只产出函数片段。
  defp correction_synthetic_owner_with_body(body),
    do: correction_synthetic_module(correction_synthetic_owner_text(body))

  defp correction_synthetic_owner_text(body) do
    correction_synthetic_good_preserving() <>
      """
        defp pg_contract_code(:proof), do: @stable_proof_contract_violation
        defp pg_contract_code(:finalize), do: @stable_finalize_contract_violation

        defp synthetic_adapter(journal, target_phase, summary, mode, opts, continuation) do
      #{body}
        end
      """
  end

  # 【R7 / A BAD】同一 short alias 同时绑定 Fake 与真实模块 → 歧义，不得展开。
  defp correction_synthetic_source(:alias_conflict_fake_and_real) do
    """
    defmodule SyntheticSample do
      alias Fake.PublishedProof
      alias Maxio.Storage.PublishedProof

      defp synthetic_adapter(journal, target_phase, summary) do
        PublishedProof.merge_failure(target_phase, journal.recovery_evidence, summary)
      end
    end
    """
  end

  # 【R7 amendment BAD】alias target 未按当时环境归一：`alias Fake, as: Maxio` 之后的
  # `alias Maxio.Storage.PublishedProof` 语义上是 `Fake.Storage.PublishedProof`。
  defp correction_synthetic_source(:alias_sequential_fake_root) do
    """
    defmodule SyntheticSample do
      alias Fake, as: Maxio
      alias Maxio.Storage.PublishedProof

      defp synthetic_adapter(journal, target_phase, summary) do
        PublishedProof.merge_failure(target_phase, journal.recovery_evidence, summary)
      end
    end
    """
  end

  # 【R7 amendment GOOD】`Elixir.` 绝对根必须被剥离并正确命中真实模块。
  defp correction_synthetic_source(:alias_absolute_elixir_root) do
    """
    defmodule SyntheticSample do
      alias Elixir.Maxio.Storage.PublishedProof

      defp synthetic_adapter(journal, target_phase, summary) do
        PublishedProof.merge_failure(target_phase, journal.recovery_evidence, summary)
      end
    end
    """
  end

  # 【R7 / A BAD】真实模块的 alias 出现在函数体内 / prelude 之后的 decoy 位置。
  defp correction_synthetic_source(:alias_after_prelude_decoy) do
    """
    defmodule SyntheticSample do
      defp synthetic_adapter(journal, target_phase, summary) do
        alias Maxio.Storage.PublishedProof
        PublishedProof.merge_failure(target_phase, journal.recovery_evidence, summary)
      end

      alias Maxio.Storage.PublishedProof
    end
    """
  end

  # 【R7 / B BAD】成功 binder 与续延 head 形参同 identity：`{:ok, continuation} ->
  # continuation.(continuation)` 会因模式遮蔽看起来合规。
  defp correction_synthetic_source(:identity_collision_ok_binder) do
    correction_synthetic_owner_with_body("""
          case PublishedProof.merge_failure(target_phase, journal.recovery_evidence, summary) do
            {:ok, continuation} -> continuation.(continuation)
            {:error, _reason} -> synthetic_preserving(journal, pg_contract_code(mode), opts)
          end
    """)
  end

  # 【R7 / B BAD】成功 binder 是 special form `__MODULE__` 而非严格普通变量。
  defp correction_synthetic_source(:ok_binder_special_form) do
    correction_synthetic_owner_with_body("""
          case PublishedProof.merge_failure(target_phase, journal.recovery_evidence, summary) do
            {:ok, __MODULE__} -> continuation.(__MODULE__)
            {:error, _reason} -> synthetic_preserving(journal, pg_contract_code(mode), opts)
          end
    """)
  end

  # 【R7 / B BAD】owner head 的续延位是 special form（可 parse 的等价 AST fixture），
  # 而不是严格普通变量。
  defp correction_synthetic_source(:head_special_form_continuation) do
    (correction_synthetic_good_preserving() <>
       """
         defp pg_contract_code(:proof), do: @stable_proof_contract_violation
        defp pg_contract_code(:finalize), do: @stable_finalize_contract_violation

         defp synthetic_adapter(journal, target_phase, summary, mode, opts, __STACKTRACE__) do
           case PublishedProof.merge_failure(target_phase, journal.recovery_evidence, summary) do
             {:ok, merged} -> __STACKTRACE__.(merged)
             {:error, _reason} -> synthetic_preserving(journal, pg_contract_code(mode), opts)
           end
         end
       """)
    |> correction_synthetic_module()
  end

  # 【R7 / B BAD】error binder 是窄字面量，只覆盖单一 reason。
  defp correction_synthetic_source(:narrow_error_literal) do
    correction_synthetic_owner_with_body("""
          case PublishedProof.merge_failure(target_phase, journal.recovery_evidence, summary) do
            {:ok, merged} -> continuation.(merged)
            {:error, :only_this_reason} -> synthetic_preserving(journal, pg_contract_code(mode), opts)
          end
    """)
  end

  # 【R7 / C BAD】scrutinee 实参被伪造：target 用字面量、evidence 取错字段、summary 换变量。
  defp correction_synthetic_source(:owner_scrutinee_forged_args) do
    correction_synthetic_owner_with_body("""
          case PublishedProof.merge_failure("forged", journal.published_fingerprint, mode) do
            {:ok, merged} -> continuation.(merged)
            {:error, _reason} -> synthetic_preserving(journal, pg_contract_code(mode), opts)
          end
    """)
  end

  # 【R7 / C BAD】拒绝臂 preserving 实参被伪造：错 journal、code 用字面量、opts 用 []。
  defp correction_synthetic_source(:owner_preserving_forged_args) do
    correction_synthetic_owner_with_body("""
          case PublishedProof.merge_failure(target_phase, journal.recovery_evidence, summary) do
            {:ok, merged} -> continuation.(merged)
            {:error, _reason} -> synthetic_preserving(summary, :forged_code, [])
          end
    """)
  end

  # 【R7 / C BAD】拒绝臂直接调用 raw public API（返回形态不是 Recovery outcome normalizer）。
  defp correction_synthetic_source(:owner_error_raw_public_api) do
    correction_synthetic_owner_with_body("""
          case PublishedProof.merge_failure(target_phase, journal.recovery_evidence, summary) do
            {:ok, merged} -> continuation.(merged)
            {:error, _reason} ->
              ObjectMutation.quarantine_preserving_evidence(journal, pg_contract_code(mode), opts)
          end
    """)
  end

  # 【R7 / D BAD】preserving helper 是 `public_call; :forged` block —— 含 API 调用但返回伪造值。
  defp correction_synthetic_source(:preserving_trailing_forged) do
    correction_synthetic_module("""
      defp journal_opts(opts), do: opts

      defp synthetic_preserving(journal, code, opts) do
        ObjectMutation.quarantine_preserving_evidence(journal, code, journal_opts(opts))
        :forged
      end
    """)
  end

  # 【R7 amendment 3 BAD】preserving helper 形态完全合规，但成功臂尾部返回**伪造 tag**
  # `{:forged, quarantined}`。通用「尾部用到了 binder」会放过它；精确尾部形状必须拒绝。
  defp correction_synthetic_source(:preserving_forged_tail) do
    correction_synthetic_module("""
      @stable_journal_convergence_failed "object_mutation:journal_convergence_failed"

      defp journal_opts(opts), do: opts

      defp synthetic_preserving(journal, code, opts) do
        case ObjectMutation.quarantine_preserving_evidence(journal, code, journal_opts(opts)) do
          {:ok, quarantined} -> {:forged, quarantined}
          {:error, reason} -> {:error, @stable_journal_convergence_failed}
        end
      end
    """)
  end

  # 【R7 / D BAD】preserving helper 是 direct case，但 public call 的三个实参全被伪造
  # （错 journal / 错 code / `[]`）。
  defp correction_synthetic_source(:preserving_forged_public_args) do
    correction_synthetic_module("""
      defp journal_opts(opts), do: opts

      defp synthetic_preserving(journal, code, opts) do
        case ObjectMutation.quarantine_preserving_evidence(code, :forged_code, []) do
          {:ok, quarantined} -> {:ok, :quarantined, quarantined}
          {:error, reason} -> {:error, {:journal_convergence_failed, reason}}
        end
      end
    """)
  end

  # 【R7.1 / gap 5 GOOD】精确宿主 MFA 承载正确数量与字面量的 callsite。
  defp correction_synthetic_source(:callsite_exact_hosts) do
    correction_synthetic_module("""
      defp apply_pg_proof_disposition(a, b, c, d) do
        pg_merged_pending_retry(j, s, k, :proof, o)
        pg_merged_terminal(j, s, k, x, :proof, o)
        pg_merged_quarantine(j, s, k, :proof, o)
      end

      defp apply_pg_finalize_disposition(a, b, c) do
        pg_merged_pending_retry(j, s, k, :finalize, o)
        pg_merged_terminal(j, s, k, x, :finalize, o)
        pg_merged_quarantine(j, s, k, :finalize, o)
        pg_merged_pending_retry(j, s, k, :finalize, o)
      end
    """)
  end

  # 【R7.1 / gap 5 BAD】真实宿主内的 callsite 被移除，改由**同名不同 arity** 的 decoy 宿主
  # 承载"正确数量"。按裸名字分组会通过；按精确 MFA 分组必须失败（数量为 0 + stray）。
  defp correction_synthetic_source(:callsite_wrong_arity_decoy_host) do
    correction_synthetic_module("""
      defp apply_pg_proof_disposition(a, b, c, d), do: :moved

      defp apply_pg_proof_disposition(a, b, c) do
        pg_merged_pending_retry(j, s, k, :proof, o)
        pg_merged_terminal(j, s, k, x, :proof, o)
        pg_merged_quarantine(j, s, k, :proof, o)
      end

      defp apply_pg_finalize_disposition(a, b, c) do
        pg_merged_pending_retry(j, s, k, :finalize, o)
        pg_merged_terminal(j, s, k, x, :finalize, o)
        pg_merged_quarantine(j, s, k, :finalize, o)
        pg_merged_pending_retry(j, s, k, :finalize, o)
      end
    """)
  end

  # 【R7.1 / gap 1 BAD】merge arg1 是**带括号**的零元调用 `journal.recovery_evidence()`，
  # 语义上是函数调用而非字段读取。
  defp correction_synthetic_source(:merge_arg_parens_call) do
    correction_synthetic_owner_with_body("""
          case PublishedProof.merge_failure(target_phase, journal.recovery_evidence(), summary) do
            {:ok, merged} -> continuation.(merged)
            {:error, _reason} -> synthetic_preserving(journal, pg_contract_code(mode), opts)
          end
    """)
  end

  # 【R7.1 / gap 6 BAD】ok binder 复用 head 的 `journal`：绑定的虽然是 merge 结果，但遮蔽了
  # head 参数，位置来源有歧义且臂内失去对原参数的访问。
  defp correction_synthetic_source(:ok_binder_shadows_head_journal) do
    correction_synthetic_owner_with_body("""
          case PublishedProof.merge_failure(target_phase, journal.recovery_evidence, summary) do
            {:ok, journal} -> continuation.(journal)
            {:error, _reason} -> synthetic_preserving(journal, pg_contract_code(mode), opts)
          end
    """)
  end

  # 【R7.1 / gap 2 BAD】preserving 成功臂 prelude 是 `throw(:forged)` 而非白名单里的
  # `Log.error/2`，尾部仍是 exact tuple。
  defp correction_synthetic_source(:preserving_throw_prelude) do
    correction_synthetic_module("""
      @stable_journal_convergence_failed "object_mutation:journal_convergence_failed"

      defp journal_opts(opts), do: opts

      defp synthetic_preserving(journal, code, opts) do
        case ObjectMutation.quarantine_preserving_evidence(journal, code, journal_opts(opts)) do
          {:ok, quarantined} ->
            throw(:forged)
            {:ok, :quarantined, quarantined}

          {:error, reason} ->
            {:error, @stable_journal_convergence_failed}
        end
      end
    """)
  end

  # 【R7.1 / gap 3 BAD】mapper 多出一个 `_other` catchall 第三子句。
  defp correction_synthetic_source(:mapper_extra_catchall) do
    correction_synthetic_module("""
      @stable_proof_contract_violation "published_proof_contract_violation:proof"
      @stable_finalize_contract_violation "published_proof_contract_violation:finalize"

      defp pg_contract_code(:proof), do: @stable_proof_contract_violation
      defp pg_contract_code(:finalize), do: @stable_finalize_contract_violation
      defp pg_contract_code(_other), do: @stable_proof_contract_violation
    """)
  end

  # 【R7.1 / gap 4 BAD】caller 唯一 clause 带 guard。
  defp correction_synthetic_source(:caller_guarded_clause) do
    correction_synthetic_module(
      correction_synthetic_good_adapter() <>
        """
          defp synthetic_caller(journal, summary, code, mode, opts) when is_map(journal) do
            synthetic_adapter(journal, "finalized", summary, mode, opts, fn merged ->
              conclude(journal, "finalized", merged, code, opts)
            end)
          end
        """
    )
  end

  # 【R7.1 / gap 4 BAD】续延位置传的 fn binder 是字面量。
  defp correction_synthetic_source(:caller_fn_literal_binder) do
    correction_synthetic_module(
      correction_synthetic_good_adapter() <>
        """
          defp synthetic_caller(journal, summary, code, mode, opts) do
            synthetic_adapter(journal, "finalized", summary, mode, opts, fn :forged ->
              conclude(journal, "finalized", :forged, code, opts)
            end)
          end
        """
    )
  end

  # 【R7.1 / gap 4 BAD】续延 fn 带 guard。
  defp correction_synthetic_source(:caller_fn_guarded) do
    correction_synthetic_module(
      correction_synthetic_good_adapter() <>
        """
          defp synthetic_caller(journal, summary, code, mode, opts) do
            synthetic_adapter(journal, "finalized", summary, mode, opts, fn merged
                                                                           when is_map(merged) ->
              conclude(journal, "finalized", merged, code, opts)
            end)
          end
        """
    )
  end

  # 【R7.1 / gap 4 BAD】续延 fn 有多个子句。
  defp correction_synthetic_source(:caller_fn_multi_clause) do
    correction_synthetic_module(
      correction_synthetic_good_adapter() <>
        """
          defp synthetic_caller(journal, summary, code, mode, opts) do
            synthetic_adapter(journal, "finalized", summary, mode, opts, fn
              nil -> :skipped
              merged -> conclude(journal, "finalized", merged, code, opts)
            end)
          end
        """
    )
  end

  # 【R7.1 / gap 4 BAD】续延 fn binder 与 caller head 的 `summary` 同 identity（不 fresh）。
  defp correction_synthetic_source(:caller_fn_binder_shadows_head) do
    correction_synthetic_module(
      correction_synthetic_good_adapter() <>
        """
          defp synthetic_caller(journal, summary, code, mode, opts) do
            synthetic_adapter(journal, "finalized", summary, mode, opts, fn summary ->
              conclude(journal, "finalized", summary, code, opts)
            end)
          end
        """
    )
  end

  # 【R7 amendment 4 BAD】mapper 形态正确但返回**任意属性 / 等值字符串字面量**，
  # 而不是精确的 `@stable_proof_contract_violation` / `@stable_finalize_contract_violation`。
  defp correction_synthetic_source(:arbitrary_mapper_codes) do
    correction_synthetic_module("""
      @some_other_code "published_proof_contract_violation:proof"

      defp pg_contract_code(:proof), do: @some_other_code
      defp pg_contract_code(:finalize), do: "published_proof_contract_violation:finalize"
    """)
  end

  # 【R7 / E BAD】caller 直接调用 owner，但前五实参里 journal 与 mode 被伪造/错位。
  defp correction_synthetic_source(:caller_forged_owner_args) do
    correction_synthetic_module(
      correction_synthetic_good_adapter() <>
        """
          defp synthetic_caller(journal, summary, code, mode, opts) do
            synthetic_adapter(summary, "forged", journal, :proof, opts, fn merged ->
              conclude(journal, "finalized", merged, code, mode, opts)
            end)
          end
        """
    )
  end

  # 控制 1（GOOD）：精确本地 preserving MFA + 合规成功续延 + caller 传显式一元 fn。
  defp correction_synthetic_source(:good_full_seam) do
    correction_synthetic_module(
      correction_synthetic_good_adapter() <>
        """
          defp synthetic_caller(journal, summary, code, mode, opts) do
            synthetic_adapter(journal, "finalized", summary, mode, opts, fn merged ->
              conclude(journal, "finalized", merged, code, opts)
            end)
          end
        """
    )
  end

  # 【R6 BAD】非 canonical 的 `with` seam。R5 曾把它当作 GOOD；R6 的架构裁决是
  # canonical grammar **只承认 direct case**，因此它现在是明确的 BAD control：
  # 即使 generator RHS 是精确 remote 调用，`with` 也不在被承认的形态内。
  defp correction_synthetic_source(:noncanonical_with_seam) do
    correction_synthetic_owner_with_body("""
          with {:ok, merged} <-
                 PublishedProof.merge_failure(target_phase, journal.recovery_evidence, summary) do
            continuation.(merged)
          else
            {:error, _reason} -> synthetic_preserving(journal, pg_contract_code(mode), opts)
          end
    """)
  end

  # 【R6 / static I1 BAD】`with` 用合规 generator 取得 merged 后，再用**第二个 generator**
  # 把 merged 重绑为伪造值。canonical grammar 不承认 `with`，因此被 grammar 直接拒绝。
  defp correction_synthetic_source(:with_second_generator_rebind) do
    correction_synthetic_owner_with_body("""
          with {:ok, merged} <-
                 PublishedProof.merge_failure(target_phase, journal.recovery_evidence, summary),
               {:ok, merged} <- {:ok, :forged} do
            continuation.(merged)
          else
            {:error, _reason} -> synthetic_preserving(journal, pg_contract_code(mode), opts)
          end
    """)
  end

  # 【R6 / static I2 BAD】owner body 是 `throw(:early); canonical_case` 的 block。
  # canonical case 本身完全合规，唯一违例是 body 不是 direct case。
  defp correction_synthetic_source(:owner_early_throw_then_canonical) do
    correction_synthetic_owner_with_body("""
          throw(:early)

          case PublishedProof.merge_failure(target_phase, journal.recovery_evidence, summary) do
            {:ok, merged} -> continuation.(merged)
            {:error, _reason} -> synthetic_preserving(journal, pg_contract_code(mode), opts)
          end
    """)
  end

  # 【R6 / static I3 BAD】成功臂带 guard，且第二臂是 catch-all preserving。
  defp correction_synthetic_source(:guarded_success_catchall) do
    correction_synthetic_owner_with_body("""
          case PublishedProof.merge_failure(target_phase, journal.recovery_evidence, summary) do
            {:ok, merged} when is_map(merged) -> continuation.(merged)
            _other -> synthetic_preserving(journal, pg_contract_code(mode), opts)
          end
    """)
  end

  # 【R6 / static I3 BAD】前置 catch-all 臂遮蔽成功臂（顺序违例 + 三臂）。
  defp correction_synthetic_source(:leading_catchall_shadows_success) do
    correction_synthetic_owner_with_body("""
          case PublishedProof.merge_failure(target_phase, journal.recovery_evidence, summary) do
            _shadow -> synthetic_preserving(journal, pg_contract_code(mode), opts)
            {:ok, merged} -> continuation.(merged)
            {:error, _reason} -> synthetic_preserving(journal, pg_contract_code(mode), opts)
          end
    """)
  end

  # 【R5 / I1 BAD】`case` scrutinee 是「先调用 merge_failure，再丢弃它并伪造 {:ok, :forged}」
  # 的序列块。merge 结果被丢弃、拒绝臂不可达；R4 的「子树包含」口径会 false-pass。
  defp correction_synthetic_source(:causal_case_sequence_forged) do
    correction_synthetic_owner_with_body("""
          case (
                 PublishedProof.merge_failure(target_phase, journal.recovery_evidence, summary)
                 {:ok, :forged}
               ) do
            {:ok, merged} -> continuation.(merged)
            {:error, _reason} -> synthetic_preserving(journal, pg_contract_code(mode), opts)
          end
    """)
  end

  # 【R5 / I1 BAD】`with` generator 的 RHS 是同样的序列块伪造形态。
  defp correction_synthetic_source(:causal_with_sequence_forged) do
    correction_synthetic_owner_with_body("""
          with {:ok, merged} <-
                 (
                   PublishedProof.merge_failure(target_phase, journal.recovery_evidence, summary)
                   {:ok, :forged}
                 ) do
            continuation.(merged)
          else
            {:error, _reason} -> synthetic_preserving(journal, pg_contract_code(mode), opts)
          end
    """)
  end

  # 【R5 / I1 BAD 诱饵】body 里先放一个**完全合规**的 merge case（scrutinee 直连、成功臂
  # tail-call 续延、拒绝臂 tail-return preserving），随后用一个伪造尾表达式覆盖返回值。
  # prewalk 口径会命中那个诱饵并判定合规；tail-only 口径必须拒绝。
  defp correction_synthetic_source(:causal_decoy_inner_then_forged_tail) do
    correction_synthetic_owner_with_body("""
          case PublishedProof.merge_failure(target_phase, journal.recovery_evidence, summary) do
            {:ok, merged} -> continuation.(merged)
            {:error, _reason} -> synthetic_preserving(journal, pg_contract_code(mode), opts)
          end

          {:ok, :forged}
    """)
  end

  # 【R5 / I2 BAD】成功臂里把续延形参**赋值重绑定**成伪造 fn 后再调用它。
  # R4 只比裸 name，因此会 false-pass。
  defp correction_synthetic_source(:continuation_rebound_assign) do
    correction_synthetic_owner_with_body("""
          case PublishedProof.merge_failure(target_phase, journal.recovery_evidence, summary) do
            {:ok, merged} ->
              continuation = fn _ -> :forged end
              continuation.(merged)

            {:error, _reason} ->
              synthetic_preserving(journal, pg_contract_code(mode), opts)
          end
    """)
  end

  # 【R5 BAD】prelude 里调一次 continuation 充数，tail-case 只留拒绝/catch-all preserving 臂。
  # 没有成功臂 ⇒ 成功续延契约被整体跳过；必须由「success_arms 非空」显式拦截。
  defp correction_synthetic_source(:owner_no_success_arm) do
    correction_synthetic_owner_with_body("""
          _ = continuation.(journal)

          case PublishedProof.merge_failure(target_phase, journal.recovery_evidence, summary) do
            {:error, _reason} -> synthetic_preserving(journal, pg_contract_code(mode), opts)
            _other -> synthetic_preserving(journal, pg_contract_code(mode), opts)
          end
    """)
  end

  # 【R5 / I2 BAD】成功臂里把 **merge 结果**赋值重绑定成伪造值后再交给续延。
  # 续延形参本身没被动，因此只有对 merged identity 的绑定扫描才能拦住它。
  defp correction_synthetic_source(:merged_rebound_assign) do
    correction_synthetic_owner_with_body("""
          case PublishedProof.merge_failure(target_phase, journal.recovery_evidence, summary) do
            {:ok, merged} ->
              merged = :forged
              continuation.(merged)

            {:error, _reason} ->
              synthetic_preserving(journal, pg_contract_code(mode), opts)
          end
    """)
  end

  # 【R6 / M1 BAD】成功臂 body 是 block：先有一段 nested-fn / shadow prelude，**最后一句
  # 仍然是** `continuation.(merged)`。
  #
  # 这个 control 的唯一被测缺陷因此是明确且单一的：**arm body 不是单一直接调用**
  # （含 prelude）。它**不**用来声称探测器做了通用 shadow/capture 分析——R5 曾这样
  # 表述，属于过强。在 canonical grammar 下，任何 prelude 都被按构造拒绝，无论其内容。
  defp correction_synthetic_source(:success_arm_prelude_then_call) do
    correction_synthetic_owner_with_body("""
          case PublishedProof.merge_failure(target_phase, journal.recovery_evidence, summary) do
            {:ok, merged} ->
              _shadow = fn continuation -> continuation.(:forged) end
              continuation.(merged)

            {:error, _reason} ->
              synthetic_preserving(journal, pg_contract_code(mode), opts)
          end
    """)
  end

  # 控制 2（BAD）：preserving /3 合格，但拒绝臂 tail-call **同名 /1** 的非 preserving 重载。
  # `/3` 的资格绝不允许授权 `/1`。
  defp correction_synthetic_source(:preserving_overload) do
    correction_synthetic_module(
      correction_synthetic_good_preserving() <>
        """
          defp synthetic_preserving(journal) do
            {:merge_rejected, journal}
          end

          defp pg_contract_code(:proof), do: @stable_proof_contract_violation
          defp pg_contract_code(:finalize), do: @stable_finalize_contract_violation

          defp synthetic_adapter(journal, target_phase, summary, mode, opts, continuation) do
            case PublishedProof.merge_failure(target_phase, journal.recovery_evidence, summary) do
              {:ok, merged} -> continuation.(merged)
              {:error, _reason} -> synthetic_preserving(journal)
            end
          end
        """
    )
  end

  # 【R6 / static I2 BAD】caller body 是 `throw(:early); owner(...fn...)` 的 block。
  # owner 调用与续延实参本身完全合规，唯一违例是 body 不是 direct call。
  defp correction_synthetic_source(:caller_early_throw_then_owner) do
    correction_synthetic_module(
      correction_synthetic_good_adapter() <>
        """
          defp synthetic_caller(journal, summary, code, mode, opts) do
            throw(:early)

            synthetic_adapter(journal, "finalized", summary, mode, opts, fn merged ->
              conclude(journal, "finalized", merged, code, opts)
            end)
          end
        """
    )
  end

  # 控制 3（BAD）：caller tail-call 的是**同名不同 arity** 的 owner 重载。
  defp correction_synthetic_source(:owner_overload_caller) do
    correction_synthetic_module(
      correction_synthetic_good_adapter() <>
        """
          defp synthetic_adapter(journal, target_phase, summary) do
            {:merge_rejected, journal}
          end

          defp synthetic_caller(journal, summary, code, mode, opts) do
            synthetic_adapter(journal, "finalized", summary)
          end
        """
    )
  end

  # 控制 4（BAD，保留自 R3）：含有 preserving 调用但尾部换成替代 tag。
  defp correction_synthetic_source(:contains_then_alternate_tag) do
    correction_synthetic_owner_with_body("""
          case PublishedProof.merge_failure(target_phase, journal.recovery_evidence, summary) do
            {:ok, merged} ->
              continuation.(merged)

            {:error, _reason} ->
              result = synthetic_preserving(journal, pg_contract_code(mode), opts)
              {:handled, result}
          end
    """)
  end

  # 控制 5（BAD）：adapter 完全没有续延参数，成功行为被它自己吸收（inline）。
  # 这正是冻结生产 `pg_merge/3` 的形态族。
  defp correction_synthetic_source(:owner_no_continuation) do
    correction_synthetic_module("""
      defp synthetic_preserving(journal, code, opts) do
        ObjectMutation.quarantine_preserving_evidence(journal, code, opts)
      end

      defp synthetic_adapter(journal, target_phase, summary, opts) do
        case PublishedProof.merge_failure(target_phase, journal.recovery_evidence, summary) do
          {:ok, merged} -> conclude(journal, "finalized", merged, opts)
          {:error, _reason} -> synthetic_preserving(journal, code, opts)
        end
      end
    """)
  end

  # 控制 6（BAD）：声明了续延参数，但成功臂没有用 merged 去 tail-call 它。
  defp correction_synthetic_source(:owner_success_not_continuation) do
    correction_synthetic_module("""
      defp synthetic_preserving(journal, code, opts) do
        ObjectMutation.quarantine_preserving_evidence(journal, code, opts)
      end

      defp synthetic_adapter(journal, target_phase, summary, opts, continuation) do
        _ = continuation.(journal)

        case PublishedProof.merge_failure(target_phase, journal.recovery_evidence, summary) do
          {:ok, merged} -> {:ok, merged}
          {:error, _reason} -> synthetic_preserving(journal, code, opts)
        end
      end
    """)
  end

  # 控制 7（BAD）：caller tail-call 了精确 owner MFA，但续延位置传的不是显式一元 fn。
  defp correction_synthetic_source(:caller_non_fn_continuation) do
    correction_synthetic_module(
      correction_synthetic_good_adapter() <>
        """
          defp synthetic_caller(journal, summary, code, mode, opts) do
            synthetic_adapter(journal, "finalized", summary, mode, opts, :inline_success)
          end
        """
    )
  end

  # 控制 7b（BAD）：续延位置传的是 arity 错误的 fn。
  defp correction_synthetic_source(:caller_wrong_fn_arity) do
    correction_synthetic_module(
      correction_synthetic_good_adapter() <>
        """
          defp synthetic_caller(journal, summary, code, mode, opts) do
            synthetic_adapter(journal, "finalized", summary, mode, opts, fn merged, extra ->
              conclude(journal, "finalized", merged, extra, code, opts)
            end)
          end
        """
    )
  end

  # 控制 8（BAD，保留自 R3）：caller 先绑定 owner 结果再 case 解释替代 tag。
  defp correction_synthetic_source(:caller_binds_and_branches) do
    correction_synthetic_module(
      correction_synthetic_good_adapter() <>
        """
          defp synthetic_caller(journal, summary, code, mode, opts) do
            result = synthetic_adapter(journal, "finalized", summary, mode, opts, fn m -> m end)

            case result do
              {:ok, merged} -> conclude(journal, "finalized", merged, code, opts)
              {:merge_rejected, original} -> synthetic_preserving(original, code, opts)
            end
          end
        """
    )
  end

  # 控制 8b（BAD，保留自 R3）：caller 用 `with` generator 解构 owner 结果。
  defp correction_synthetic_source(:caller_with_generator) do
    correction_synthetic_module(
      correction_synthetic_good_adapter() <>
        """
          defp synthetic_caller(journal, summary, code, mode, opts) do
            with {:ok, merged} <-
                   synthetic_adapter(journal, "finalized", summary, mode, opts, fn m -> m end) do
              conclude(journal, "finalized", merged, code, opts)
            end
          end
        """
    )
  end

  # 远程锚点负控（保留自 R3）：错误模块的同名同 arity 调用。
  defp correction_synthetic_source(:owner_wrong_module) do
    correction_synthetic_module("""
      defp synthetic_adapter(journal, target_phase, summary, opts) do
        case Fake.merge_failure(target_phase, journal.recovery_evidence, summary) do
          {:ok, merged} -> {:ok, merged}
          {:error, _reason} -> ObjectMutation.quarantine_preserving_evidence(journal, c, opts)
        end
      end
    """)
  end

  # 远程锚点负控（保留自 R3）：正确模块但 arity 错误。
  defp correction_synthetic_source(:owner_wrong_arity) do
    correction_synthetic_module("""
      defp synthetic_adapter(journal, target_phase, summary, opts) do
        case PublishedProof.merge_failure(target_phase, journal.recovery_evidence) do
          {:ok, merged} -> {:ok, merged}
          {:error, _reason} -> ObjectMutation.quarantine_preserving_evidence(journal, c, opts)
        end
      end
    """)
  end

  # preserving 类负控（保留自 R3）：错误模块的同名调用不得进入 preserving MFA 集合。
  defp correction_synthetic_source(:preserving_wrong_module) do
    correction_synthetic_module("""
      defp synthetic_not_preserving(journal, code, opts) do
        Fake.quarantine_preserving_evidence(journal, code, opts)
      end
    """)
  end

  # preserving 类负控（R4 新增）：同一 MFA 的**某个子句**不连公共 API —— 整个 MFA 都不合格，
  # 封死同 MFA 多子句旁路。
  defp correction_synthetic_source(:preserving_clause_bypass) do
    correction_synthetic_module("""
      defp synthetic_preserving(journal, :real, opts) do
        ObjectMutation.quarantine_preserving_evidence(journal, :real, opts)
      end

      defp synthetic_preserving(journal, :bypass, _opts) do
        {:merge_rejected, journal}
      end
    """)
  end

  # 可逃逸的 `{:merge_rejected, _}` 二元 tuple 字面量（AST 里是 2-element tuple 节点）。
  defp correction_merge_rejected_nodes(ast) do
    collect_nodes(ast, fn
      {:merge_rejected, _value} -> true
      {:{}, _meta, [:merge_rejected | _rest]} -> true
      _node -> false
    end)
  end

  # ── G3 Batch A fixtures（§7.5 sentinels）──

  # 带 canonical wrapper 与 fingerprint 的 rollback_pending 行（published → rollback_pending
  # 是 @pg_graph 的合法边）。
  defp pg_rollback_pending_journal(ctx, key) do
    {:ok, journal} = ObjectMutation.prepare(prepare_attrs(ctx, key, 1))
    {:ok, journal} = ObjectMutation.transition(journal, "claimed")

    {:ok, journal} =
      ObjectMutation.transition(journal, "published", %{
        published_fingerprint: @fingerprint,
        recovery_evidence: g3_wrapper("canonical")
      })

    {:ok, pending} = ObjectMutation.transition(journal, "rollback_pending")
    pending
  end

  # 窄口径 update_all：模拟另一个 worker 在 claim 与 renew 之间接管租约。
  defp g3_steal_lease!(journal) do
    {1, _} =
      Repo.update_all(from(j in Journal, where: j.id == ^journal.id),
        set: [
          lease_owner: @g3_lease_thief,
          lease_expires_at: DateTime.add(DateTime.utc_now(), 3600, :second)
        ]
      )

    ObjectMutation.get(journal.id)
  end

  # ── G3 Batch A fixtures（§7.4 races）──

  # 等待脚本 backend 的完整 entered 记录；缺失时给出自解释的 RED 说明而不是裸超时。
  defp g3_await_gate!(ref, label) do
    receive do
      {:script_backend_entered, %{ref: ^ref} = entered} -> entered
    after
      5_000 ->
        flunk(
          "#{label} gate 从未进入：入口 Recovery 在该点不调用对应的 Storage callback，" <>
            "因此这一步不存在可观察的边界"
        )
    end
  end

  # 确定性并发扰动：只 bump attempts，因此手中旧行的精确 attempts CAS 必然落空，
  # 而证据 / fingerprint / phase 全部保持不变（赢家可被逐字比对）。
  defp g3_bump_attempts!(journal) do
    {1, _} = Repo.update_all(from(j in Journal, where: j.id == ^journal.id), inc: [attempts: 1])
    ObjectMutation.get(journal.id)
  end

  defp g3_published_epoch(journal) do
    {:ok, mctx} = MutationContext.from_journal(journal)

    {:ok, epoch} =
      ObjectEpoch.new(mctx.target, mctx.token, %{
        operation: "put",
        phase: "published",
        value_type: "object",
        fingerprint: @fingerprint,
        updated_at: DateTime.utc_now()
      })

    {:ok, epoch}
  end

  # ── G3 Batch A fixtures（§7.3 sidecar matrix）──

  defp sidecar_journal(ctx, key, "published") do
    {:ok, journal} = sidecar_published_journal(ctx, key)
    journal
  end

  defp sidecar_journal(ctx, key, "finalize_pending") do
    {:ok, journal} = sidecar_published_journal(ctx, key)
    {:ok, pending} = ObjectMutation.transition(journal, "finalize_pending")
    pending
  end

  # published entry 必须先让 current-epoch pre-adapter 通过，才谈得上 finalize adapter：
  # 直接把本 token 的 published epoch 写到盘上，让未编排的 current_epoch 委派给 FS。
  defp sidecar_ready_journal(ctx, key, "published") do
    journal = sidecar_journal(ctx, key, "published")
    {:ok, mctx} = MutationContext.from_journal(journal)
    write_epoch!(ctx, mctx, "published", @fingerprint)
    journal
  end

  defp sidecar_ready_journal(ctx, key, "finalize_pending"),
    do: sidecar_journal(ctx, key, "finalize_pending")

  # 窄口径 update_all：只用于构造公开 API 无法表达的「不可能状态」。
  defp g3_seed_row!(journal, sets) do
    {1, _} = Repo.update_all(from(j in Journal, where: j.id == ^journal.id), set: sets)
    {:ok, ObjectMutation.get(journal.id)}
  end

  defp assert_sidecar_counts!(label, current_epoch, finalize) do
    assert Script.call_count(:current_epoch) == current_epoch,
           "#{label}：current_epoch 调用次数必须精确为 #{current_epoch}"

    assert Script.call_count(:finalize_if_current) == finalize,
           "#{label}：finalize_if_current 调用次数必须精确为 #{finalize}"

    assert Script.call_count(:verify_published) == 0,
           "#{label}：sidecar adapter 绝不做独立 verify"

    assert Script.call_count(:restore_if_current) == 0,
           "#{label}：sidecar finalize 路径 restore 恒为 0"
  end

  defp g3_current_epoch_result("missing", _journal), do: {:ok, :absent}

  defp g3_current_epoch_result("unavailable", _journal),
    do: {:error, {:unavailable, @g3_current_epoch_sentinel}}

  # 既非 `:absent` 也非 `%ObjectEpoch{}` 的 obsolete/malformed 结果。
  defp g3_current_epoch_result("contract_violation", _journal),
    do: {:ok, {:obsolete_current_epoch, @g3_current_epoch_sentinel}}

  # 本 token 却处于对 finalize 非法的 phase：journal 与 epoch 互相矛盾。
  defp g3_current_epoch_result("conflict", journal) do
    {:ok, mctx} = MutationContext.from_journal(journal)

    {:ok, epoch} =
      ObjectEpoch.new(mctx.target, mctx.token, %{
        operation: "put",
        phase: "claimed",
        value_type: "object",
        updated_at: DateTime.utc_now()
      })

    {:ok, epoch}
  end

  defp g3_current_epoch_expectation(observed),
    do: {observed, "sidecar_current_epoch:#{observed}"}

  # blueprint §5.2 表：finalize disposition → {目标 phase, 精确稳定 code, outcome, class}
  defp g3_sidecar_expectation("finalized"), do: {"finalized", nil, "finalized", nil}

  defp g3_sidecar_expectation("cleanup_pending"),
    do: {"finalize_pending", "sidecar_finalize:cleanup_pending", "cleanup_pending", nil}

  defp g3_sidecar_expectation("superseded"),
    do: {"finalized", "sidecar_finalize:superseded", "superseded", nil}

  defp g3_sidecar_expectation("unavailable"),
    do: {"finalize_pending", "sidecar_finalize:unavailable", "failed", "unavailable"}

  defp g3_sidecar_expectation("contract_violation"),
    do: {"quarantined", "sidecar_finalize:contract_violation", "contract_violation", nil}

  defp g3_sidecar_expectation(class) when class in @g3_integrity_classes,
    do: {"quarantined", "sidecar_finalize:#{class}", "failed", class}

  # sidecar finalize 结果：在 canonical summary 的 detail 里挂上 marker，用于证明
  # detail 级字段绝不会被投影进有界证据。"code" 属于冻结的 endpoint 键集合且满足
  # safe-text 约束，故结果仍完整通过 Storage validator，不削弱任何校验。
  defp g3_sidecar_finalize_result("cleanup_pending") do
    {:ok, {:cleanup_pending, summary}} =
      PublishedProof.classify_finalize(1, [
        {"ordinal:0", PublishedProof.endpoint_finalized("ordinal:0", %{})},
        {"ordinal:1",
         PublishedProof.endpoint_cleanup_pending("ordinal:1", %{
           code: @g3_sidecar_detail_sentinel
         })}
      ])

    {:ok, {:cleanup_pending, summary}}
  end

  defp g3_sidecar_finalize_result(class)
       when class in @g3_integrity_classes or class == "unavailable" do
    atom = String.to_existing_atom(class)

    {:error, {:published_proof_failed, ^atom, summary}} =
      PublishedProof.classify_finalize(1, [
        {
          "local",
          # 冻结的 PublishedProof 规则：placement_drift 的 detail 必须 `owned == false`，
          # 否则该 detail（连同它的 `code`）不会被接受——sentinel 也就注入不进去。
          PublishedProof.endpoint_finalize_failed(atom, "local", %{
            owned: atom != :placement_drift,
            code: @g3_sidecar_detail_sentinel
          })
        }
      ])

    {:error, {:published_proof_failed, atom, summary}}
  end

  defp g3_sidecar_finalize_result(label), do: g3_finalize_result(label)

  defp g3_summary_of({:ok, {_status, summary}}) when is_map(summary), do: summary

  defp g3_summary_of({:error, {:published_proof_failed, _class, summary}}) when is_map(summary),
    do: summary

  defp g3_summary_of(_term), do: nil

  # §5.2 的**完整**有界投影：12 个基础键，`class` 当且仅当 outcome == "failed"。
  defp g3_sidecar_finalize_evidence(outcome, class, summary) do
    for key <- ~w(mode status required verified finalized debt unavailable omitted orphaned) do
      assert Map.has_key?(summary, key),
             "canonical finalize summary 必须提供标量 #{key}（否则本期望值是空洞的）"
    end

    base = %{
      "authority_mode" => "sidecar",
      "stage" => "finalize",
      "outcome" => outcome,
      "mode" => summary["mode"],
      "status" => summary["status"],
      "required" => summary["required"],
      "verified" => summary["verified"],
      "finalized" => summary["finalized"],
      "debt" => summary["debt"],
      "unavailable" => summary["unavailable"],
      "omitted" => summary["omitted"],
      "orphaned" => summary["orphaned"]
    }

    if class, do: Map.put(base, "class", class), else: base
  end

  # ── G3 Batch A fixtures（§7.2 PG matrix）──

  # 构造一个带 canonical durable wrapper 与 fingerprint 的 PG journal，停在指定 entry
  # phase。全部经公开 `ObjectMutation` API，绝不旁路 Repo。
  defp pg_journal(ctx, key, phase, opts \\ []) do
    wrapper = Keyword.get(opts, :wrapper, g3_wrapper("canonical"))
    fingerprint = Keyword.get(opts, :fingerprint, @fingerprint)

    {:ok, journal} = ObjectMutation.prepare(prepare_attrs(ctx, key, 1))
    {:ok, journal} = ObjectMutation.transition(journal, "claimed")

    published_attrs =
      if wrapper,
        do: %{published_fingerprint: fingerprint, recovery_evidence: wrapper},
        else: %{published_fingerprint: fingerprint}

    {:ok, journal} = ObjectMutation.transition(journal, "published", published_attrs)
    {:ok, journal} = ObjectMutation.transition(journal, "metadata_committed")

    case phase do
      "metadata_committed" ->
        journal

      "finalize_pending" ->
        {:ok, pending} = ObjectMutation.transition(journal, "finalize_pending")
        pending
    end
  end

  # canonical wrapper 只经 G1 权威构造，绝不手写字面量；malformed 属于 canonical 命名空间
  # 但 published_proof 不是合法 aggregate summary，因此完全 JSON-safe、可原样持久化。
  defp g3_wrapper("canonical") do
    {:ok, wrapper} =
      PublishedProof.journal_evidence("published", g3_proof_summary("verified"), nil)

    wrapper
  end

  defp g3_wrapper("malformed"),
    do: %{"published_proof" => %{"g3" => "json-safe-but-not-canonical"}, "last_failure" => nil}

  defp g3_wrapper("missing"), do: nil

  defp g3_snapshot(journal) do
    wrapper = journal.recovery_evidence

    %{
      phase: journal.phase,
      attempts: journal.attempts,
      fingerprint: journal.published_fingerprint,
      wrapper: wrapper,
      wrapper_bytes: Jason.encode!(wrapper),
      proof: is_map(wrapper) && Map.get(wrapper, "published_proof"),
      proof_bytes: is_map(wrapper) && Jason.encode!(Map.get(wrapper, "published_proof"))
    }
  end

  defp g3_recover(ctx, journal) do
    {result, log} =
      with_log(@g3_capture_opts, fn ->
        Recovery.recover(journal.id, storage_opts: [data_dir: ctx.dir])
      end)

    {result, ObjectMutation.get(journal.id), log}
  end

  defp assert_pg_counts!(label, verify, finalize) do
    assert Script.call_count(:verify_published) == verify,
           "#{label}：verify_published 调用次数必须精确为 #{verify}"

    assert Script.call_count(:finalize_if_current) == finalize,
           "#{label}：finalize_if_current 调用次数必须精确为 #{finalize}"

    assert Script.call_count(:current_epoch) == 0,
           "#{label}：PG 矩阵的 current_epoch 恒为 0"

    assert Script.call_count(:restore_if_current) == 0,
           "#{label}：PG metadata 之后 restore 恒为 0"
  end

  # 初始 proof 的 term 与编码字节逐字不变（成功路径只可清陈旧 last_failure）。
  defp assert_proof_preserved!(journal, snapshot, label) do
    assert %{"published_proof" => proof} = journal.recovery_evidence
    assert proof === snapshot.proof, "#{label}：初始 proof term 必须逐字不变"
    assert Jason.encode!(proof) == snapshot.proof_bytes, "#{label}：初始 proof JSON 字节必须逐字不变"
  end

  # 【correction §4】期望 wrapper 由**生产权威**按精确 API 顺序算出：
  # `PublishedProof.merge_failure(expected_phase, snapshot.wrapper, canonical_summary)`。
  # 绝不自比、绝不用 `is_map(last_failure)` 之类的泛化替身。
  defp g3_expected_merge(expected_phase, snapshot, scripted) do
    summary = g3_summary_of(scripted)

    assert is_map(summary),
           "期望值必须来自被脚本化结果里的 canonical summary（实际：#{inspect(scripted)}）"

    {:ok, wrapper} = PublishedProof.merge_failure(expected_phase, snapshot.wrapper, summary)
    %{wrapper: wrapper, bytes: Jason.encode!(wrapper)}
  end

  # 完整 wrapper 的 term 与编码字节都必须严格等于上面冻结的期望值；同时继续单独证明
  # 初始 `published_proof` 的 term/字节与 fingerprint 逐字不变。
  defp assert_exact_merge!(journal, snapshot, expected, label) do
    assert journal.recovery_evidence === expected.wrapper,
           "#{label}：持久化 wrapper 必须严格等于生产权威合并出的期望 term"

    assert Jason.encode!(journal.recovery_evidence) == expected.bytes,
           "#{label}：持久化 wrapper 的 JSON 字节必须与期望值逐字相同"

    assert_proof_preserved!(journal, snapshot, label)
  end

  defp g3_proof_result("verified"), do: {:ok, {:verified, g3_proof_summary("verified")}}
  defp g3_proof_result("degraded"), do: {:ok, {:degraded, g3_proof_summary("degraded")}}
  defp g3_proof_result("superseded"), do: {:ok, {:superseded, g3_proof_summary("superseded")}}

  # 退役的 atom 结果：由冻结的 Storage callback trust boundary 折叠成 proof 契约违约。
  defp g3_proof_result("contract_violation"), do: {:ok, :verified}

  defp g3_proof_result(class) when class in @g3_integrity_classes or class == "unavailable" do
    atom = String.to_existing_atom(class)

    {:error, {:published_proof_failed, ^atom, summary}} =
      PublishedProof.classify(1, [{"local", PublishedProof.failed(atom, "local", %{owned: true})}])

    {:error, {:published_proof_failed, atom, summary}}
  end

  defp g3_proof_summary("verified") do
    {:ok, {:verified, summary}} =
      PublishedProof.classify(1, [{"local", PublishedProof.verified("local", %{})}])

    summary
  end

  defp g3_proof_summary("degraded") do
    {:ok, {:degraded, summary}} =
      PublishedProof.classify(1, [
        {"local", PublishedProof.verified("local", %{})},
        {"ordinal:1", PublishedProof.failed(:unavailable, "ordinal:1", %{owned: true})}
      ])

    summary
  end

  defp g3_proof_summary("superseded") do
    {:ok, {:superseded, summary}} =
      PublishedProof.classify(1, [{"local", PublishedProof.superseded("local")}])

    summary
  end

  defp g3_finalize_result("finalized") do
    {:ok, {:finalized, summary}} =
      PublishedProof.classify_finalize(1, [
        {"local", PublishedProof.endpoint_finalized("local", %{})}
      ])

    {:ok, {:finalized, summary}}
  end

  defp g3_finalize_result("cleanup_pending") do
    {:ok, {:cleanup_pending, summary}} =
      PublishedProof.classify_finalize(1, [
        {"ordinal:0", PublishedProof.endpoint_finalized("ordinal:0", %{})},
        {"ordinal:1", PublishedProof.endpoint_cleanup_pending("ordinal:1", %{})}
      ])

    {:ok, {:cleanup_pending, summary}}
  end

  defp g3_finalize_result("superseded") do
    {:ok, {:superseded, summary}} =
      PublishedProof.classify_finalize(1, [
        {"local", PublishedProof.endpoint_finalize_superseded("local")}
      ])

    {:ok, {:superseded, summary}}
  end

  # 退役的 atom 结果：由冻结的 Storage trust boundary 折叠成 finalize 契约违约。
  defp g3_finalize_result("contract_violation"), do: {:ok, :finalized}

  defp g3_finalize_result(class)
       when class in @g3_integrity_classes or class == "unavailable" do
    atom = String.to_existing_atom(class)

    {:error, {:published_proof_failed, ^atom, summary}} =
      PublishedProof.classify_finalize(1, [
        {"local", PublishedProof.endpoint_finalize_failed(atom, "local", %{owned: true})}
      ])

    {:error, {:published_proof_failed, atom, summary}}
  end

  # blueprint §4.2 表：proof disposition → {目标 phase, 精确稳定 code}
  defp g3_proof_expectation("unavailable"),
    do: {"finalize_pending", "published_proof_failed:proof:unavailable"}

  defp g3_proof_expectation("superseded"),
    do: {"finalized", "published_proof_superseded:proof"}

  defp g3_proof_expectation("contract_violation"),
    do: {"quarantined", "published_proof_contract_violation:proof"}

  defp g3_proof_expectation(class) when class in @g3_integrity_classes,
    do: {"quarantined", "published_proof_failed:proof:#{class}"}

  # blueprint §4.4 表：finalize disposition → {目标 phase, 精确稳定 code}
  defp g3_finalize_expectation("cleanup_pending"),
    do: {"finalize_pending", "published_proof_cleanup_pending:finalize"}

  defp g3_finalize_expectation("unavailable"),
    do: {"finalize_pending", "published_proof_failed:finalize:unavailable"}

  defp g3_finalize_expectation("superseded"),
    do: {"finalized", "published_proof_superseded:finalize"}

  defp g3_finalize_expectation("contract_violation"),
    do: {"quarantined", "published_proof_contract_violation:finalize"}

  defp g3_finalize_expectation(class) when class in @g3_integrity_classes,
    do: {"quarantined", "published_proof_failed:finalize:#{class}"}

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

  # 【G3 sidecar fixture correction】真实 FS 协议产物的 sidecar published 中间态。
  #
  # 与 EC partial 切片同形（真实 backend put + `around_object_commit` seam），但走 FS 且
  # authority_mode: "sidecar"：journal 先行 → claimed → 用**同一 token** claim epoch →
  # publish → 用 publish 真实回传的 fingerprint 把 journal 推进 published。随后**先杀
  # Control 再杀 publisher**（全程 monitor + 精确 `:DOWN`，零 sleep/轮询）：加速器整体消失，
  # 终局收敛完全交给 Recovery 依 journal + durable epoch + backend proof 作出。
  defp sidecar_published_fixture(ctx, key, content) do
    # 先播种旧值：published 中间态因此拥有真实的 durable mutation backup（manifest 可取证）。
    {:ok, _} = Storage.put(ctx.bucket, key, "null", ["old sidecar content"], data_dir: ctx.dir)

    {:ok, journal} =
      ObjectMutation.prepare(Map.put(prepare_attrs(ctx, key, 1), :authority_mode, "sidecar"))

    {:ok, journal} = ObjectMutation.transition(journal, "claimed")
    {:ok, claim_mctx} = MutationContext.from_journal(journal)

    parent = self()

    publisher =
      start_supervised!(
        {Task,
         fn ->
           Storage.put(ctx.bucket, key, "null", [content],
             data_dir: ctx.dir,
             around_object_commit: fn write_info, publish ->
               {:ok, _} =
                 Storage.claim_epoch(claim_mctx.target, claim_mctx.token, "put",
                   data_dir: ctx.dir
                 )

               {:ok, published} =
                 publish.(version_id: "null", object_meta: %{}, object_mutation: claim_mctx)

               send(
                 parent,
                 {:sidecar_published, Map.fetch!(write_info, :object_commit_control),
                  published.epoch_fingerprint}
               )

               # 阻塞：ObjectCommit 完成路径绝不允许提前 finalize 掉这个中间态。
               receive do
                 :never -> {:error, :never}
               end
             end
           )
         end},
        id: {:sidecar_publisher, System.unique_integer([:positive])}
      )

    assert_receive {:sidecar_published, control, fingerprint}, 15_000

    {:ok, journal} =
      ObjectMutation.transition(journal, "published", %{published_fingerprint: fingerprint})

    control_ref = Process.monitor(control)
    Process.exit(control, :kill)
    assert_receive {:DOWN, ^control_ref, :process, ^control, :killed}, 5_000
    publisher_ref = Process.monitor(publisher)
    Process.exit(publisher, :kill)
    assert_receive {:DOWN, ^publisher_ref, :process, ^publisher, :killed}, 5_000

    # 取证/断言用的 context 由 **published** journal 派生：它携带真实 published_fingerprint，
    # 与 Recovery 自行派生的 context 逐字同源。
    {:ok, mctx} = MutationContext.from_journal(journal)
    {:ok, journal, mctx, fingerprint}
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
