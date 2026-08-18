defmodule Maxio.ObjectMutation.Recovery do
  @moduledoc """
  ObjectMutation journal 的耐久收敛 recovery worker（协议 2026-07-10 §5 步骤 5 后半，
  实现计划 B6）。crash recovery 根据 journal phase + backend durable epoch 作**确定性决策**，
  不依赖任何进程是否存活；`ObjectCommit.Control` 只是进程内加速器（D5），终局收敛永远由
  本模块兜底。决策表：

  | journal phase + authority | 动作 |
  |---|---|
  | `metadata_committed` / `finalize_pending`（pg） | → finalize_pending → `finalize_if_current` → finalized；successor → finalized + superseded 证据 |
  | `published`（pg） | → rollback_pending → `restore_if_current` → rolled_back；successor → rolled_back + 证据（不触 final） |
  | `published`（sidecar） | 读 epoch：published/committed（本 token）→ **必须 finalize**（协议 §4：不得因 journal 未 metadata_committed 而 rollback）；epoch 缺失/不可读/矛盾 → quarantine |
  | `prepared` / `claimed` | → rollback_pending → `restore_if_current` → rolled_back；prepared 从未确立 epoch 授权，epoch absent 直接收敛（零破坏性 IO） |
  | `rollback_pending` | `restore_if_current` → rolled_back / superseded |

  错误分类（不猜测、不破坏、backup 保留）：证据矛盾类（epoch/manifest `{:corrupt,_}`、
  `{:placement_drift,_}`、`{:invalid_placement_snapshot,_}`、`{:epoch_mismatch,_}`、
  rollback 途中却见 committed epoch）→ `quarantine`（终态，操作员经 CLI 裁决）；其余
  （`:epoch_missing`、`{:partial,_}`、quorum 不可用、端点失联等）→ `mark_error` 可重试
  （backoff 后由下一轮 drain 接手）。

  竞争防线（D5/R5 双保险）：worker 经 `ObjectMutation.claim` 持恢复租约（DB CAS 互斥），
  并对每条 journal 取与请求路径**相同的** `{bucket, key}` object lock——健康 in-flight
  请求除 60s prepare 宽限外再受锁保护；拿不到锁只 `mark_error` 短 backoff 跳过，绝不误
  回滚。锁序与请求路径一致：object lock → journal CAS → backend epoch 调用（R2）。
  """

  alias Maxio.Lock
  alias Maxio.ObjectMutation
  alias Maxio.ObjectMutation.Journal
  alias Maxio.ObjectMutation.Log
  alias Maxio.ObjectMutation.StorageDisposition
  alias Maxio.Storage
  alias Maxio.Storage.MutationBackup
  alias Maxio.Storage.MutationContext
  alias Maxio.Storage.ObjectEpoch
  alias Maxio.Storage.PublishedProof

  @sidecar_finalize_epoch_phases ~w(published committed)
  # 对象锁被健康 in-flight 请求持有时的短 backoff（区别于 mark_error 默认 60s：锁窗口
  # 正常毫秒级，快速重试即可收敛）。
  @default_locked_backoff_ms 5_000
  @max_error_chars 2_000

  # ── 冻结的稳定 code（G3 blueprint §4–§6）──
  #
  # 运维失败绝不伪装成 proof 失败；异常消息 / inspect 输出 / 路径 / 端点 payload /
  # raw callback term 一律不得进入 evidence、last_error 或日志。
  @stable_context_invalid "object_mutation:context_invalid"
  @stable_object_locked "object_mutation:object_locked"
  @stable_restore_failed "object_mutation:restore_failed"
  @stable_recovery_exception "object_mutation:recovery_exception"
  @stable_lease_renewal_failed "object_mutation:lease_renewal_failed"
  @stable_claim_failed "object_mutation:claim_failed"
  @stable_journal_convergence_failed "object_mutation:journal_convergence_failed"

  @stable_proof_invalid_durable "published_proof_invalid:durable"
  @stable_proof_superseded "published_proof_superseded:proof"
  @stable_proof_contract_violation "published_proof_contract_violation:proof"
  @stable_finalize_superseded "published_proof_superseded:finalize"
  @stable_finalize_cleanup_pending "published_proof_cleanup_pending:finalize"
  @stable_finalize_contract_violation "published_proof_contract_violation:finalize"
  @stable_sidecar_impossible_phase "sidecar_phase:metadata_committed"

  @integrity_classes [:mismatch, :corrupt, :placement_drift]

  # sidecar 只写**有界通用标量投影**：以下 canonical 标量逐个从已校验的 summary 取值，
  # 绝不持久化 scope / observed_owned / degraded / orphan_hints / detail / endpoint /
  # path / token / raw tuple / inspect 后的 reason。
  @sidecar_projection_keys ~w(mode status required verified finalized debt unavailable omitted orphaned)
  @sidecar_base_keys ~w(authority_mode stage outcome)
  @sidecar_current_epoch_outcomes ~w(missing unavailable conflict contract_violation)
  @sidecar_finalize_outcomes ~w(finalized cleanup_pending superseded failed contract_violation)

  @empty_stats %{
    claimed: 0,
    finalized: 0,
    rolled_back: 0,
    superseded: 0,
    quarantined: 0,
    retried: 0,
    skipped_locked: 0
  }

  @type stats :: %{
          claimed: non_neg_integer(),
          finalized: non_neg_integer(),
          rolled_back: non_neg_integer(),
          superseded: non_neg_integer(),
          quarantined: non_neg_integer(),
          retried: non_neg_integer(),
          skipped_locked: non_neg_integer()
        }

  @doc """
  drain 一轮到期 journal（`list_due` → 逐条 claim → object lock → 决策表推进）。

  opts：
    * `:limit` / `:now` / `:repo` / `:older_than_ms` —— 透传 `ObjectMutation.list_due`
      （`:now` 时间注入供测试与 CLI 使用，R5：不得为图方便缩短 prepare 宽限；
      `:older_than_ms` 为 CLI `--older-than` 的落点，只处理创建超过给定年龄的记录）；
    * `:lease_ms` / `:backoff_ms` / `:locked_backoff_ms` —— 租约与重试节奏；
    * `:lease_owner` —— 恢复租约持有者标识（默认 `node/pid`）；
    * `:storage_opts` —— 透传给全部 `Storage` epoch/restore/finalize 调用（后端 opts）。
  """
  @spec drain(keyword()) :: stats()
  def drain(opts \\ []) do
    Keyword.take(opts, [:repo, :now, :limit, :older_than_ms])
    |> ObjectMutation.list_due()
    |> Enum.reduce(@empty_stats, fn journal, stats ->
      case recover_claimed(journal, opts) do
        {:ok, outcome, _journal} -> stats |> bump(:claimed) |> bump(outcome)
        {:locked, _journal} -> stats |> bump(:claimed) |> bump(:skipped_locked)
        {:stale, _reason} -> bump(stats, :claimed)
        {:claim_failed, _reason} -> stats
      end
    end)
  end

  @doc """
  单条恢复入口（CLI `--mutation-id` 与 drain 共用同一路径，禁止旁路）：claim 恢复租约 →
  同一 `{bucket, key}` object lock → 决策表推进。journal 未到期或被他人持租 →
  `{:error, :not_due_or_leased}`；对象锁被占 → `{:error, :locked}`（journal 已
  mark_error 短 backoff，保持可重试）。
  """
  @spec recover(Journal.t() | Ecto.UUID.t(), keyword()) :: {:ok, Journal.t()} | {:error, term()}
  def recover(ref, opts \\ [])

  def recover(%Journal{} = journal, opts) do
    case recover_claimed(journal, opts) do
      {:ok, _outcome, final} -> {:ok, final}
      {:locked, _journal} -> {:error, :locked}
      {:stale, reason} -> {:error, reason}
      {:claim_failed, reason} -> {:error, reason}
    end
  end

  def recover(id, opts) when is_binary(id) do
    case ObjectMutation.get(id, journal_opts(opts)) do
      %Journal{} = journal -> recover(journal, opts)
      nil -> {:error, :not_found}
    end
  end

  # ── claim + object lock（第二道防线）──

  defp recover_claimed(journal, opts) do
    owner = lease_owner(opts)

    case invoke_claim(journal, owner, opts) do
      {:ok, %Journal{lease_owner: ^owner} = claimed} ->
        locked_apply(claimed, opts)

      # claim 的 CAS 读回可能返回一行**已被他人接管**的租约（读回时刻租约已易主）。
      # 那不是我们的租约：零写入返回，绝不把任何诊断写到新 owner 头上，也绝不把
      # observed owner 泄漏到 outward result 或日志（§3.1 稳定 claim 边界）。
      {:ok, %Journal{}} ->
        log_no_action(journal, @stable_claim_failed)
        {:stale, @stable_claim_failed}

      {:error, reason} when reason in [:not_found, :not_due_or_leased] ->
        {:claim_failed, reason}

      {:error, code} ->
        log_no_action(journal, code)
        {:claim_failed, code}
    end
  end

  # §3.2 唯一的 claim invoke wrapper：一次性覆盖 Elixir 的三个异常域。
  # 只有既有公共控制结果 `:not_found` / `:not_due_or_leased` 逐字保留；其余任何
  # `{:error, _}`、raise、exit、throw 都折叠成同一个稳定 claim binary。捕获值立即丢弃：
  # 绝不 inspect / Exception.message / to_string / 记录 / 放进 evidence 或 journal。
  defp invoke_claim(journal, owner, opts) do
    case ObjectMutation.claim(journal, owner, lease_opts(opts)) do
      {:ok, %Journal{} = claimed} -> {:ok, claimed}
      {:error, :not_found} -> {:error, :not_found}
      {:error, :not_due_or_leased} -> {:error, :not_due_or_leased}
      {:error, _reason} -> {:error, @stable_claim_failed}
    end
  rescue
    _error -> {:error, @stable_claim_failed}
  catch
    :exit, _reason -> {:error, @stable_claim_failed}
    :throw, _value -> {:error, @stable_claim_failed}
  end

  # fun 在 Lock 的独立 worker 进程内执行（shared sandbox 兼容，R1）；进锁后先 renew
  # （锁获取的重试耗时不侵蚀租约），renew 失败即另一 worker 已接管——放手不动。
  defp locked_apply(journal, opts) do
    resource = {journal.bucket_name, journal.object_key}

    lock_result =
      Lock.with_object_lock(resource, fn ->
        case invoke_renew(journal, opts) do
          {:ok, fresh} -> safe_decide(fresh, opts)
          {:error, _code} -> lease_renewal_failed(journal, opts)
        end
      end)

    case lock_result do
      {:ok, {:ok, outcome, final}} ->
        {:ok, outcome, final}

      # 锁内失败一律已是稳定 binary：本 worker 不再动 journal，但要主动释放仍属于自己的
      # 租约（否则只能等 60s 过期自愈，纯 liveness 延迟）。锁内 renew 可能已更新过期时刻，
      # 须按最新行判定；租约已易主则绝不触碰（接管者负责自己的租约）。
      {:ok, {:error, code}} ->
        _ = release_own_lease_quietly(journal, opts)
        log_no_action(journal, code)
        {:stale, code}

      {:error, :locked} ->
        handle_locked(journal, opts)
    end
  end

  # §3.2 唯一的 renew invoke wrapper：同样一次性覆盖三个异常域，任何 renew 失败域都只
  # 折叠成稳定 lease binary，捕获值立即丢弃。
  defp invoke_renew(journal, opts) do
    case ObjectMutation.renew_lease(journal, lease_opts(opts)) do
      {:ok, %Journal{} = fresh} -> {:ok, fresh}
      {:error, _reason} -> {:error, @stable_lease_renewal_failed}
    end
  rescue
    _error -> {:error, @stable_lease_renewal_failed}
  catch
    :exit, _reason -> {:error, @stable_lease_renewal_failed}
    :throw, _value -> {:error, @stable_lease_renewal_failed}
  end

  # §3.2 租约续期栅栏：只有在 fresh 读仍显示本 worker 持租时，才做一次
  # evidence-preserving 的运维 CAS，随后只释放自己的租约；owner 已易主则零写入。
  # 两条分支的 outward reason 都是同一个稳定 lease code，绝不暴露 owner 或 raw tuple。
  defp lease_renewal_failed(journal, opts) do
    case ObjectMutation.get(journal.id, journal_opts(opts)) do
      %Journal{lease_owner: owner} = fresh when owner == journal.lease_owner and owner != nil ->
        _ = operational_error(fresh, @stable_lease_renewal_failed, opts)
        {:error, @stable_lease_renewal_failed}

      _other ->
        {:error, @stable_lease_renewal_failed}
    end
  end

  # 对象锁被健康 in-flight 请求持有：短 backoff 跳过（只涨 attempts / 推迟
  # next_attempt_at，不改 phase），租约立即释放——绝不与活请求争抢，也绝不误回滚（R5）。
  defp handle_locked(journal, opts) do
    backoff_ms = positive_int(Keyword.get(opts, :locked_backoff_ms), @default_locked_backoff_ms)
    mark_opts = journal_opts(opts) ++ [backoff_ms: backoff_ms]

    # §6 受保护证据分流：已带非 nil 证据的行只能走 evidence-preserving 的运维 CAS，
    # 让证据 byte-for-term 原样保留；nil 证据的行沿用既有的有界通用证据。
    result =
      if protected_evidence?(journal) do
        ObjectMutation.mark_operational_error(journal, @stable_object_locked, mark_opts)
      else
        evidence = %{"stage" => "recovery", "reason" => "object_locked"}
        ObjectMutation.mark_error(journal, @stable_object_locked, evidence, mark_opts)
      end

    journal =
      case result do
        {:ok, marked} -> release_quietly(marked, opts)
        {:error, _reason} -> journal
      end

    Log.warn(
      "object mutation recovery skipped: object lock held",
      Log.journal_fields(journal,
        action: :object_mutation_recovery_decision,
        outcome: :skipped_locked
      )
    )

    {:locked, journal}
  end

  # 决策执行的异常兜底：任何未预期异常折叠为**保留证据**的运维错误（backup 保留，
  # 不猜测、不破坏），绝不让单条 journal 的异常终止整轮 drain，也绝不把异常消息落库。
  defp safe_decide(journal, opts) do
    route_authority_phase(journal, opts)
  rescue
    _error -> operational_error(journal, @stable_recovery_exception, opts)
  end

  # ── §3 authority/phase 预路由（先于任何 context 派生与通用 phase 处理）──
  #
  # sidecar `metadata_committed` 是不可能状态：它必须在**所有** Storage I/O 之前命中
  # 自己的隔离分支，即使该行根本无法派生 mutation context。

  defp route_authority_phase(
         %Journal{authority_mode: "sidecar", phase: "metadata_committed"} = journal,
         opts
       ),
       do: preserving_quarantine(journal, @stable_sidecar_impossible_phase, opts)

  defp route_authority_phase(journal, opts) do
    case MutationContext.from_journal(journal) do
      {:ok, ctx} ->
        route_with_context(journal, ctx, opts)

      # journal 行无法派生执行上下文＝持久数据自身矛盾。在任何 Storage I/O 之前
      # evidence-preserving 隔离取证：绝不覆盖既有 fingerprint / 证据。
      {:error, _reason} ->
        preserving_quarantine(journal, @stable_context_invalid, opts)
    end
  end

  # pg 的 metadata_committed / finalize_pending：唯一合法方向是 proof-aware finalize
  # （协议 §4 metadata_committed 禁回滚线；metadata 之后绝不 rollback/restore）。
  defp route_with_context(%Journal{authority_mode: "pg", phase: phase} = journal, ctx, opts)
       when phase in ~w(metadata_committed finalize_pending),
       do: recover_pg_finalize(journal, ctx, opts)

  # sidecar published：backend epoch 达 published quorum 即 logical authority commit——
  # 必须 finalize，不得因 journal 未 metadata_committed 而 rollback（协议 §4）。
  defp route_with_context(
         %Journal{authority_mode: "sidecar", phase: "published"} = journal,
         ctx,
         opts
       ),
       do: recover_sidecar_published(journal, ctx, opts)

  # sidecar finalize_pending：直接进共享 finalize adapter，绝不做独立 verify。
  defp route_with_context(
         %Journal{authority_mode: "sidecar", phase: "finalize_pending"} = journal,
         ctx,
         opts
       ),
       do: recover_sidecar_finalize(journal, ctx, opts)

  defp route_with_context(%Journal{phase: "rollback_pending"} = journal, ctx, opts),
    do: restore_flow(journal, ctx, opts, "rollback_pending")

  defp route_with_context(%Journal{phase: phase} = journal, ctx, opts)
       when phase in ~w(prepared claimed published),
       do: rollback_flow(journal, ctx, opts)

  defp rollback_flow(%Journal{phase: origin} = journal, ctx, opts) do
    with {:ok, pending} <- to_phase(journal, "rollback_pending", opts) do
      restore_flow(pending, ctx, opts, origin)
    end
  end

  defp restore_flow(journal, ctx, opts, origin) do
    case Storage.restore_if_current(ctx, storage_opts(opts)) do
      {:ok, :restored} ->
        conclude(journal, "rolled_back", %{}, :rolled_back, opts)

      {:ok, :superseded} ->
        conclude(
          journal,
          "rolled_back",
          %{recovery_evidence: superseded_evidence("restore", ctx, opts)},
          :superseded,
          opts
        )

      # prepared 从未确立 epoch 授权（journal → claimed 前崩溃；destructive IO 只可能发生
      # 在 claimed 之后）：epoch absent 是预期状态而非证据缺失，与 Commit.abandon_unclaimed
      # 同源直接收敛——零存储副作用，绝不把 nil/:enoent 当成任何动作的授权。
      {:error, :epoch_missing} when origin == "prepared" ->
        conclude(
          journal,
          "rolled_back",
          %{
            recovery_evidence: %{
              "stage" => "restore",
              "reason" => "epoch_missing_before_claim"
            }
          },
          :rolled_back,
          opts
        )

      {:error, reason} ->
        classify_restore_error(journal, "restore", reason, opts)
    end
  end

  # ── §4 PG proof-aware convergence ──

  # §4.1 durable gate：任何端点 I/O 之前先过冻结的非变异权威。非法证据绝不裁剪、
  # 修复、规范化或替换——evidence-preserving 隔离，verify/finalize/current_epoch/
  # restore 调用次数全部为零。
  defp recover_pg_finalize(journal, ctx, opts) do
    case PublishedProof.validate_durable_evidence(journal.phase, journal.recovery_evidence) do
      :ok ->
        ctx
        |> Storage.verify_published(storage_opts(opts))
        |> StorageDisposition.proof()
        |> apply_pg_proof_disposition(journal, ctx, opts)

      {:error, _reason} ->
        preserving_quarantine(journal, @stable_proof_invalid_durable, opts)
    end
  end

  # §4.2/§4.3 proof disposition → journal 策略。pending CAS 是破坏性 finalize 的
  # **唯一**授权栅栏：它没通过，finalize 调用次数恒为零。
  defp apply_pg_proof_disposition({:proof_passed, _class, _summary}, journal, ctx, opts) do
    with {:ok, pending} <- pg_pending_fence(journal, %{}, opts) do
      apply_pg_finalize(pending, ctx, opts)
    end
  end

  # 后继：先做合法的 pending 转换（原子写入合并证据 + 稳定 code），再收敛终态 finalized。
  # finalize I/O 恒为零。
  defp apply_pg_proof_disposition({:superseded, summary}, journal, _ctx, opts) do
    pg_merged_terminal(journal, summary, @stable_proof_superseded, :superseded, :proof, opts)
  end

  # 可重试：合并 canonical last failure、保持 pending、排期重试。
  defp apply_pg_proof_disposition(
         {:retryable_failure, :unavailable, summary},
         journal,
         _ctx,
         opts
       ) do
    pg_merged_pending_retry(journal, summary, stable_proof_code(:unavailable), :proof, opts)
  end

  # 完整性：纯 merge 之后直接一次 evidence-writing quarantine CAS。
  defp apply_pg_proof_disposition({:integrity_failure, class, summary}, journal, _ctx, opts)
       when class in @integrity_classes do
    pg_merged_quarantine(journal, summary, stable_proof_code(class), :proof, opts)
  end

  # callback 契约违约：没有 canonical summary，绝不 merge——evidence-preserving 隔离。
  defp apply_pg_proof_disposition({:contract_violation, :proof}, journal, _ctx, opts),
    do: preserving_quarantine(journal, @stable_proof_contract_violation, opts)

  # §4.4 finalize：只在 pending fence 之后恰好调用一次，并恰好分类一次。
  defp apply_pg_finalize(pending, ctx, opts) do
    ctx
    |> Storage.finalize_if_current(storage_opts(opts))
    |> StorageDisposition.finalize()
    |> apply_pg_finalize_disposition(pending, opts)
  end

  # 成功终结：保留初始 proof，只清掉陈旧的 canonical last_failure（绝不替换或重编码
  # `published_proof`）。
  defp apply_pg_finalize_disposition({:finalized, _summary}, pending, opts) do
    case pg_cleared_success_attrs(pending) do
      {:ok, attrs} ->
        conclude(pending, "finalized", attrs, :finalized, opts)

      :contract_violation ->
        preserving_quarantine(pending, @stable_finalize_contract_violation, opts)
    end
  end

  defp apply_pg_finalize_disposition({:cleanup_pending, summary}, pending, opts),
    do:
      pg_merged_pending_retry(
        pending,
        summary,
        @stable_finalize_cleanup_pending,
        :finalize,
        opts
      )

  defp apply_pg_finalize_disposition({:superseded, summary}, pending, opts),
    do:
      pg_merged_terminal(
        pending,
        summary,
        @stable_finalize_superseded,
        :superseded,
        :finalize,
        opts
      )

  defp apply_pg_finalize_disposition({:retryable_failure, :unavailable, summary}, pending, opts),
    do:
      pg_merged_pending_retry(
        pending,
        summary,
        stable_finalize_code(:unavailable),
        :finalize,
        opts
      )

  defp apply_pg_finalize_disposition({:integrity_failure, class, summary}, pending, opts)
       when class in @integrity_classes,
       do: pg_merged_quarantine(pending, summary, stable_finalize_code(class), :finalize, opts)

  defp apply_pg_finalize_disposition({:contract_violation, :finalize}, pending, opts),
    do: preserving_quarantine(pending, @stable_finalize_contract_violation, opts)

  # pending 栅栏：`transition/4` 对已是 finalize_pending 的行是幂等无写入的，因此
  # 它既能从 metadata_committed 推进，也能在 pending 上原样通过。
  defp pg_pending_fence(journal, attrs, opts) do
    case ObjectMutation.transition(journal, "finalize_pending", attrs, journal_opts(opts)) do
      {:ok, pending} -> {:ok, pending}
      {:error, reason} -> convergence_failure(reason)
    end
  end

  # §3.2 唯一的收敛失败 normalizer：transition / mark_error / quarantine / conclude 等
  # **每一个** journal CAS 失败都只经这里折叠成同一个稳定 binary。raw reason 在这一个
  # 位置被丢弃，绝不 inspect、记录、放进 evidence 或穿出对象锁。
  #
  # 唯一的例外是 `preserving_quarantine/3` 的错误臂：R7.1 canonical grammar 把它固定为
  # 字面 `{:error, @stable_journal_convergence_failed}` 尾部，那是同一个 attribute 值的
  # 契约指定形态，不是第二个 normalizer。
  defp convergence_failure(_reason), do: {:error, @stable_journal_convergence_failed}

  # ── §4 唯一的 mode-aware PG merge adapter seam ──
  #
  # 三个 caller 都不再各自解释 merge 拒绝：它们只把 (原 journal, 固定 target, canonical
  # summary, 字面 mode, opts, 续延) 交给唯一的 owner adapter。成功续延才执行各自的目标
  # 动作；拒绝一律由 adapter 从**原 journal** 直接 evidence-preserving 隔离。

  # mode → 精确 contract code 的唯一映射（恰好两个无 guard 子句，无 catchall）。
  defp pg_contract_code(:proof), do: @stable_proof_contract_violation
  defp pg_contract_code(:finalize), do: @stable_finalize_contract_violation

  # 唯一 owner adapter。拒绝分支绝不 log/inspect/使用 reason，绝不写入被拒绝的 merged
  # value，绝不先推进 finalize_pending，绝不 restore/rollback。
  defp pg_merge(journal, target_phase, summary, mode, opts, continuation) do
    case PublishedProof.merge_failure(target_phase, journal.recovery_evidence, summary) do
      {:ok, merged} -> continuation.(merged)
      {:error, _reason} -> preserving_quarantine(journal, pg_contract_code(mode), opts)
    end
  end

  # 合并 canonical last failure 后保持 pending 并排期重试。
  defp pg_merged_pending_retry(journal, summary, code, mode, opts) do
    pg_merge(journal, "finalize_pending", summary, mode, opts, fn merged ->
      pg_pending_retry_action(journal, code, merged, opts)
    end)
  end

  # 后继/终态：合并证据针对目标终态构造。
  defp pg_merged_terminal(journal, summary, code, outcome, mode, opts) do
    pg_merge(journal, "finalized", summary, mode, opts, fn merged ->
      pg_terminal_action(journal, code, merged, outcome, opts)
    end)
  end

  defp pg_merged_quarantine(journal, summary, code, mode, opts) do
    pg_merge(journal, "quarantined", summary, mode, opts, fn merged ->
      quarantine_journal(journal, code, merged, opts)
    end)
  end

  # 已在 finalize_pending：同相位 `transition/4` 不写 attrs，因此必须用 evidence-writing
  # 的 `mark_error/4` 一次 CAS 完成证据 + code + attempts + backoff。仍在
  # metadata_committed：先原子转换写入合并证据与 code，再对 fresh pending 行做
  # `mark_operational_error/3` 涨 attempts / 排期——两次 CAS 之间崩溃只会留下一个安全、
  # 可立即重试的 pending 行，绝不授权回滚。
  defp pg_pending_retry_action(%Journal{phase: "finalize_pending"} = journal, code, merged, opts),
    do: pg_mark_error(journal, code, merged, opts)

  defp pg_pending_retry_action(journal, code, merged, opts) do
    with {:ok, _pending} <-
           pg_pending_fence(journal, %{recovery_evidence: merged, last_error: code}, opts) do
      pg_operational_retry(journal, code, opts)
    end
  end

  # 从 metadata_committed 必须先走合法 pending 边，再收敛终态。
  defp pg_terminal_action(
         %Journal{phase: "finalize_pending"} = journal,
         code,
         merged,
         outcome,
         opts
       ),
       do: conclude(journal, "finalized", pg_terminal_attrs(merged, code), outcome, opts)

  defp pg_terminal_action(journal, code, merged, outcome, opts) do
    attrs = pg_terminal_attrs(merged, code)

    with {:ok, pending} <- pg_pending_fence(journal, attrs, opts) do
      conclude(pending, "finalized", attrs, outcome, opts)
    end
  end

  defp pg_terminal_attrs(merged, code),
    do: %{recovery_evidence: merged, last_error: code}

  # 成功路径只可清掉陈旧 canonical last_failure；`published_proof` 逐字不动。
  defp pg_cleared_success_attrs(%Journal{recovery_evidence: %{"last_failure" => nil}}),
    do: {:ok, %{}}

  defp pg_cleared_success_attrs(%Journal{
         recovery_evidence: %{"published_proof" => proof, "last_failure" => _failure}
       }) do
    case PublishedProof.journal_evidence("finalized", proof, nil) do
      {:ok, wrapper} -> {:ok, %{recovery_evidence: wrapper}}
      {:error, _reason} -> :contract_violation
    end
  end

  defp pg_cleared_success_attrs(_journal), do: {:ok, %{}}

  defp pg_mark_error(journal, code, evidence, opts) do
    case ObjectMutation.mark_error(journal, code, evidence, retry_opts(opts)) do
      {:ok, marked} -> {:ok, :retried, release_quietly(marked, opts)}
      {:error, reason} -> convergence_failure(reason)
    end
  end

  # 第二次 CAS 必须打在**本 worker 刚刚写下的那一行**上，而不是 `transition/4` 的
  # 读回结果：读回会把并发赢家的 attempts 一并带回来，令第二次 CAS 反而"成功"并覆盖
  # 赢家。pending 转换不改 attempts/lease，因此期望身份 = 观察行 + phase 推进。
  # CAS 输掉即绝不覆盖赢家：保留原请求语义，只释放本 worker 自己的租约。
  defp pg_operational_retry(%Journal{} = observed, code, opts) do
    expected = %Journal{observed | phase: "finalize_pending"}

    case ObjectMutation.mark_operational_error(expected, code, retry_opts(opts)) do
      {:ok, marked} -> {:ok, :retried, release_quietly(marked, opts)}
      {:error, _reason} -> {:ok, :retried, release_own_lease_quietly(observed, opts)}
    end
  end

  defp stable_proof_code(class), do: "published_proof_failed:proof:#{class}"
  defp stable_finalize_code(class), do: "published_proof_failed:finalize:#{class}"

  # ── §5 sidecar adapters（绝不调用 PG 的 durable validator / merge）──

  # §5.1 published current-epoch pre-adapter：只有 sidecar published 读 current_epoch。
  # 本 token 且 phase 合法 → 进 pending 栅栏；观察到更大的 token → 同样交由 backend
  # finalize adapter 给出权威 superseded 判定（Recovery 绝不触碰 successor）。
  defp recover_sidecar_published(journal, ctx, opts) do
    case safe_current_epoch(ctx, opts) do
      {:ok, %ObjectEpoch{token: token, phase: phase}}
      when token == ctx.token and phase in @sidecar_finalize_epoch_phases ->
        sidecar_pending_then_finalize(journal, ctx, opts)

      {:ok, %ObjectEpoch{} = epoch} ->
        case ObjectEpoch.compare_tokens(epoch.token, ctx.token) do
          {:ok, :gt} -> sidecar_pending_then_finalize(journal, ctx, opts)
          _other -> sidecar_current_epoch_failure(journal, "conflict", opts)
        end

      {:ok, :absent} ->
        sidecar_current_epoch_failure(journal, "missing", opts)

      {:error, :unavailable} ->
        sidecar_current_epoch_failure(journal, "unavailable", opts)

      {:error, :contract_violation} ->
        sidecar_current_epoch_failure(journal, "contract_violation", opts)
    end
  end

  # §5.4：published 入口**从不**直接授权 finalize 证据写入。它必须先做无证据的
  # published→finalize_pending 转换，再用 fresh pending 行驱动共享 adapter。
  defp sidecar_pending_then_finalize(journal, ctx, opts) do
    with {:ok, pending} <-
           (case ObjectMutation.transition(journal, "finalize_pending", %{}, journal_opts(opts)) do
              {:ok, fresh} -> {:ok, fresh}
              {:error, reason} -> convergence_failure(reason)
            end) do
      recover_sidecar_finalize(pending, ctx, opts)
    end
  end

  # 把 raise/exit/throw 折叠成固定的 contract violation：raw term 绝不外泄。
  defp safe_current_epoch(ctx, opts) do
    case Storage.current_epoch(ctx.target, storage_opts(opts)) do
      {:ok, %ObjectEpoch{} = epoch} -> {:ok, epoch}
      {:ok, :absent} -> {:ok, :absent}
      {:error, _reason} -> {:error, :unavailable}
      _other -> {:error, :contract_violation}
    end
  rescue
    _error -> {:error, :contract_violation}
  catch
    _kind, _reason -> {:error, :contract_violation}
  end

  defp sidecar_current_epoch_failure(journal, outcome, opts) do
    evidence = %{
      "authority_mode" => "sidecar",
      "stage" => "current_epoch",
      "outcome" => outcome
    }

    code = "sidecar_current_epoch:#{outcome}"

    with :ok <- validate_sidecar_write(journal, :current_epoch, "quarantined", evidence, code) do
      quarantine_journal(journal, code, evidence, opts)
    end
  end

  # §5.2 共享 finalize adapter：两个合法入口共用，绝不做独立 verify，只消费
  # `StorageDisposition.finalize/1`。
  defp recover_sidecar_finalize(pending, ctx, opts) do
    ctx
    |> Storage.finalize_if_current(storage_opts(opts))
    |> StorageDisposition.finalize()
    |> apply_sidecar_finalize_disposition(pending, opts)
  end

  defp apply_sidecar_finalize_disposition({:finalized, summary}, pending, opts),
    do: sidecar_write(pending, "finalized", "finalized", nil, summary, nil, :finalized, opts)

  defp apply_sidecar_finalize_disposition({:cleanup_pending, summary}, pending, opts) do
    sidecar_write(
      pending,
      "finalize_pending",
      "cleanup_pending",
      nil,
      summary,
      "sidecar_finalize:cleanup_pending",
      :retried,
      opts
    )
  end

  defp apply_sidecar_finalize_disposition({:superseded, summary}, pending, opts) do
    sidecar_write(
      pending,
      "finalized",
      "superseded",
      nil,
      summary,
      "sidecar_finalize:superseded",
      :superseded,
      opts
    )
  end

  defp apply_sidecar_finalize_disposition(
         {:retryable_failure, :unavailable, summary},
         pending,
         opts
       ) do
    sidecar_write(
      pending,
      "finalize_pending",
      "failed",
      "unavailable",
      summary,
      "sidecar_finalize:unavailable",
      :retried,
      opts
    )
  end

  defp apply_sidecar_finalize_disposition({:integrity_failure, class, summary}, pending, opts)
       when class in @integrity_classes do
    sidecar_write(
      pending,
      "quarantined",
      "failed",
      Atom.to_string(class),
      summary,
      "sidecar_finalize:#{class}",
      :quarantined,
      opts
    )
  end

  defp apply_sidecar_finalize_disposition({:contract_violation, :finalize}, pending, opts) do
    evidence = %{
      "authority_mode" => "sidecar",
      "stage" => "finalize",
      "outcome" => "contract_violation"
    }

    code = "sidecar_finalize:contract_violation"

    with :ok <- validate_sidecar_write(pending, :finalize, "quarantined", evidence, code) do
      quarantine_journal(pending, code, evidence, opts)
    end
  end

  # 有界投影 + 每次写入前的调用点校验（§5.4），随后才发 SQL。
  defp sidecar_write(pending, target_phase, outcome, class, summary, code, stat, opts) do
    evidence = sidecar_finalize_evidence(outcome, class, summary)

    with :ok <- validate_sidecar_write(pending, :finalize, target_phase, evidence, code) do
      sidecar_apply(pending, target_phase, evidence, code, stat, opts)
    end
  end

  defp sidecar_apply(pending, "quarantined", evidence, code, _stat, opts),
    do: quarantine_journal(pending, code, evidence, opts)

  defp sidecar_apply(pending, "finalize_pending", evidence, code, _stat, opts),
    do: pg_mark_error(pending, code, evidence, opts)

  defp sidecar_apply(pending, "finalized", evidence, code, stat, opts) do
    attrs = %{recovery_evidence: evidence}
    attrs = if code, do: Map.put(attrs, :last_error, code), else: attrs
    conclude(pending, "finalized", attrs, stat, opts)
  end

  # 只投影 canonical summary 里已被校验过的标量；`class` 当且仅当 outcome == "failed"。
  defp sidecar_finalize_evidence(outcome, class, summary) do
    base = %{
      "authority_mode" => "sidecar",
      "stage" => "finalize",
      "outcome" => outcome
    }

    projection = Map.new(@sidecar_projection_keys, &{&1, Map.get(summary, &1)})
    evidence = Map.merge(base, projection)

    if class, do: Map.put(evidence, "class", class), else: evidence
  end

  # §5.4 单一调用点校验器：观察到的 authority/源 phase、目标 phase/动作、精确的
  # 必需与允许键、outcome/class 组合、标量类型、outcome↔code 配对，以及共享的
  # durable JSON / 深度 / 65,536 字节闸门。拒绝即固定内部失败，零 SQL、零 raw 持久化。
  defp validate_sidecar_write(
         %Journal{authority_mode: "sidecar"} = journal,
         form,
         target,
         ev,
         code
       ) do
    with :ok <- validate_sidecar_source(form, journal.phase),
         :ok <- validate_sidecar_shape(form, ev),
         :ok <- validate_sidecar_target(form, target, ev["outcome"]),
         :ok <- validate_sidecar_code(form, ev["outcome"], ev["class"], code),
         true <- Journal.json_evidence_valid?(ev) do
      :ok
    else
      _invalid -> {:error, sidecar_contract_code(form)}
    end
  end

  defp validate_sidecar_write(_journal, form, _target, _ev, _code),
    do: {:error, sidecar_contract_code(form)}

  # 【I2】sidecar 写前契约拒绝的唯一 form→code 映射：对**合法 form 的封闭映射**，两个
  # 字面子句、无 catchall、无 `Atom.to_string/1`、无 raw 插值——意外 form 不会被兜底，
  # 也绝不会合成出动态 code。拒绝是**零 action SQL** 的 fail-closed 边界：既不隔离、
  # 不合成证据、不调用 `sidecar_apply/6`，也不写任何兜底行；`locked_apply/2` 收到 binary
  # 后只释放自己的租约、打同一个稳定 code 日志并返回公共稳定失败。该命名空间与 PG 的
  # `pg_contract_code/1` 完全独立。
  defp sidecar_contract_code(:current_epoch), do: "sidecar_current_epoch:contract_violation"
  defp sidecar_contract_code(:finalize), do: "sidecar_finalize:contract_violation"

  defp validate_sidecar_source(:current_epoch, "published"), do: :ok
  defp validate_sidecar_source(:finalize, "finalize_pending"), do: :ok
  defp validate_sidecar_source(_form, _phase), do: :error

  defp validate_sidecar_shape(:current_epoch, ev) do
    if Map.keys(ev) |> Enum.sort() == Enum.sort(@sidecar_base_keys) and
         ev["authority_mode"] == "sidecar" and ev["stage"] == "current_epoch" and
         ev["outcome"] in @sidecar_current_epoch_outcomes,
       do: :ok,
       else: :error
  end

  defp validate_sidecar_shape(:finalize, %{"outcome" => "contract_violation"} = ev) do
    if Map.keys(ev) |> Enum.sort() == Enum.sort(@sidecar_base_keys) and
         ev["authority_mode"] == "sidecar" and ev["stage"] == "finalize",
       do: :ok,
       else: :error
  end

  defp validate_sidecar_shape(:finalize, ev) do
    expected =
      Enum.sort(
        @sidecar_base_keys ++ @sidecar_projection_keys ++ sidecar_class_key(ev["outcome"])
      )

    with true <- Map.keys(ev) |> Enum.sort() == expected,
         true <- ev["authority_mode"] == "sidecar" and ev["stage"] == "finalize",
         true <- ev["outcome"] in @sidecar_finalize_outcomes,
         true <- sidecar_scalars_valid?(ev) do
      :ok
    else
      _invalid -> :error
    end
  end

  defp sidecar_class_key("failed"), do: ["class"]
  defp sidecar_class_key(_outcome), do: []

  defp sidecar_scalars_valid?(ev) do
    is_binary(ev["mode"]) and is_binary(ev["status"]) and
      Enum.all?(~w(required verified finalized debt unavailable omitted orphaned), fn key ->
        is_integer(ev[key]) and ev[key] >= 0
      end) and (is_nil(ev["class"]) or is_binary(ev["class"]))
  end

  defp validate_sidecar_target(:current_epoch, "quarantined", outcome),
    do: if(outcome in @sidecar_current_epoch_outcomes, do: :ok, else: :error)

  defp validate_sidecar_target(:finalize, "finalized", outcome)
       when outcome in ["finalized", "superseded"],
       do: :ok

  defp validate_sidecar_target(:finalize, "finalize_pending", outcome)
       when outcome in ["cleanup_pending", "failed"],
       do: :ok

  defp validate_sidecar_target(:finalize, "quarantined", outcome)
       when outcome in ["failed", "contract_violation"],
       do: :ok

  defp validate_sidecar_target(_form, _target, _outcome), do: :error

  defp validate_sidecar_code(:current_epoch, outcome, _class, code),
    do: if(code == "sidecar_current_epoch:#{outcome}", do: :ok, else: :error)

  defp validate_sidecar_code(:finalize, "finalized", _class, nil), do: :ok

  defp validate_sidecar_code(:finalize, "failed", class, code)
       when is_binary(class),
       do: if(code == "sidecar_finalize:#{class}", do: :ok, else: :error)

  defp validate_sidecar_code(:finalize, outcome, _class, code)
       when outcome in ["cleanup_pending", "superseded", "contract_violation"],
       do: if(code == "sidecar_finalize:#{outcome}", do: :ok, else: :error)

  defp validate_sidecar_code(_form, _outcome, _class, _code), do: :error

  # ── 冻结的 legacy restore-only 分类器（绝不处理 proof/finalize 结果）──

  # 证据矛盾类 → quarantine（终态，操作员经 B7 CLI 裁决）；其余 → mark_error 可重试。
  # 已带受保护证据的行改走 evidence-preserving 运维路径，绝不覆盖主失败证据。
  defp classify_restore_error(journal, stage, reason, opts) do
    cond do
      protected_evidence?(journal) ->
        operational_error(journal, @stable_restore_failed, opts)

      restore_quarantine_reason?(reason) ->
        quarantine_journal(journal, error_text(reason), error_evidence(stage, reason), opts)

      true ->
        retry_error(journal, reason, error_evidence(stage, reason), opts)
    end
  end

  defp restore_quarantine_reason?({:corrupt, _details}), do: true
  defp restore_quarantine_reason?({:placement_drift, _evidence}), do: true
  defp restore_quarantine_reason?({:invalid_placement_snapshot, _snapshot}), do: true
  defp restore_quarantine_reason?({:epoch_mismatch, _token}), do: true

  # rollback 途中却见 committed epoch：journal（可回滚 phase）与 epoch（已终结）矛盾。
  defp restore_quarantine_reason?(:epoch_committed), do: true
  defp restore_quarantine_reason?(_reason), do: false

  defp protected_evidence?(%Journal{recovery_evidence: evidence}), do: not is_nil(evidence)

  # ── §6 运维失败：evidence-preserving，绝不伪装成 proof 失败 ──

  # 【I1】通用 evidence-preserving 运维收敛。成功语义不变；CAS 输掉时**绝不**再伪造
  # `{:ok, :retried, ...}`，而是交给唯一的 convergence normalizer 折叠成稳定
  # `object_mutation:journal_convergence_failed`。raw CAS reason 在 normalizer 里一次性
  # 丢弃，绝不记录 / inspect / 持久化 / 返回。
  #
  # 本次职责调整**仅限 CAS 失败臂**：只有该臂把 best-effort 的自有租约释放与稳定日志
  # 委托给 `locked_apply/2`。成功臂仍照旧自行调用 `release_quietly/2` 释放租约；且既有的
  # lease-renewal 路径随后仍可能把稳定 lease 错误交回 `locked_apply/2`。因此这里不声称
  # `locked_apply/2` 是所有 operational_error 路径的唯一释放者。
  defp operational_error(journal, code, opts) do
    case ObjectMutation.mark_operational_error(journal, code, retry_opts(opts)) do
      {:ok, marked} ->
        {:ok, :retried, release_quietly(marked, opts)}

      {:error, reason} ->
        convergence_failure(reason)
    end
  end

  # evidence-preserving 隔离的唯一持久化收口（R7.1 canonical helper grammar）：
  # 直接 case 公共保全 API，成功臂只保留既有结构化错误日志 + 精确尾部，错误臂无任何
  # prelude，直接返回契约固定的稳定 convergence 结果。
  defp preserving_quarantine(journal, code, opts) do
    case ObjectMutation.quarantine_preserving_evidence(journal, code, journal_opts(opts)) do
      {:ok, quarantined} ->
        Log.error(
          "object mutation quarantined by recovery (evidence preserved; backup retained)",
          Log.journal_fields(quarantined,
            action: :object_mutation_quarantine,
            outcome: :quarantined,
            reason: code
          )
        )

        {:ok, :quarantined, quarantined}

      {:error, _reason} ->
        {:error, @stable_journal_convergence_failed}
    end
  end

  # ── journal 收敛动作 ──

  defp to_phase(%Journal{} = journal, phase, opts) do
    case ObjectMutation.transition(journal, phase, %{}, journal_opts(opts)) do
      {:ok, fresh} -> {:ok, fresh}
      {:error, reason} -> convergence_failure(reason)
    end
  end

  defp conclude(journal, target_phase, attrs, outcome, opts) do
    case ObjectMutation.transition(journal, target_phase, attrs, journal_opts(opts)) do
      {:ok, final} ->
        Log.info(
          "object mutation recovery decision applied",
          Log.journal_fields(final,
            action: :object_mutation_recovery_decision,
            outcome: outcome
          )
        )

        {:ok, outcome, final}

      {:error, reason} ->
        convergence_failure(reason)
    end
  end

  defp quarantine_journal(journal, reason, evidence, opts) do
    case ObjectMutation.quarantine(journal, reason, evidence, journal_opts(opts)) do
      {:ok, quarantined} ->
        Log.error(
          "object mutation quarantined by recovery (evidence conflict; backup retained)",
          Log.journal_fields(quarantined,
            action: :object_mutation_quarantine,
            outcome: :quarantined,
            reason: stable_reason(reason)
          )
        )

        {:ok, :quarantined, quarantined}

      {:error, q_reason} ->
        convergence_failure(q_reason)
    end
  end

  defp retry_error(journal, reason, evidence, opts) do
    mark_opts = journal_opts(opts) ++ Keyword.take(opts, [:backoff_ms])

    case ObjectMutation.mark_error(journal, reason, evidence, mark_opts) do
      {:ok, marked} ->
        released = release_quietly(marked, opts)

        Log.warn(
          "object mutation recovery retryable error (backoff; backup retained)",
          Log.journal_fields(released,
            action: :object_mutation_recovery_decision,
            outcome: :retried,
            reason: stable_reason(reason)
          )
        )

        {:ok, :retried, released}

      {:error, m_reason} ->
        convergence_failure(m_reason)
    end
  end

  # mark_error 保留 live lease（既有契约）——recovery 主动释放，backoff 到期即可被
  # 任意 worker 再领取。
  defp release_quietly(journal, opts) do
    case ObjectMutation.release_lease(journal, journal_opts(opts)) do
      {:ok, released} -> released
      {:error, _reason} -> journal
    end
  end

  # 按最新行释放仍属于本 worker 的租约（B6 审查项 3：journal_convergence_failed 分支的
  # 主动释放）——锁内 renew 已更新 lease_expires_at，用旧 struct 直接 release 恒 CAS 失败。
  # 终态/易主/已清空的租约一律不动（release_lease 的 identity CAS 是最终防线）。
  defp release_own_lease_quietly(%Journal{} = journal, opts) do
    case ObjectMutation.get(journal.id, journal_opts(opts)) do
      %Journal{lease_owner: owner} = fresh when is_binary(owner) ->
        if owner == journal.lease_owner, do: release_quietly(fresh, opts), else: fresh

      other ->
        other || journal
    end
  end

  # §3.2：只接受**已经归一**的稳定 binary code，绝不再经 `error_text/1` inspect。
  # 调用方（claim 边界与锁内收敛）必须先把 raw reason 折叠掉。
  defp log_no_action(journal, code) when is_binary(code) do
    Log.warn(
      "object mutation recovery took no action (lost race or journal moved)",
      Log.journal_fields(journal,
        action: :object_mutation_recovery_decision,
        outcome: :no_action,
        reason: code
      )
    )
  end

  # ── 证据构造（journal recovery_evidence 只收 string-key JSON，B3 审查项 2 +
  # 备忘 B3 节第 2 条：partial errors 含盘路径/端点与原始 term，落库前必须 stringify）──

  defp error_evidence(stage, reason) do
    merge_reason_evidence(%{"stage" => stage, "reason" => error_text(reason)}, reason)
  end

  defp merge_reason_evidence(base, {:partial, %{} = partial}) do
    Map.merge(base, %{
      "applied" => Map.get(partial, :applied),
      "superseded" => Map.get(partial, :superseded),
      "epoch_quorum" => Map.get(partial, :epoch_quorum),
      "endpoint_errors" =>
        Enum.map(Map.get(partial, :errors, []), fn {endpoint, term} ->
          %{"endpoint" => endpoint_text(endpoint), "reason" => error_text(term)}
        end)
    })
  end

  defp merge_reason_evidence(base, {:placement_drift, %{} = drift}) do
    Map.put(base, "placement_drift", stringify_map(drift))
  end

  defp merge_reason_evidence(base, _reason), do: base

  # superseded 收敛必须留痕（B2 审查项 2）；EC/Distributed 的 :superseded 返回值不含
  # successor token——另行 current_epoch 取证（B3 审查项 2）。best-effort：读不到也照常
  # 收敛（successor 事实由 backend epoch CAS 保证，evidence 只是取证）；backup 原地保留。
  defp superseded_evidence(stage, ctx, opts) do
    Map.merge(
      %{
        "stage" => stage,
        "outcome" => "superseded",
        "backup_dir" => MutationBackup.relative_dir(ctx.mutation_id)
      },
      successor_evidence(ctx, opts)
    )
  end

  defp successor_evidence(ctx, opts) do
    case Storage.current_epoch(ctx.target, storage_opts(opts)) do
      {:ok, %ObjectEpoch{} = epoch} ->
        %{
          "successor_generation" => epoch.token["generation"],
          "successor_mutation_id" => epoch.token["mutation_id"],
          "successor_phase" => epoch.phase
        }

      {:ok, :absent} ->
        %{"successor" => "absent"}

      {:error, reason} ->
        %{"successor" => error_text(reason)}
    end
  rescue
    error -> %{"successor" => error_text(error)}
  end

  # ── helpers ──

  defp bump(stats, key), do: Map.update!(stats, key, &(&1 + 1))

  defp lease_owner(opts) do
    Keyword.get_lazy(opts, :lease_owner, fn -> "#{node()}/#{inspect(self())}" end)
  end

  defp storage_opts(opts), do: Keyword.get(opts, :storage_opts, [])
  defp journal_opts(opts), do: Keyword.take(opts, [:repo, :now])
  defp retry_opts(opts), do: journal_opts(opts) ++ Keyword.take(opts, [:backoff_ms])
  defp lease_opts(opts), do: Keyword.take(opts, [:repo, :now, :lease_ms])

  defp endpoint_text(endpoint) when is_binary(endpoint), do: endpoint
  defp endpoint_text(endpoint), do: inspect(endpoint)

  defp stringify_map(map) do
    Map.new(map, fn {key, value} -> {to_string(key), json_safe(value)} end)
  end

  defp json_safe(value)
       when is_binary(value) or is_number(value) or is_boolean(value) or is_nil(value),
       do: value

  defp json_safe(value), do: inspect(value)

  defp error_text(reason) do
    reason
    |> inspect(limit: 50, printable_limit: @max_error_chars)
    |> String.slice(0, @max_error_chars)
  end

  # 日志 reason：已是稳定 code 的 binary 逐字保留（绝不被 inspect 加引号）；
  # 只有 legacy restore 分类器的结构化 term 才走 inspect。
  defp stable_reason(reason) when is_binary(reason), do: reason
  defp stable_reason(reason), do: error_text(reason)

  defp positive_int(value, _default) when is_integer(value) and value > 0, do: value
  defp positive_int(_value, default), do: default
end
