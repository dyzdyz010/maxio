defmodule Maxio.ObjectMutation.Commit do
  @moduledoc """
  对象变更的可复用 around-mutation seam（协议 2026-07-10 §0.2 十一步序列；Phase 1 仅普通
  PutObject 接入，Phase 2A 迁移其余 byte-producing 调用者时复用同一入口）。

  调用者（handler 的 `around_object_commit`，已持 `{bucket, key}` object lock）构造 `plan`
  并调 `run/1`；本模块负责 journal 生命周期与 backend epoch CAS 的编排：

      1. Storage.current_epoch（quorum 读，世代基数来源之一）
      2. generation = max(epoch generation, journal max_generation) + 1（legacy/absent 记 0）
      3. ObjectMutation.prepare（phase=prepared；journal id 即 mutation_id；60s 宽限防
         recovery 误扫健康 in-flight 请求，D5）
      4. Storage.claim_epoch（per-endpoint CAS + quorum；previous/placement_snapshot 回填）
      5. journal → claimed（attrs: previous_epoch = ObjectEpoch payload string-key 形状，
         placement_snapshot 原样 durable 写入）
      6. plan.publish（backend 内：manifest+backup 落 durable 目录 → epoch
         claimed→published(+fingerprint) → destructive rename）
      7. journal → published（attrs: published_fingerprint）
      8. plan.metadata_tx（内部 Repo.transaction，必须经 transaction_hook 调
         `commit_metadata_in_tx!/2`——journal metadata_committed 与 Objects/outbox/quota
         同一 PG 事务，CAS 失败即事务回滚）
      9–10. journal → finalize_pending → Storage.finalize_if_current → finalized
         （finalize 失败 mark_error，**请求仍成功**，recovery 收敛，协议 §5）
     11. Control.mark_committed（仅进程内加速器语义，journal 已 durable 之后）

  失败路径：claim 失败（无破坏性 IO）→ journal 直接 rolled_back；publish/metadata_tx
  失败 → `request_rollback` + best-effort `restore_if_current`（restore 失败 mark_error、
  backup 保留、recovery 兜底）。`metadata_committed` 是回滚禁止线——三层防线：journal
  状态图无回滚边 + `request_rollback` 前置拒绝（含 Control rollback guard）+ 端点
  `restore_mutation` 拒 committed epoch。

  Failpoint 挂点：`:object_mutation_before_metadata_commit`（步骤 8 前）、
  `:object_mutation_after_metadata_commit`（步骤 9）、`:object_mutation_finalize`
  （finalize 前）、`:object_mutation_restore`（restore 前）。

  ## operation 取值集合（Phase 2A D6；规范单一来源）

  journal/schema 层对 `operation` 仅约束非空，本清单即取值规范——取证时 operation 是
  唯一的 caller 判别器，新增取值必须先在此登记：

    * `"put"` —— PutObject / Console single-object upload；
    * `"copy"` —— CopyObject；
    * `"generated_put"` —— server-generated 对象（ObjectWriter、Inventory report、
      Access log delivery）；
    * `"replicate"` —— replication delivery；
    * `"rebalance_copy"` —— rebalance destination copy（placement 迁移语义：不挂
      notification/replication outbox、不动 is_latest）；
    * `"complete"` —— Multipart complete（put 分支与 assemble 分支同值）。

  ## caller 迁移契约（Phase 2A §0.1 六条公共不变量，每批独立 reviewer 逐条核对）

    1. `around_object_commit` **绝不能在 metadata 未提交时返回成功**——`run/1` 返回什么
       around 就返回什么（Control finalize 闭包重放会清 backup，B2 备忘 4）。
    2. `metadata_tx` 内部自行 `Repo.transaction` 且必须经 `commit_metadata_in_tx!/2`
       （推荐用 `transaction_hook/2` 组合 caller 附加 hook）：CAS 失败 `repo.rollback/1`
       整体回滚，closure 返回 `{:error, reason}` 不 raise；返回 ok 但未 CAS → 运行期
       `quarantine_contract_violation` 防线接管（PG 新行 + 旧字节分裂只能隔离取证）。
    3. 原「metadata 失败后 plain `Storage.delete`」调用点与函数本体**删除**，不留死代码
       （协议 §6：禁止 publish 后自行 plain delete）。
    4. `:sidecar` 写权威分支逐字节不变（D1：sidecar 协议化整体归 Phase 2B）。
    5. Failpoint 复用本模块既有挂点（上列四处，所有 caller 免费获得）；测试零
       `Process.sleep`。
    6. `:storage_opts` 必须来自 `Placement.storage_opts(write_info)` 写钉扎（B4 审查项 2）；
       每批仅跑聚焦测试 + `mix compile --warnings-as-errors`，完整 precommit 仅收口批一次。
  """

  alias Maxio.Failpoint
  alias Maxio.ObjectMutation
  alias Maxio.ObjectMutation.Journal
  alias Maxio.ObjectMutation.Log
  alias Maxio.Storage
  alias Maxio.Storage.EpochStore
  alias Maxio.Storage.MutationBackup
  alias Maxio.Storage.MutationContext
  alias Maxio.Storage.ObjectCommit.Control
  alias Maxio.Storage.ObjectEpoch

  # D5/R5：请求路径 journal 的 recovery 宽限（不得为 0——recovery 另持同一 object lock
  # 作第二道防线；测试用 opts[:now] 时间注入而非缩短宽限）。
  @initial_backoff_ms 60_000

  # metadata_committed 及之后：任何异常/DOWN 都只能 finalize/retry，绝不回滚（协议 §4）。
  @no_rollback_phases ~w(metadata_committed finalize_pending finalized)

  @max_error_chars 2_000

  @typedoc """
  编排计划（调用者已持 object lock）：

    * `:bucket` / `:key` / `:version_id` —— object_version target（Phase 1 唯一 kind）；
    * `:operation` —— 取值见 moduledoc「operation 取值集合」（D6）；`:authority_mode` ——
      恒 `"pg"`（D1：caller 侧已 gate `authoritative_source(:write) == :pg` 才进入）；
    * `:storage_opts` —— 透传给全部 backend epoch 调用；**必须与本次 put 的写落点一致**
      （Distributed 传 `Placement.storage_opts(write_info)` 的 placement 钉扎，保证
      current_epoch 与 claim_epoch 解析同一端点集，B4 审查项 2）；
    * `:write_info` —— ObjectCommit prepared map（含 `:object_commit_control`，用于
      rollback guard 与 mark_committed 加速器）；
    * `:publish` —— arity-1 闭包，接收追加的 commit_opts（本模块注入
      `object_mutation: %MutationContext{}`），内部恰好调用一次 ObjectCommit 的
      publish_fun；成功结果 map 必须含 `:epoch_fingerprint`（B2 契约）；
    * `:metadata_tx` —— arity-2 闭包 `(journal, published)`，内部自行 Repo.transaction
      并经 transaction_hook 调 `commit_metadata_in_tx!/2`；
    * `:backend`（可选）—— journal backend 字段，缺省 `inspect(Storage.backend())`。
  """
  @type plan :: %{
          :bucket => String.t(),
          :key => String.t(),
          :version_id => String.t(),
          :operation => String.t(),
          :authority_mode => String.t(),
          :storage_opts => keyword(),
          :write_info => map(),
          :publish => (keyword() -> {:ok, map()} | {:error, term()}),
          :metadata_tx => (Journal.t(), map() -> {:ok, term()} | {:error, term()}),
          optional(:backend) => String.t()
        }

  @doc "按 §0.2 序列执行一次协议化对象提交（operation 取值集合见 moduledoc，D6）。"
  @spec run(plan()) ::
          {:ok, %{journal: Journal.t(), published: map(), metadata: term()}} | {:error, term()}
  def run(plan) when is_map(plan) do
    storage_opts = Map.get(plan, :storage_opts, [])

    with {:ok, target} <- ObjectEpoch.object_target(plan.bucket, plan.key, plan.version_id),
         {:ok, generation} <- next_generation(plan, target, storage_opts),
         {:ok, journal} <- prepare_journal(plan, generation),
         {:ok, token} <- ObjectEpoch.token(generation, journal.id) do
      :ok = arm_rollback_guard(plan, journal.id)

      try do
        claim_phase(plan, target, token, journal, storage_opts)
      rescue
        error ->
          converge_after_exception(journal, storage_opts, error)
          reraise(error, __STACKTRACE__)
      catch
        kind, reason ->
          converge_after_exception(journal, storage_opts, {kind, reason})
          :erlang.raise(kind, reason, __STACKTRACE__)
      end
    end
  end

  @doc """
  metadata_tx 的 transaction_hook 内调用：journal CAS → metadata_committed，与
  Objects/outbox/quota 同一 Ecto 事务；CAS 失败 → `repo.rollback/1`（整个 metadata
  事务回滚，PG 无半提交）。
  """
  @spec commit_metadata_in_tx!(Journal.t(), module()) :: Journal.t()
  def commit_metadata_in_tx!(%Journal{} = journal, repo) do
    case ObjectMutation.transition(journal, "metadata_committed", %{}, repo: repo) do
      {:ok, committed} ->
        Log.info(
          "object mutation metadata committed",
          Log.journal_fields(committed, action: :object_mutation_metadata_commit, outcome: :ok)
        )

        committed

      {:error, reason} ->
        repo.rollback({:object_mutation_metadata_commit_failed, reason})
    end
  end

  @doc """
  构造可直接作 `Objects.put_version_with_id` 等 `:transaction_hook` 的组合器（Phase 2A
  C1 共享胶水，caller 迁移契约第 2 条的标准接入方式）：

  返回的 hook 在 metadata 事务内**先** `commit_metadata_in_tx!/2`（journal CAS →
  `metadata_committed`，与 Objects/outbox/quota 同一 PG 事务；CAS 失败 `repo.rollback/1`
  令整个事务回滚），**再**执行 `extra`（notification/replication enqueue 等 caller 附加
  hook），hook 返回值即 `extra` 的返回值（`extra = nil` 时返回 `:ok`）。

  `journal = nil` 时直通只跑 `extra`——兼容尚未迁移的调用者（Copy 等迁移前传 nil），
  行为逐字节不变。
  """
  @spec transaction_hook(Journal.t() | nil, (module(), term() -> term()) | nil) ::
          (module(), term() -> term())
  def transaction_hook(journal, extra \\ nil)

  def transaction_hook(nil, nil), do: fn _repo, _subject -> :ok end

  def transaction_hook(nil, extra) when is_function(extra, 2), do: extra

  def transaction_hook(%Journal{} = journal, nil) do
    fn repo, _subject ->
      _ = commit_metadata_in_tx!(journal, repo)
      :ok
    end
  end

  def transaction_hook(%Journal{} = journal, extra) when is_function(extra, 2) do
    fn repo, subject ->
      _ = commit_metadata_in_tx!(journal, repo)
      extra.(repo, subject)
    end
  end

  # ── 步骤 1–2：世代基数（epoch quorum 读 + journal 历史取 max，R4/B4 审查项 2）──

  defp next_generation(plan, target, storage_opts) do
    with {:ok, current} <- Storage.current_epoch(target, storage_opts) do
      journal_generation =
        ObjectMutation.max_generation(%{
          bucket_name: plan.bucket,
          object_key: plan.key,
          version_id: plan.version_id
        })

      {:ok, max(epoch_generation(current), journal_generation) + 1}
    end
  end

  # legacy final（meta.json 在、epoch absent）逻辑代际按协议记 0（R4）。
  defp epoch_generation(:absent), do: 0
  defp epoch_generation(%ObjectEpoch{token: %{"generation" => generation}}), do: generation

  # ── 步骤 3：prepared journal（id 即 mutation_id）──

  defp prepare_journal(plan, generation) do
    ObjectMutation.prepare(
      %{
        target_kind: "object_version",
        bucket_name: plan.bucket,
        object_key: plan.key,
        version_id: plan.version_id,
        generation: generation,
        operation: plan.operation,
        authority_mode: plan.authority_mode,
        backend: plan_backend(plan)
      },
      initial_backoff_ms: @initial_backoff_ms
    )
  end

  defp plan_backend(%{backend: backend}) when is_binary(backend), do: backend
  defp plan_backend(_plan), do: inspect(Storage.backend())

  # ── Control rollback guard（协议 §5：owner/publisher DOWN 只经 request_rollback，
  # 最终决定由 journal + backend CAS 作出）──

  defp arm_rollback_guard(%{write_info: %{object_commit_control: control}}, journal_id)
       when is_pid(control) do
    case Control.arm_rollback_guard(control, rollback_guard(journal_id)) do
      :ok ->
        :ok

      {:error, reason} ->
        # guard 装载失败（control 已收口）＝ 提交窗口已不存在；journal 由 recovery 收敛。
        Log.warn("object mutation rollback guard not armed",
          action: :object_mutation_rollback_requested,
          mutation_id: journal_id,
          outcome: :error,
          reason: inspect(reason)
        )
    end
  end

  defp arm_rollback_guard(_plan, _journal_id), do: :ok

  # guard 在 Control 进程内执行：journal CAS 通过（rollback_pending + next_attempt_at=now）
  # 才放行 backend restore 闭包；metadata_committed 及之后 halt——绝不回滚已提交的对象。
  defp rollback_guard(journal_id) do
    fn ->
      case ObjectMutation.get(journal_id) do
        nil ->
          {:halt, :journal_missing}

        %Journal{} = journal ->
          case ObjectMutation.request_rollback(journal) do
            {:ok, requested} ->
              Log.warn(
                "object mutation rollback requested by control",
                Log.journal_fields(requested,
                  action: :object_mutation_rollback_requested,
                  outcome: :ok,
                  reason: "control_down"
                )
              )

              :proceed

            {:error, reason} ->
              Log.warn(
                "object mutation rollback refused by journal",
                Log.journal_fields(journal,
                  action: :object_mutation_rollback_requested,
                  outcome: :refused,
                  reason: inspect(reason)
                )
              )

              {:halt, reason}
          end
      end
    end
  end

  # ── 步骤 4–5：claim + journal claimed ──

  defp claim_phase(plan, target, token, journal, storage_opts) do
    case Storage.claim_epoch(target, token, plan.operation, storage_opts) do
      {:ok, claim} ->
        Log.info(
          "object mutation epoch claimed",
          Log.journal_fields(journal, action: :object_mutation_claim, outcome: :ok)
        )

        claimed_phase(plan, journal, claim, storage_opts)

      {:error, reason} ->
        Log.warn(
          "object mutation epoch claim failed",
          Log.journal_fields(journal,
            action: :object_mutation_claim,
            outcome: :error,
            reason: inspect(reason)
          )
        )

        abandon_unclaimed(journal, reason)
    end
  end

  # claim 未达成：我们不持有 epoch、无任何破坏性 IO——journal 直接收敛 rolled_back。
  # 少数端点可能已写入 claimed epoch：fence 单调性保证无害（后继 claim 取 max+1），
  # 绝不做猜测式 restore（nil/:enoent 不当授权）。
  defp abandon_unclaimed(journal, reason) do
    with {:ok, pending} <-
           ObjectMutation.transition(journal, "rollback_pending", %{
             last_error: error_text(reason)
           }),
         {:ok, rolled} <- ObjectMutation.transition(pending, "rolled_back") do
      Log.warn(
        "object mutation rolled back before claim",
        Log.journal_fields(rolled,
          action: :object_mutation_rollback_result,
          outcome: :rolled_back
        )
      )
    else
      {:error, journal_error} ->
        Log.error(
          "object mutation journal convergence failed after claim failure",
          Log.journal_fields(journal,
            action: :object_mutation_rollback_result,
            outcome: :error,
            reason: inspect(journal_error)
          )
        )
    end

    {:error, reason}
  end

  defp claimed_phase(plan, journal, claim, storage_opts) do
    with {:ok, attrs} <- claimed_attrs(claim),
         {:ok, claimed} <- ObjectMutation.transition(journal, "claimed", attrs),
         {:ok, ctx} <- MutationContext.from_journal(claimed) do
      publish_phase(plan, ctx, claimed, storage_opts)
    else
      {:error, reason} ->
        # claim 已写下我们的 claimed epoch：restore 收敛（claimed → rolled_back，
        # 无 manifest 时仅翻转 epoch），失败 mark_error 交 recovery。
        rollback_requested(journal, {:claimed_transition_failed, reason}, storage_opts)
    end
  end

  # 冻结 journal previous_epoch 持久形状 = ObjectEpoch encode 的 string-key JSON payload
  # （B2 审查项 3：backend 侧 previous_epoch_token/1 只认 %{"token" => _}）；
  # placement_snapshot（B4）已是 durable string-key 形状，原样写入。
  defp claimed_attrs(claim) do
    with {:ok, previous} <- previous_epoch_payload(Map.get(claim, :previous)) do
      attrs =
        %{}
        |> maybe_put(:previous_epoch, previous)
        |> maybe_put(:placement_snapshot, Map.get(claim, :placement_snapshot))

      {:ok, attrs}
    end
  end

  defp previous_epoch_payload(nil), do: {:ok, nil}
  defp previous_epoch_payload(%ObjectEpoch{} = previous), do: EpochStore.payload(previous)

  # ── 步骤 6–7：publish + journal published ──

  defp publish_phase(plan, ctx, journal, storage_opts) do
    case plan.publish.(object_mutation: ctx) do
      {:ok, published} ->
        published_transition(plan, ctx, journal, published, storage_opts)

      {:error, reason} ->
        Log.warn(
          "object mutation publish failed",
          Log.journal_fields(journal,
            action: :object_mutation_publish,
            outcome: :error,
            reason: inspect(reason)
          )
        )

        rollback_requested(journal, reason, storage_opts)
    end
  end

  defp published_transition(plan, ctx, journal, published, storage_opts) do
    with {:ok, fingerprint} <- published_fingerprint(published),
         {:ok, journal} <-
           ObjectMutation.transition(journal, "published", %{published_fingerprint: fingerprint}) do
      Log.info(
        "object mutation published",
        Log.journal_fields(journal, action: :object_mutation_publish, outcome: :ok)
      )

      metadata_phase(plan, ctx, journal, published, storage_opts)
    else
      {:error, reason} ->
        rollback_requested(journal, {:published_transition_failed, reason}, storage_opts)
    end
  end

  # 后端契约（B2）：协议 publish 成功结果必须回传 :epoch_fingerprint——缺失即契约违约，
  # 立即回滚，绝不带着未知 fingerprint 进 metadata 提交。
  defp published_fingerprint(%{epoch_fingerprint: fingerprint}), do: {:ok, fingerprint}
  defp published_fingerprint(published), do: {:error, {:missing_epoch_fingerprint, published}}

  # ── 步骤 8–11：metadata 同事务 + finalize + 加速器 ──

  defp metadata_phase(plan, ctx, journal, published, storage_opts) do
    Failpoint.hit(:object_mutation_before_metadata_commit)

    case plan.metadata_tx.(journal, published) do
      {:ok, metadata} ->
        after_metadata_commit(plan, ctx, journal, published, metadata, storage_opts)

      {:error, reason} ->
        Log.warn(
          "object mutation metadata transaction failed",
          Log.journal_fields(journal,
            action: :object_mutation_metadata_commit,
            outcome: :error,
            reason: inspect(reason)
          )
        )

        rollback_requested(journal, reason, storage_opts)
    end
  end

  defp after_metadata_commit(plan, ctx, journal, published, metadata, storage_opts) do
    case refetch(journal) do
      %Journal{phase: phase} = fresh when phase in @no_rollback_phases ->
        Failpoint.hit(:object_mutation_after_metadata_commit)
        finalized = finalize_phase(ctx, fresh, storage_opts)
        accelerate_mark_committed(plan, finalized)
        {:ok, %{journal: finalized, published: published, metadata: metadata}}

      fresh ->
        # metadata_tx 契约违约：PG 事务已提交但 journal 未经 commit_metadata_in_tx! 同事务
        # 推进。自动回滚会造成「PG 新行 + 旧字节」永久分裂——唯一安全动作是隔离取证
        # （字节保留、backup 保留、操作员经 CLI 裁决）。
        quarantine_contract_violation(journal, fresh)
    end
  end

  defp quarantine_contract_violation(journal, fresh) do
    actual_phase = fresh && fresh.phase

    evidence = %{
      "stage" => "metadata_commit",
      "expected_phase" => "metadata_committed",
      "actual_phase" => actual_phase
    }

    case ObjectMutation.quarantine(fresh || journal, :metadata_commit_not_journaled, evidence) do
      {:ok, quarantined} ->
        Log.error(
          "object mutation quarantined: metadata committed without journal CAS",
          Log.journal_fields(quarantined,
            action: :object_mutation_quarantine,
            outcome: :quarantined,
            reason: "metadata_commit_not_journaled"
          )
        )

      {:error, reason} ->
        Log.error(
          "object mutation quarantine failed after metadata contract violation",
          Log.journal_fields(journal,
            action: :object_mutation_quarantine,
            outcome: :error,
            reason: inspect(reason)
          )
        )
    end

    {:error, {:metadata_commit_not_journaled, actual_phase}}
  end

  # 步骤 10：finalize 失败绝不失败请求（metadata 已权威提交，协议 §5）；:superseded
  # （后继已建立）同样收敛为 finalized + evidence（B6 决策表同源）。
  defp finalize_phase(_ctx, %Journal{phase: "finalized"} = journal, _storage_opts), do: journal

  defp finalize_phase(ctx, journal, storage_opts) do
    case ObjectMutation.transition(journal, "finalize_pending") do
      {:ok, pending} ->
        run_finalize(ctx, pending, storage_opts)

      {:error, reason} ->
        Log.error(
          "object mutation finalize_pending transition failed (recovery converges)",
          Log.journal_fields(journal,
            action: :object_mutation_finalize,
            outcome: :error,
            reason: inspect(reason)
          )
        )

        journal
    end
  end

  defp run_finalize(ctx, journal, storage_opts) do
    Failpoint.hit(:object_mutation_finalize)

    case Storage.finalize_if_current(ctx, storage_opts) do
      {:ok, :finalized} ->
        conclude_finalized(journal, %{}, :finalized)

      {:ok, :superseded} ->
        conclude_finalized(
          journal,
          %{recovery_evidence: superseded_evidence("finalize", ctx)},
          :superseded
        )

      {:error, reason} ->
        finalize_failed(journal, reason)
    end
  rescue
    error -> finalize_failed(journal, error)
  end

  defp conclude_finalized(journal, attrs, outcome) do
    case ObjectMutation.transition(journal, "finalized", attrs) do
      {:ok, finalized} ->
        Log.info(
          "object mutation finalized",
          Log.journal_fields(finalized, action: :object_mutation_finalize, outcome: outcome)
        )

        finalized

      {:error, reason} ->
        Log.error(
          "object mutation finalized transition failed (recovery converges)",
          Log.journal_fields(journal,
            action: :object_mutation_finalize,
            outcome: :error,
            reason: inspect(reason)
          )
        )

        journal
    end
  end

  defp finalize_failed(journal, reason) do
    Log.error(
      "object mutation finalize failed (request still succeeds; recovery converges)",
      Log.journal_fields(journal,
        action: :object_mutation_finalize,
        outcome: :error,
        reason: inspect(reason)
      )
    )

    case ObjectMutation.mark_error(journal, reason, %{"stage" => "finalize"}) do
      {:ok, marked} -> marked
      {:error, _mark_reason} -> journal
    end
  end

  # 步骤 11：仅进程内加速器（协议 §5：只能在 journal 已 durable
  # metadata_committed/finalize_pending/finalized 之后调用）；失败只记日志——
  # correctness 由 journal + recovery 保证。
  defp accelerate_mark_committed(%{write_info: %{object_commit_control: control}}, journal)
       when is_pid(control) do
    case Control.mark_committed(control) do
      :ok ->
        :ok

      {:error, reason} ->
        Log.error(
          "object commit control mark_committed failed after durable journal",
          Log.journal_fields(journal,
            action: :object_mutation_finalize,
            outcome: :error,
            reason: inspect(reason)
          )
        )
    end
  end

  defp accelerate_mark_committed(_plan, _journal), do: :ok

  # ── 失败路径：request_rollback + best-effort restore（协议 §5）──

  # refetch 后再请求：并发扰动（mark_error 等）下用最新行提高收敛率；restore 失败
  # mark_error 留给 recovery（backup 保留，不猜测、不破坏）。
  defp rollback_requested(journal, reason, storage_opts) do
    journal = refetch(journal) || journal

    case ObjectMutation.request_rollback(journal) do
      {:ok, requested} ->
        Log.warn(
          "object mutation rollback requested",
          Log.journal_fields(requested,
            action: :object_mutation_rollback_requested,
            outcome: :ok,
            reason: inspect(reason)
          )
        )

        attempt_restore(requested, storage_opts)

      {:error, {:illegal_transition, from, _to}} ->
        Log.error(
          "object mutation rollback refused (metadata_committed no-rollback line)",
          Log.journal_fields(journal,
            action: :object_mutation_rollback_requested,
            outcome: :refused,
            reason: inspect({:illegal_transition, from, "rollback_pending"})
          )
        )

      {:error, request_error} ->
        Log.error(
          "object mutation rollback request failed (recovery converges)",
          Log.journal_fields(journal,
            action: :object_mutation_rollback_requested,
            outcome: :error,
            reason: inspect(request_error)
          )
        )
    end

    {:error, reason}
  end

  defp attempt_restore(journal, storage_opts) do
    case MutationContext.from_journal(journal) do
      {:ok, ctx} ->
        Failpoint.hit(:object_mutation_restore)
        apply_restore(ctx, journal, storage_opts)

      {:error, reason} ->
        restore_failed(journal, reason)
    end
  rescue
    error -> restore_failed(journal, error)
  end

  defp apply_restore(ctx, journal, storage_opts) do
    case Storage.restore_if_current(ctx, storage_opts) do
      {:ok, :restored} ->
        conclude_rolled_back(journal, %{}, :rolled_back)

      {:ok, :superseded} ->
        # B2 审查项 2：superseded 收敛必须记录 evidence（successor 已建立、final 未被本次
        # 触碰；backup 原地保留可取证）。
        conclude_rolled_back(
          journal,
          %{recovery_evidence: superseded_evidence("restore", ctx)},
          :superseded
        )

      {:error, reason} ->
        restore_failed(journal, reason)
    end
  end

  defp conclude_rolled_back(journal, attrs, outcome) do
    case ObjectMutation.transition(journal, "rolled_back", attrs) do
      {:ok, rolled} ->
        Log.warn(
          "object mutation rolled back",
          Log.journal_fields(rolled, action: :object_mutation_rollback_result, outcome: outcome)
        )

      {:error, reason} ->
        Log.error(
          "object mutation rolled_back transition failed (recovery converges)",
          Log.journal_fields(journal,
            action: :object_mutation_rollback_result,
            outcome: :error,
            reason: inspect(reason)
          )
        )
    end

    :ok
  end

  defp restore_failed(journal, reason) do
    Log.error(
      "object mutation restore failed (backup retained; recovery converges)",
      Log.journal_fields(journal,
        action: :object_mutation_rollback_result,
        outcome: :error,
        reason: inspect(reason)
      )
    )

    case ObjectMutation.mark_error(journal, reason, %{"stage" => "restore"}) do
      {:ok, _marked} -> :ok
      {:error, _mark_reason} -> :ok
    end
  end

  # 未捕获异常（含 failpoint 注入）收敛：按 journal 最新 phase 决定——metadata_committed
  # 及之后绝不回滚（新字节保留，recovery finalize）；之前 request_rollback + best-effort
  # restore。随后调用方原样 reraise（外层 ObjectCommit 的 rollback 经 Control guard 幂等收敛）。
  defp converge_after_exception(journal, storage_opts, error) do
    case refetch(journal) do
      nil ->
        Log.error("object mutation journal missing after exception",
          action: :object_mutation_rollback_requested,
          mutation_id: journal.id,
          outcome: :error,
          reason: inspect(error)
        )

      %Journal{phase: phase} = fresh when phase in @no_rollback_phases ->
        Log.error(
          "object mutation crashed after metadata commit (no rollback; recovery finalizes)",
          Log.journal_fields(fresh,
            action: :object_mutation_rollback_requested,
            outcome: :refused,
            reason: inspect(error)
          )
        )

      %Journal{} = fresh ->
        _ = rollback_requested(fresh, {:exception, inspect(error)}, storage_opts)
    end

    :ok
  end

  defp superseded_evidence(stage, ctx) do
    %{
      stage => "superseded",
      "backup_dir" => MutationBackup.relative_dir(ctx.mutation_id)
    }
  end

  defp refetch(%Journal{id: id}), do: ObjectMutation.get(id)

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp error_text(reason) do
    reason
    |> inspect(limit: 50, printable_limit: @max_error_chars)
    |> String.slice(0, @max_error_chars)
  end
end
