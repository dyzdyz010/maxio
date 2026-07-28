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
  alias Maxio.Storage
  alias Maxio.Storage.MutationBackup
  alias Maxio.Storage.MutationContext
  alias Maxio.Storage.ObjectEpoch

  @finalize_phases ~w(metadata_committed finalize_pending)
  @sidecar_finalize_epoch_phases ~w(published committed)
  # 对象锁被健康 in-flight 请求持有时的短 backoff（区别于 mark_error 默认 60s：锁窗口
  # 正常毫秒级，快速重试即可收敛）。
  @default_locked_backoff_ms 5_000
  @max_error_chars 2_000

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
    case ObjectMutation.claim(journal, lease_owner(opts), lease_opts(opts)) do
      {:ok, claimed} -> locked_apply(claimed, opts)
      {:error, reason} -> {:claim_failed, reason}
    end
  end

  # fun 在 Lock 的独立 worker 进程内执行（shared sandbox 兼容，R1）；进锁后先 renew
  # （锁获取的重试耗时不侵蚀租约），renew 失败即另一 worker 已接管——放手不动。
  defp locked_apply(journal, opts) do
    resource = {journal.bucket_name, journal.object_key}

    lock_result =
      Lock.with_object_lock(resource, fn ->
        case ObjectMutation.renew_lease(journal, lease_opts(opts)) do
          {:ok, fresh} -> safe_decide(fresh, opts)
          {:error, reason} -> {:error, {:lease_lost, reason}}
        end
      end)

    case lock_result do
      {:ok, {:ok, outcome, final}} ->
        {:ok, outcome, final}

      {:ok, {:error, reason}} ->
        # 锁内收敛 CAS 失败（journal 被并发推进 / 租约易主）：本 worker 不再动 journal，
        # 但要主动释放仍属于自己的租约（B6 审查项 3——否则只能等 60s 过期自愈，纯
        # liveness 延迟）。锁内 renew 可能已更新过期时刻，须按最新行判定；租约已易主
        # 则绝不触碰（接管者负责自己的租约）。
        _ = release_own_lease_quietly(journal, opts)
        log_no_action(journal, reason)
        {:stale, reason}

      {:error, :locked} ->
        handle_locked(journal, opts)
    end
  end

  # 对象锁被健康 in-flight 请求持有：短 backoff 跳过（mark_error 只涨 attempts / 推迟
  # next_attempt_at，不改 phase），租约立即释放——绝不与活请求争抢，也绝不误回滚（R5）。
  defp handle_locked(journal, opts) do
    backoff_ms = positive_int(Keyword.get(opts, :locked_backoff_ms), @default_locked_backoff_ms)
    evidence = %{"stage" => "recovery", "reason" => "object_locked"}
    mark_opts = journal_opts(opts) ++ [backoff_ms: backoff_ms]

    journal =
      case ObjectMutation.mark_error(journal, :object_locked, evidence, mark_opts) do
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

  # 决策执行的异常兜底：任何未预期异常折叠为可重试 mark_error（backup 保留，不猜测、
  # 不破坏），绝不让单条 journal 的异常终止整轮 drain。
  defp safe_decide(journal, opts) do
    case MutationContext.from_journal(journal) do
      {:ok, ctx} ->
        decide(journal, ctx, opts)

      {:error, reason} ->
        # journal 行无法派生执行上下文＝持久数据自身矛盾——隔离取证。
        quarantine_journal(journal, reason, error_evidence("context", reason), opts)
    end
  rescue
    error ->
      retry_error(
        journal,
        {:recovery_exception, Exception.message(error)},
        error_evidence("recovery", Exception.message(error)),
        opts
      )
  end

  # ── 决策表（每个动作前后均 journal CAS，天然幂等）──

  # pg 的 metadata_committed / finalize_pending：唯一合法方向是 finalize
  # （协议 §4 metadata_committed 禁回滚线）。
  defp decide(%Journal{phase: phase} = journal, ctx, opts) when phase in @finalize_phases,
    do: finalize_flow(journal, ctx, opts)

  # sidecar published：backend epoch 达 published quorum 即 logical authority commit——
  # 必须 finalize，不得因 journal 未 metadata_committed 而 rollback（协议 §4；journal
  # 状态机 @sidecar_published_targets 已禁 rollback 兜底）。
  defp decide(%Journal{phase: "published", authority_mode: "sidecar"} = journal, ctx, opts),
    do: sidecar_published_flow(journal, ctx, opts)

  defp decide(%Journal{phase: "published"} = journal, ctx, opts),
    do: rollback_flow(journal, ctx, opts)

  defp decide(%Journal{phase: phase} = journal, ctx, opts) when phase in ~w(prepared claimed),
    do: rollback_flow(journal, ctx, opts)

  defp decide(%Journal{phase: "rollback_pending"} = journal, ctx, opts),
    do: restore_flow(journal, ctx, opts, "rollback_pending")

  defp finalize_flow(journal, ctx, opts) do
    with {:ok, pending} <- to_phase(journal, "finalize_pending", opts) do
      case Storage.finalize_if_current(ctx, storage_opts(opts)) do
        {:ok, :finalized} ->
          conclude(pending, "finalized", %{}, :finalized, opts)

        {:ok, :superseded} ->
          conclude(
            pending,
            "finalized",
            %{recovery_evidence: superseded_evidence("finalize", ctx, opts)},
            :superseded,
            opts
          )

        {:error, reason} ->
          classify_error(pending, "finalize", reason, opts)
      end
    end
  end

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
        classify_error(journal, "restore", reason, opts)
    end
  end

  # sidecar-authority published 的裁决：只认 durable epoch（协议 §4）。
  defp sidecar_published_flow(journal, ctx, opts) do
    case Storage.current_epoch(ctx.target, storage_opts(opts)) do
      {:ok, %ObjectEpoch{token: token, phase: phase}}
      when token == ctx.token and phase in @sidecar_finalize_epoch_phases ->
        finalize_flow(journal, ctx, opts)

      {:ok, %ObjectEpoch{} = epoch} ->
        sidecar_epoch_conflict(journal, ctx, epoch, opts)

      # journal 声称 published quorum 已达成，epoch 却缺失/不可读——证据不足 quorum，
      # 不猜测、不破坏（计划 B6 决策表：epoch 不足 quorum → quarantine）。
      {:ok, :absent} ->
        quarantine_journal(
          journal,
          :sidecar_epoch_missing,
          %{"stage" => "sidecar_finalize", "reason" => "epoch_absent"},
          opts
        )

      {:error, reason} ->
        quarantine_journal(
          journal,
          {:sidecar_epoch_unreadable, reason},
          error_evidence("sidecar_finalize", reason),
          opts
        )
    end
  end

  # successor 已建立 → finalize_if_current 折叠 :superseded（与 pg 路径同源收敛）；
  # 其余（本 token 却非 published/committed、或更旧 token）均为 journal 与 epoch 矛盾。
  defp sidecar_epoch_conflict(journal, ctx, epoch, opts) do
    case ObjectEpoch.compare_tokens(epoch.token, ctx.token) do
      {:ok, :gt} ->
        finalize_flow(journal, ctx, opts)

      _other ->
        quarantine_journal(
          journal,
          {:sidecar_epoch_conflict, epoch.token},
          %{
            "stage" => "sidecar_finalize",
            "epoch_phase" => epoch.phase,
            "epoch_generation" => epoch.token["generation"],
            "epoch_mutation_id" => epoch.token["mutation_id"]
          },
          opts
        )
    end
  end

  # ── 错误分类（实现计划 B6 决策表末行）──

  # 证据矛盾类 → quarantine（终态，操作员经 B7 CLI 裁决）；其余 → mark_error 可重试。
  defp classify_error(journal, stage, reason, opts) do
    if quarantine_reason?(reason) do
      quarantine_journal(journal, reason, error_evidence(stage, reason), opts)
    else
      retry_error(journal, reason, error_evidence(stage, reason), opts)
    end
  end

  defp quarantine_reason?({:corrupt, _details}), do: true
  defp quarantine_reason?({:placement_drift, _evidence}), do: true
  defp quarantine_reason?({:invalid_placement_snapshot, _snapshot}), do: true
  defp quarantine_reason?({:epoch_mismatch, _token}), do: true

  # rollback 途中却见 committed epoch：journal（可回滚 phase）与 epoch（已终结）矛盾。
  defp quarantine_reason?(:epoch_committed), do: true
  defp quarantine_reason?(_reason), do: false

  # ── journal 收敛动作 ──

  defp to_phase(%Journal{} = journal, phase, opts) do
    case ObjectMutation.transition(journal, phase, %{}, journal_opts(opts)) do
      {:ok, fresh} -> {:ok, fresh}
      {:error, reason} -> {:error, {:journal_convergence_failed, reason}}
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
        {:error, {:journal_convergence_failed, reason}}
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
            reason: error_text(reason)
          )
        )

        {:ok, :quarantined, quarantined}

      {:error, q_reason} ->
        {:error, {:journal_convergence_failed, q_reason}}
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
            reason: error_text(reason)
          )
        )

        {:ok, :retried, released}

      {:error, m_reason} ->
        {:error, {:journal_convergence_failed, m_reason}}
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

  defp log_no_action(journal, reason) do
    Log.warn(
      "object mutation recovery took no action (lost race or journal moved)",
      Log.journal_fields(journal,
        action: :object_mutation_recovery_decision,
        outcome: :no_action,
        reason: error_text(reason)
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

  defp positive_int(value, _default) when is_integer(value) and value > 0, do: value
  defp positive_int(_value, default), do: default
end
