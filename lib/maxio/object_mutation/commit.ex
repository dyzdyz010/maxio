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
      9–10. journal → finalize_pending → Storage.finalize_if_current → 已规范化 disposition
         （**只有** finalized 与 cleanup-pending 是请求成功类；unavailable/integrity/
         superseded/契约违约各自返回固定结构化错误。metadata 已权威提交，故任何
         disposition 都绝不回滚，recovery 收敛，协议 §5）
     11. Control.mark_committed（仅进程内加速器语义，journal 已 durable 之后）

  失败路径：claim 失败（无破坏性 IO）→ journal 直接 rolled_back；publish/metadata_tx
  失败 → `request_rollback` + best-effort `restore_if_current`。`metadata_committed` 是
  回滚禁止线——三层防线：journal 状态图无回滚边 + `request_rollback` 前置拒绝（含 Control
  rollback guard）+ 端点 `restore_mutation` 拒 committed epoch。

  ## Publish 与 finalize 的收口契约（G2 Green review correction R1）

    * claimed→published 是**原子**持久化：`published_fingerprint` 与 canonical wrapper
      在同一次 CAS 里写入，绝不分两步；
    * 只有 `finalized` 与 `cleanup_pending` 两个已规范化 disposition 属于**请求成功**类；
    * 其余已规范化 disposition（unavailable / integrity / superseded / callback 契约违约）
      一律返回各自**固定的结构化错误**，metadata 已提交故绝不回滚；
    * 纯 evidence builder / merge 拒绝是**内部 durable 契约违约**，返回固定的
      `{:published_proof_contract_violation, _mode}`，绝不返回原 backend union；
    * restore 失败是 log-only 的次生运维失败：主失败证据的 term/JSON 字节与主稳定 code
      逐字保留，backup 原样保留；
    * `:object_mutation_after_publish_before_proof` 是**正式挂点**（proof 之前）；
    * 步骤 11 的显式 `Control.mark_committed/1` 加速器**只**跟在已确认的 finalized 终态
      写入或已确认的 cleanup-pending 欠债写入之后；写丢失兜底、编排错误与任何错误
      disposition 一律 defer，永远进不了加速器。

  Failpoint 挂点：`:object_mutation_before_metadata_commit`（步骤 8 前）、
  `:object_mutation_after_metadata_commit`（步骤 9）、`:object_mutation_finalize`
  （finalize 前）、`:object_mutation_after_publish_before_proof`（proof 前）、
  `:object_mutation_restore`（restore 前）。

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
  alias Maxio.ObjectMutation.StorageDisposition
  alias Maxio.Storage
  alias Maxio.Storage.EpochStore
  alias Maxio.Storage.MutationBackup
  alias Maxio.Storage.MutationContext
  alias Maxio.Storage.ObjectCommit.Control
  alias Maxio.Storage.ObjectEpoch
  alias Maxio.Storage.PublishedProof

  # D5/R5：请求路径 journal 的 recovery 宽限（不得为 0——recovery 另持同一 object lock
  # 作第二道防线；测试用 opts[:now] 时间注入而非缩短宽限）。
  @initial_backoff_ms 60_000

  # metadata_committed 及之后：任何异常/DOWN 都只能 finalize/retry，绝不回滚（协议 §4）。
  @no_rollback_phases ~w(metadata_committed finalize_pending finalized)

  @max_error_chars 2_000

  # G1/G2 冻结的稳定 code 与两个精确 generic PG 证据形状（design D2 / G2 §5.3）。
  # Commit 只做「已规范化 disposition class → 稳定 journal code」的映射，这是 journal
  # 策略，不是第二个 backend 结果分类器。
  @stable_proof_superseded "published_proof_superseded:proof"
  @stable_proof_contract_violation "published_proof_contract_violation:proof"
  @stable_journal_transition "published_proof_journal_transition:failed"
  @stable_finalize_superseded "published_proof_superseded:finalize"
  @stable_finalize_cleanup_pending "published_proof_cleanup_pending:finalize"
  @stable_finalize_contract_violation "published_proof_contract_violation:finalize"
  @stable_finalize_orchestration_error "object_mutation_finalize:orchestration_error"
  @stable_restore_failed "object_mutation:restore_failed"

  # durable-finalize-outcome seam 的唯一固定写丢失标量：绝不记录/返回/持久化
  # inspect(reason)、SQL、changeset、raw evidence、callback term、path、node、drive、
  # endpoint 或 stacktrace。
  @stable_finalize_write_loss "object_mutation_finalize:durable_outcome_write_failed"

  # 行缺失、畸形或处于不兼容终态时的固定内部信封（绝不加速）。
  @finalize_outcome_internal {:object_mutation_journal, :internal, :finalize_outcome}

  # 合法可恢复的赢家状态：保留原请求语义、defer、交 Recovery 收敛。
  @recoverable_finalize_phases ~w(metadata_committed finalize_pending)

  # correction R2 §4.1：单一 exact-field 清单，供所有 intent 的完整标量证明复用，
  # 禁止在每个分支复制不同的字段列表。
  @journal_fields ~w(
    id target_kind bucket_name object_key version_id upload_id part_number generation
    operation authority_mode phase backend placement_snapshot previous_epoch
    published_fingerprint recovery_evidence attempts next_attempt_at lease_owner
    lease_expires_at last_error metadata_committed_at finalized_at rolled_back_at
    quarantined_at inserted_at updated_at
  )a

  # mutation identity：任何 durable 动作都绝不允许改动它们。
  @identity_fields ~w(
    id target_kind bucket_name object_key version_id upload_id part_number generation
    operation authority_mode backend placement_snapshot previous_epoch inserted_at
  )a

  @contract_violation_evidence %{
    "authority_mode" => "pg",
    "stage" => "verify_published",
    "outcome" => "contract_violation",
    "mode" => "proof"
  }

  @journal_transition_evidence %{
    "authority_mode" => "pg",
    "stage" => "journal_publish",
    "outcome" => "transition_failed"
  }

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
          case ObjectMutation.request_rollback(journal, %{}) do
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

  # G2 §5.2：publish 之后的固定顺序
  #   enrich ctx → failpoint → verify_published → StorageDisposition.proof/1 →
  #   journal_evidence → 原子 claimed→published(fingerprint + wrapper) → fresh journal ctx
  #
  # `ctx` 是原始 claimed context，只用于 pre-metadata restore；backend 拥有的 Control
  # finalize 闭包保持不变，Commit 绝不替换或重新注册它。
  defp published_transition(plan, %MutationContext{} = ctx, journal, published, storage_opts) do
    case published_fingerprint(published) do
      {:ok, fingerprint} ->
        proof_ctx = %MutationContext{ctx | published_fingerprint: fingerprint}
        Failpoint.hit(:object_mutation_after_publish_before_proof)

        proof_ctx
        |> Storage.verify_published(storage_opts)
        |> StorageDisposition.proof()
        |> handle_proof(plan, ctx, journal, published, fingerprint, storage_opts)

      {:error, reason} ->
        rollback_requested(journal, {:published_transition_failed, reason}, storage_opts)
    end
  end

  # proof 通过：把 canonical wrapper 与 fingerprint 在**同一次** CAS 里写入 published。
  defp handle_proof(
         {:proof_passed, class, summary},
         plan,
         ctx,
         journal,
         published,
         fingerprint,
         storage_opts
       ) do
    case PublishedProof.journal_evidence("published", summary, nil) do
      {:ok, wrapper} ->
        attrs = %{published_fingerprint: fingerprint, recovery_evidence: wrapper}

        case ObjectMutation.transition(journal, "published", attrs) do
          {:ok, journal} ->
            Log.info(
              "object mutation published",
              Log.journal_fields(journal,
                action: :object_mutation_publish,
                outcome: :ok,
                proof_mode: "proof",
                proof_class: Atom.to_string(class)
              )
              |> Keyword.merge(proof_scalars(summary))
            )

            # 从 fresh published journal 重建 context，供 metadata 与直接 finalize 使用。
            case MutationContext.from_journal(journal) do
              {:ok, fresh_ctx} ->
                metadata_phase(plan, ctx, fresh_ctx, journal, published, storage_opts)

              {:error, reason} ->
                publish_transition_lost(journal, ctx, reason, storage_opts)
            end

          {:error, reason} ->
            publish_transition_lost(journal, ctx, reason, storage_opts)
        end

      {:error, reason} ->
        publish_transition_lost(journal, ctx, reason, storage_opts)
    end
  end

  defp handle_proof(
         {:superseded, summary},
         _plan,
         ctx,
         journal,
         _published,
         _fingerprint,
         storage_opts
       ) do
    rollback_with_proof_evidence(
      journal,
      ctx,
      summary,
      @stable_proof_superseded,
      {:published_proof_superseded, summary},
      storage_opts
    )
  end

  defp handle_proof(
         {:retryable_failure, class, summary},
         _plan,
         ctx,
         journal,
         _published,
         _fingerprint,
         storage_opts
       ) do
    rollback_with_proof_evidence(
      journal,
      ctx,
      summary,
      stable_proof_code(class),
      {:published_proof_failed, class, summary},
      storage_opts
    )
  end

  defp handle_proof(
         {:integrity_failure, class, summary},
         _plan,
         ctx,
         journal,
         _published,
         _fingerprint,
         storage_opts
       ) do
    rollback_with_proof_evidence(
      journal,
      ctx,
      summary,
      stable_proof_code(class),
      {:published_proof_failed, class, summary},
      storage_opts
    )
  end

  # callback contract violation 没有 canonical summary：绝不调用 PublishedProof merge，
  # 改用冻结的四键 generic PG 证据。
  defp handle_proof(
         {:contract_violation, :proof},
         _plan,
         ctx,
         journal,
         _published,
         _fingerprint,
         storage_opts
       ) do
    rollback_with_evidence(
      journal,
      ctx,
      @contract_violation_evidence,
      @stable_proof_contract_violation,
      {:published_proof_contract_violation, :proof},
      storage_opts
    )
  end

  # proof 已成功但 claimed→published 转换丢失：写冻结的 journal-transition generic 证据，
  # 绝不持久化/返回 raw CAS 原因或成功的 proof summary。
  defp publish_transition_lost(journal, ctx, _reason, storage_opts) do
    rollback_with_evidence(
      journal,
      ctx,
      @journal_transition_evidence,
      @stable_journal_transition,
      {:object_mutation_journal, :internal, :publish_transition},
      storage_opts
    )
  end

  # aggregate proof 失败/superseded：canonical nil-proof wrapper + 精确稳定 code。
  #
  # 纯 builder 拒绝（correction R1 §3.2）：`journal_evidence/3` 拒绝一个 summary 属于
  # **内部 durable 契约违约**，不是原始 backend disposition。此时写冻结的四键 generic PG
  # proof-contract 证据 + 显式 nil fingerprint + 精确 contract code，并返回**固定的**
  # `{:published_proof_contract_violation, :proof}`——绝不再返回原来的
  # unavailable/integrity/superseded union（那会让请求结果与 journal 权威互相矛盾）。
  defp rollback_with_proof_evidence(journal, ctx, summary, code, result, storage_opts) do
    case PublishedProof.journal_evidence("rollback_pending", nil, summary) do
      {:ok, evidence} ->
        rollback_with_evidence(journal, ctx, evidence, code, result, storage_opts)

      {:error, _reason} ->
        rollback_with_evidence(
          journal,
          ctx,
          @contract_violation_evidence,
          @stable_proof_contract_violation,
          {:published_proof_contract_violation, :proof},
          storage_opts
        )
    end
  end

  # 完整显式原子三元组：nil fingerprint + phase-valid evidence + 精确稳定 code，
  # 随后 best-effort restore 使用**原始 claimed context**。
  defp rollback_with_evidence(journal, ctx, evidence, code, result, storage_opts) do
    attrs = %{published_fingerprint: nil, recovery_evidence: evidence, last_error: code}

    # 并发扰动（attempts/lease）下用最新行提高收敛率；创建三元组仍要求 observed
    # fingerprint/evidence 为 nil，由 G1 在 SQL 之前判定。
    journal = refetch(journal) || journal

    case ObjectMutation.request_rollback(journal, attrs) do
      {:ok, requested} ->
        Log.warn(
          "object mutation rollback requested",
          Log.journal_fields(requested,
            action: :object_mutation_rollback_requested,
            outcome: :ok,
            reason: code
          )
        )

        _ = restore_with_claimed_context(requested, ctx, storage_opts)

      {:error, request_error} ->
        Log.error(
          "object mutation rollback request failed (recovery converges)",
          Log.journal_fields(journal,
            action: :object_mutation_rollback_requested,
            outcome: :error,
            reason: stable_reason_code(request_error)
          )
        )
    end

    {:error, result}
  end

  # pre-metadata restore 永远使用原始的、与 fingerprint 无关的 claimed context。
  defp restore_with_claimed_context(journal, %MutationContext{} = ctx, storage_opts) do
    Failpoint.hit(:object_mutation_restore)
    apply_restore(ctx, journal, storage_opts)
  rescue
    error -> restore_failed(journal, error)
  end

  # 后端契约（B2）：协议 publish 成功结果必须回传 :epoch_fingerprint——缺失即契约违约，
  # 立即回滚，绝不带着未知 fingerprint 进 metadata 提交。
  defp published_fingerprint(%{epoch_fingerprint: fingerprint}), do: {:ok, fingerprint}
  defp published_fingerprint(published), do: {:error, {:missing_epoch_fingerprint, published}}

  # ── 步骤 8–11：metadata 同事务 + finalize + 加速器 ──

  # `claimed_ctx` 只用于 pre-metadata restore；`fresh_ctx` 来自 published journal，
  # 供 metadata 与直接 finalize 使用。
  defp metadata_phase(plan, claimed_ctx, fresh_ctx, journal, published, storage_opts) do
    Failpoint.hit(:object_mutation_before_metadata_commit)

    case plan.metadata_tx.(journal, published) do
      {:ok, metadata} ->
        after_metadata_commit(plan, fresh_ctx, journal, published, metadata, storage_opts)

      {:error, reason} ->
        Log.warn(
          "object mutation metadata transaction failed",
          Log.journal_fields(journal,
            action: :object_mutation_metadata_commit,
            outcome: :error,
            reason: stable_reason_code(reason)
          )
        )

        # metadata 失败：refetch durable published 行，用 omission-preservation 回滚，
        # 让既有的非 nil fingerprint 与 canonical 成功 wrapper 原样跨越（G2 §5.3 第 2 类）。
        rollback_preserving_evidence(journal, claimed_ctx, reason, storage_opts)
    end
  end

  defp after_metadata_commit(plan, fresh_ctx, journal, published, metadata, storage_opts) do
    case refetch(journal) do
      %Journal{phase: phase} = fresh when phase in @no_rollback_phases ->
        Failpoint.hit(:object_mutation_after_metadata_commit)

        fresh_ctx
        |> finalize_phase(fresh, storage_opts)
        |> request_result(plan, published, metadata)

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

  # correction R2 §5：seam 结果 → 请求语义 + accelerator 的**唯一**纯映射函数。
  # `{:request_ok, row, :accelerate}` 这个最终 tuple 在整个 production 里只在这里构造，
  # 且输入必须是 `{:converged, row}` + `{:success, :accelerate}`；只有 finalized 与
  # cleanup 两个 handle 分支可以提供该 success policy。
  defp seam_outcome(journal, intent, semantics),
    do: journal |> durable_action(intent) |> outcome_result(semantics)

  defp outcome_result({:converged, row}, {:success, :accelerate}),
    do: {:request_ok, row, :accelerate}

  defp outcome_result({:converged, row}, {:success, :defer}), do: {:request_ok, row, :defer}

  defp outcome_result({:converged, row}, {:error, public_term}),
    do: {:request_error, public_term, row}

  # 安全可恢复的赢家：保留原请求语义，但**恒 defer**，绝不加速。
  defp outcome_result({:recoverable_winner, row}, {:success, _accelerator}),
    do: {:request_ok, row, :defer}

  defp outcome_result({:recoverable_winner, row}, {:error, public_term}),
    do: {:request_error, public_term, row}

  defp outcome_result({:incompatible, row}, _semantics),
    do: {:request_error, @finalize_outcome_internal, row}

  # 加速器决策是**显式**的，绝无隐式加速；错误与 defer 永远进不了 `Control.mark_committed/1`。
  defp request_result({:request_ok, journal, :accelerate}, plan, published, metadata) do
    accelerate_mark_committed(plan, journal)
    {:ok, %{journal: journal, published: published, metadata: metadata}}
  end

  defp request_result({:request_ok, journal, :defer}, _plan, published, metadata),
    do: {:ok, %{journal: journal, published: published, metadata: metadata}}

  defp request_result({:request_error, public_term, _journal}, _plan, _published, _metadata),
    do: {:error, public_term}

  # 步骤 10（correction R2 §3.4）：`after_metadata_commit` 首次 refetch 就已是 `finalized`
  # 的捷径。它必须独立验证 fingerprint、canonical finalized evidence、`finalized_at` 与
  # terminal lease 清理；合法即请求成功但**恒 defer**——该捷径不是本次 seam 确认的
  # finalized action，绝不产生 accelerate。
  defp finalize_phase(_ctx, %Journal{phase: "finalized"} = journal, _storage_opts) do
    if canonical_finalized_row?(journal),
      do: {:request_ok, journal, :defer},
      else: {:request_error, @finalize_outcome_internal, journal}
  end

  # metadata_committed → finalize_pending fence 复用**同一个** durable-action seam：
  # 这里绝不再实现第二套 write / proof / refetch / winner 逻辑（correction R2 §3.4）。
  defp finalize_phase(ctx, journal, storage_opts) do
    case durable_action(journal, fence_intent()) do
      {:converged, pending} ->
        run_finalize(ctx, pending, storage_opts)

      # 安全的 pending 赢家：从 fresh row 继续 finalize。
      {:recoverable_winner, %Journal{phase: "finalize_pending"} = pending} ->
        run_finalize(ctx, pending, storage_opts)

      # 安全地仍停在 metadata_committed：请求成功 + defer，不做直接 finalize。
      {:recoverable_winner, row} ->
        {:request_ok, row, :defer}

      {:incompatible, row} ->
        {:request_error, @finalize_outcome_internal, row}
    end
  end

  # 终态 finalized 行的 canonical 判定：只消费冻结的 `Journal` 与 `PublishedProof`
  # 非变异权威判定，绝不复制第三套 schema/classifier。
  defp canonical_finalized_row?(row) do
    Journal.fingerprint_valid?(row.published_fingerprint) and
      PublishedProof.validate_durable_evidence("finalized", row.recovery_evidence) == :ok and
      not is_nil(row.finalized_at) and is_nil(row.lease_owner) and
      is_nil(row.lease_expires_at)
  end

  # G2 §5.4：编排 failpoint 与 backend callback 结果处理严格分开。
  # `Failpoint.hit/1` 的 raise 属于编排域，必须原样逃逸给上层 `converge_after_exception`；
  # 绝不允许任何宽泛 rescue 把编排 bug 或 failpoint 转成 proof 结论。
  defp run_finalize(ctx, journal, storage_opts) do
    case orchestration_failpoint(journal) do
      :ok ->
        ctx
        |> Storage.finalize_if_current(storage_opts)
        |> StorageDisposition.finalize()
        |> handle_finalize(journal)

      {:orchestration_error, outcome} ->
        outcome
    end
  end

  # 编排 failpoint 属于 orchestration 域：它**只**被这一处窄 rescue 捕获，收敛为
  # evidence-preserving 的运维错误（请求仍成功、journal 停在 finalize_pending、由 Recovery
  # 收敛），绝不被折叠成 proof 结论。backend callback 结果路径完全不在此 rescue 之内——
  # 那条边界只属于 `Maxio.Storage`。
  defp orchestration_failpoint(journal) do
    Failpoint.hit(:object_mutation_finalize)
    :ok
  rescue
    _error ->
      Log.error(
        "object mutation finalize orchestration error (request succeeds; recovery converges)",
        Log.journal_fields(journal,
          action: :object_mutation_finalize,
          outcome: :error,
          reason: @stable_finalize_orchestration_error
        )
      )

      # 编排错误也必须经同一个 durable-outcome seam：既有请求成功语义保留，但**恒 defer**
      # ——它不是两个被授权的成功 disposition 之一，绝不允许触达显式加速器。
      {:orchestration_error,
       seam_outcome(
         journal,
         operational_error_intent(@stable_finalize_orchestration_error),
         {:success, :defer}
       )}
  end

  # ── correction R2 §3.1 disposition 矩阵：每格恰好一个 durable 动作 ──
  #
  # | fact                 | durable 动作                          | 请求        | 加速器 |
  # | finalized            | canonical 门 + transition → finalized  | 成功        | 是    |
  # | cleanup pending      | mark_error（canonical merge/code）     | 成功        | 是    |
  # | unavailable          | mark_error（canonical merge/code）     | 原 proof 错  | 否   |
  # | integrity            | 一次 quarantine CAS（phase+证据+code）  | 原 proof 错  | 否   |
  # | superseded           | 一次 finalized CAS（phase+证据+code）   | 精确后继错   | 否   |
  # | callback/merge 契约违约 | evidence-preserving quarantine       | 固定契约错   | 否   |
  # | 编排失败              | mark_operational_error                | 既有成功     | defer |
  #
  # 注意：只有 finalized 与 cleanup 两格是**请求成功**类；其余 finalize failure 一律返回
  # 各自固定的结构化错误。任何 recoverable winner / 写丢失兜底一律 defer，绝不加速。

  # finalized：终态，保留初始 proof wrapper（不 merge）。正因为它不经 `merge_failure/3`，
  # 必须在构造 terminal intent **之前**单独过同一个非变异 `PublishedProof` 权威门
  # （correction R2 §3.3）。拒绝时忽略 summary 的业务类别，按 pure durable contract
  # violation 隔离——绝不 terminalize、绝不 accelerate；callback raw term 不进 journal/结果/日志。
  defp handle_finalize({:finalized, summary}, journal) do
    log_finalize(journal, :finalized, "finalized", summary)

    case PublishedProof.validate_durable_evidence("finalize_pending", journal.recovery_evidence) do
      :ok ->
        seam_outcome(journal, terminal_intent("finalized", %{}), {:success, :accelerate})

      {:error, _reason} ->
        Log.error(
          "object mutation finalize durable evidence rejected before terminal write",
          Log.journal_fields(journal,
            action: :object_mutation_finalize,
            outcome: :error,
            reason: @stable_finalize_contract_violation,
            proof_mode: "finalize"
          )
        )

        finalize_contract_violation(journal)
    end
  end

  # cleanup pending：请求成功但非终态；merge canonical last failure，保持 finalize_pending
  # 并排期重试。
  defp handle_finalize({:cleanup_pending, summary}, journal) do
    log_finalize(journal, :cleanup_pending, "cleanup_pending", summary)

    merged_outcome(journal, summary, fn evidence ->
      seam_outcome(
        journal,
        mark_error_intent(@stable_finalize_cleanup_pending, evidence),
        {:success, :accelerate}
      )
    end)
  end

  # superseded：**先纯 merge**，再用一次终态 CAS 同时写入 phase、canonical successor 证据
  # 与精确 code；绝不在缺少 canonical successor 证据时终态化，也绝不回滚。
  defp handle_finalize({:superseded, summary}, journal) do
    log_finalize(journal, :superseded, "superseded", summary)

    merged_outcome(journal, summary, fn evidence ->
      seam_outcome(
        journal,
        terminal_intent("finalized", %{
          recovery_evidence: evidence,
          last_error: @stable_finalize_superseded
        }),
        {:error, {:published_proof_superseded, summary}}
      )
    end)
  end

  # unavailable：可重试；merge canonical last failure、保持 pending、排期重试。
  defp handle_finalize({:retryable_failure, class, summary}, journal) do
    log_finalize(journal, :error, Atom.to_string(class), summary)

    merged_outcome(journal, summary, fn evidence ->
      seam_outcome(
        journal,
        mark_error_intent(stable_finalize_code(class), evidence),
        {:error, {:published_proof_failed, class, summary}}
      )
    end)
  end

  # integrity：**绝不**先 mark_error 再 quarantine。纯 merge 之后只做一次终态 CAS，
  # 同时携带 phase、合并证据与精确 code；backup 保留供取证。
  defp handle_finalize({:integrity_failure, class, summary}, journal) do
    log_finalize(journal, :error, Atom.to_string(class), summary)
    code = stable_finalize_code(class)

    merged_outcome(journal, summary, fn evidence ->
      seam_outcome(
        journal,
        quarantine_intent(code, evidence),
        {:error, {:published_proof_failed, class, summary}}
      )
    end)
  end

  # callback contract violation：没有 canonical summary，绝不 merge；隔离并逐字保留既有
  # fingerprint 与 wrapper 的 term/JSON 字节。
  defp handle_finalize({:contract_violation, :finalize}, journal) do
    Log.error(
      "object mutation finalize callback contract violation (evidence preserved; backup retained)",
      Log.journal_fields(journal,
        action: :object_mutation_finalize,
        outcome: :error,
        reason: @stable_finalize_contract_violation,
        proof_mode: "finalize"
      )
    )

    finalize_contract_violation(journal)
  end

  # 纯 merge 先行（correction R1 §3.2）：merge 拒绝本身就是内部 durable 契约违约，
  # 必须收敛为 evidence-preserving quarantine + 固定 finalize 契约错误——绝不返回原
  # unavailable/integrity/superseded union，也绝不返回 cleanup 成功。
  defp merged_outcome(journal, summary, continue) do
    case merge_evidence(journal, summary) do
      {:ok, evidence} ->
        continue.(evidence)

      {:error, _reason} ->
        Log.error(
          "object mutation finalize evidence merge rejected (evidence preserved; backup retained)",
          Log.journal_fields(journal,
            action: :object_mutation_finalize,
            outcome: :error,
            reason: @stable_finalize_contract_violation,
            proof_mode: "finalize"
          )
        )

        finalize_contract_violation(journal)
    end
  end

  defp finalize_contract_violation(journal) do
    seam_outcome(
      journal,
      preserving_quarantine_intent(@stable_finalize_contract_violation),
      {:error, {:published_proof_contract_violation, :finalize}}
    )
  end

  defp merge_evidence(%Journal{recovery_evidence: wrapper}, summary) when is_map(wrapper),
    do: PublishedProof.merge_failure("finalize_pending", wrapper, summary)

  defp merge_evidence(_journal, _summary), do: {:error, :invalid_proof_evidence}

  # ── correction R2 §3.1：唯一的 durable-action seam ──
  #
  # observed journal + action-specific intent
  #   → 恰好一次 ObjectMutation 动作
  #   → 返回行的**完整**意图证明（绝不轻信 tuple tag）
  #   → `{:error, _}` 时恰好一次 refetch
  #   → {:converged, row} | {:recoverable_winner, row} | {:incompatible, row}
  #
  # fence、finalized/cleanup/unavailable/integrity/superseded、callback/merge 契约隔离与
  # orchestration operational error **全部**共用它。请求进程内绝不重试写入，也绝不
  # 规范化/修复/覆盖 CAS 赢家：无论接受还是拒绝，赢家行 byte-for-term 保持不变。
  defp durable_action(observed, intent) do
    case intent.run.(observed) do
      {:ok, row} ->
        if intent.proven?.(observed, row) do
          log_durable_outcome(row)
          {:converged, row}
        else
          # `ObjectMutation.transition/4` 的 generic 终态幂等**不是**本次意图的证明。
          # 这是一个已经新鲜的并发赢家：不 refetch、不 retry、不 overwrite、绝不加速。
          log_durable_write_loss(observed)
          winner_verdict(observed, intent, row)
        end

      {:error, _reason} ->
        log_durable_write_loss(observed)

        case refetch(observed) do
          nil ->
            {:incompatible, observed}

          %Journal{} = fresh ->
            if intent.proven?.(observed, fresh) do
              log_durable_outcome(fresh)
              {:converged, fresh}
            else
              winner_verdict(observed, intent, fresh)
            end
        end
    end
  end

  # 赢家必须**同时**通过公共 row gate 与该 action 自己的 compatibility 契约。
  defp winner_verdict(observed, intent, row) do
    if recoverable_row?(observed, row) and intent.compatible?.(observed, row),
      do: {:recoverable_winner, row},
      else: {:incompatible, row}
  end

  # 公共 row gate（correction R2 §3.3）。phase 只能单调前进；mutation identity 必须严格
  # 一致；attempts 不得回退；fingerprint 与 evidence 必须分别经**冻结的**
  # `Journal.fingerprint_valid?/1` 与 `PublishedProof.validate_durable_evidence/2` 权威
  # 判定——绝不复制第三套 schema/classifier。
  defp recoverable_row?(observed, row) do
    phase_monotonic?(observed.phase, row.phase) and same_mutation_identity?(observed, row) and
      is_integer(row.attempts) and row.attempts >= observed.attempts and
      Journal.fingerprint_valid?(row.published_fingerprint) and
      row.published_fingerprint === observed.published_fingerprint and
      PublishedProof.validate_durable_evidence(row.phase, row.recovery_evidence) == :ok and
      scheduling_scalars_stable?(observed, row)
  end

  defp phase_monotonic?("metadata_committed", phase),
    do: phase in @recoverable_finalize_phases

  defp phase_monotonic?("finalize_pending", phase), do: phase == "finalize_pending"
  defp phase_monotonic?(_observed_phase, _row_phase), do: false

  # attempts 未增加时，调度标量也必须与 observed 严格一致；attempts 增加才允许合法的
  # recovery/operational writer 更新 last_error / next_attempt_at / lease。
  defp scheduling_scalars_stable?(observed, row) do
    row.attempts > observed.attempts or
      (row.last_error === observed.last_error and
         row.next_attempt_at === observed.next_attempt_at and
         row.lease_owner === observed.lease_owner and
         row.lease_expires_at === observed.lease_expires_at)
  end

  defp same_mutation_identity?(observed, row),
    do: Enum.all?(@identity_fields, &(Map.fetch!(row, &1) === Map.fetch!(observed, &1)))

  # 单一 exact-field helper（correction R2 §4.1）：`owned` 之外的每个字段都必须与 observed
  # 严格 `===`。禁止在每个分支复制不同的字段列表。
  defp exact_row?(observed, row, owned) do
    Enum.all?(@journal_fields, fn field ->
      Map.fetch!(row, field) === Map.get(owned, field, Map.fetch!(observed, field))
    end)
  end

  # 除 `mark_error` 外，所有 action 的合法竞争者都必须保持 evidence 与 observed 一致。
  defp evidence_identical?(observed, row),
    do: row.recovery_evidence === observed.recovery_evidence

  # ── 五个 durable 动作意图：动作本体 + 完整标量证明 + action-aware winner 契约 ──
  #
  # 每个 intent 构造时捕获一个 `now` 并显式传给对应 ObjectMutation API；
  # `mark_error` / `mark_operational_error` 另显式传 `backoff_ms`。
  # 绝不用「非 nil」冒充本次写入的证明。

  defp fence_intent do
    now = DateTime.utc_now()

    %{
      run: fn journal -> ObjectMutation.transition(journal, "finalize_pending", %{}, now: now) end,
      proven?: fn observed, row ->
        exact_row?(observed, row, %{phase: "finalize_pending", updated_at: now})
      end,
      compatible?: &evidence_identical?/2
    }
  end

  defp terminal_intent(phase, attrs) do
    now = DateTime.utc_now()

    owned =
      %{phase: phase, updated_at: now, lease_owner: nil, lease_expires_at: nil}
      |> Map.put(terminal_stamp_field(phase), now)
      |> Map.merge(Map.take(attrs, [:recovery_evidence, :last_error]))

    %{
      run: fn journal -> ObjectMutation.transition(journal, phase, attrs, now: now) end,
      proven?: fn observed, row -> exact_row?(observed, row, owned) end,
      compatible?: &evidence_identical?/2
    }
  end

  defp quarantine_intent(code, evidence) do
    now = DateTime.utc_now()

    owned = %{
      phase: "quarantined",
      quarantined_at: now,
      updated_at: now,
      lease_owner: nil,
      lease_expires_at: nil,
      recovery_evidence: evidence,
      last_error: code
    }

    %{
      run: fn journal -> ObjectMutation.quarantine(journal, code, evidence, now: now) end,
      proven?: fn observed, row -> exact_row?(observed, row, owned) end,
      compatible?: &evidence_identical?/2
    }
  end

  defp preserving_quarantine_intent(code) do
    now = DateTime.utc_now()

    owned = %{
      phase: "quarantined",
      quarantined_at: now,
      updated_at: now,
      lease_owner: nil,
      lease_expires_at: nil,
      last_error: code
    }

    %{
      run: fn journal ->
        ObjectMutation.quarantine_preserving_evidence(journal, code, now: now)
      end,
      proven?: fn observed, row -> exact_row?(observed, row, owned) end,
      compatible?: &evidence_identical?/2
    }
  end

  defp mark_error_intent(code, evidence) do
    now = DateTime.utc_now()
    next_attempt_at = DateTime.add(now, @initial_backoff_ms, :millisecond)

    %{
      run: fn journal ->
        ObjectMutation.mark_error(journal, code, evidence,
          now: now,
          backoff_ms: @initial_backoff_ms
        )
      end,
      proven?: fn observed, row ->
        exact_row?(observed, row, %{
          attempts: observed.attempts + 1,
          next_attempt_at: next_attempt_at,
          updated_at: now,
          recovery_evidence: evidence,
          last_error: code
        })
      end,
      # `mark_error` 的合法竞争者可能已经写入**本 intent 纯构造的** canonical merged
      # wrapper；此时 exact stable code 也必须一致。任何第三个 valid-but-unrelated
      # wrapper/code 仍是 incompatible。
      compatible?: fn observed, row ->
        evidence_identical?(observed, row) or
          (row.recovery_evidence === evidence and row.last_error === code)
      end
    }
  end

  defp operational_error_intent(code) do
    now = DateTime.utc_now()
    next_attempt_at = DateTime.add(now, @initial_backoff_ms, :millisecond)

    %{
      run: fn journal ->
        ObjectMutation.mark_operational_error(journal, code,
          now: now,
          backoff_ms: @initial_backoff_ms
        )
      end,
      proven?: fn observed, row ->
        exact_row?(observed, row, %{
          attempts: observed.attempts + 1,
          next_attempt_at: next_attempt_at,
          updated_at: now,
          last_error: code
        })
      end,
      compatible?: &evidence_identical?/2
    }
  end

  defp terminal_stamp_field("finalized"), do: :finalized_at
  defp terminal_stamp_field("quarantined"), do: :quarantined_at

  defp log_durable_outcome(row) do
    Log.info(
      "object mutation durable finalize outcome persisted",
      Log.journal_fields(row, action: :object_mutation_finalize, outcome: :ok)
    )
  end

  # 唯一的固定写丢失标量：绝不记录 raw reason / SQL / changeset / evidence / callback term。
  defp log_durable_write_loss(journal) do
    Log.error(
      "object mutation durable finalize outcome write lost (recovery converges)",
      Log.journal_fields(journal,
        action: :object_mutation_finalize,
        outcome: :error,
        reason: @stable_finalize_write_loss
      )
    )
  end

  # 只记录**有界标量**（G2 §3.4 白名单）；raw summary 绝不进日志。
  defp log_finalize(journal, outcome, class, summary) do
    fields =
      Log.journal_fields(journal,
        action: :object_mutation_finalize,
        outcome: outcome,
        proof_mode: "finalize",
        proof_class: class
      )
      |> Keyword.merge(proof_scalars(summary))

    if outcome == :error,
      do: Log.error("object mutation finalize disposition", fields),
      else: Log.info("object mutation finalize disposition", fields)
  end

  defp proof_scalars(summary) when is_map(summary) do
    [
      proof_required: Map.get(summary, "required"),
      proof_verified: Map.get(summary, "verified"),
      proof_finalized: Map.get(summary, "finalized"),
      proof_debt: Map.get(summary, "debt"),
      proof_unavailable: Map.get(summary, "unavailable"),
      proof_omitted: Map.get(summary, "omitted"),
      proof_orphaned: Map.get(summary, "orphaned")
    ]
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
  end

  defp proof_scalars(_summary), do: []

  defp stable_proof_code(:unavailable), do: "published_proof_failed:proof:unavailable"
  defp stable_proof_code(:mismatch), do: "published_proof_failed:proof:mismatch"
  defp stable_proof_code(:corrupt), do: "published_proof_failed:proof:corrupt"
  defp stable_proof_code(:placement_drift), do: "published_proof_failed:proof:placement_drift"

  defp stable_finalize_code(:unavailable), do: "published_proof_failed:finalize:unavailable"
  defp stable_finalize_code(:mismatch), do: "published_proof_failed:finalize:mismatch"
  defp stable_finalize_code(:corrupt), do: "published_proof_failed:finalize:corrupt"

  defp stable_finalize_code(:placement_drift),
    do: "published_proof_failed:finalize:placement_drift"

  # 日志 `reason` 只接受稳定标量 code：绝不把 raw callback/结果 term 塞进 reason。
  defp stable_reason_code(reason) when is_binary(reason), do: reason
  defp stable_reason_code(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp stable_reason_code({code, _detail}) when is_atom(code), do: Atom.to_string(code)
  defp stable_reason_code({code, _a, _b}) when is_atom(code), do: Atom.to_string(code)
  defp stable_reason_code(_reason), do: "internal"

  # G2 §5.3 第 2 类：proof 成功且 published 已 durable 之后的 metadata/操作失败。
  # refetch durable 行后用 omission-preservation 回滚——G1 先校验已观察到的非 nil
  # fingerprint 与 canonical 成功 wrapper，再把两者原样带进 rollback_pending。
  # 绝不把操作性原因合并进 proof 证据，也绝不伪造 proof failure。
  defp rollback_preserving_evidence(journal, ctx, reason, storage_opts) do
    fresh = refetch(journal) || journal

    case ObjectMutation.request_rollback(fresh, %{}) do
      {:ok, requested} ->
        Log.warn(
          "object mutation rollback requested",
          Log.journal_fields(requested,
            action: :object_mutation_rollback_requested,
            outcome: :ok,
            reason: stable_reason_code(reason)
          )
        )

        _ = restore_with_claimed_context(requested, ctx, storage_opts)

      {:error, :invalid_rollback_evidence} ->
        Log.error(
          "object mutation rollback refused (metadata_committed no-rollback line)",
          Log.journal_fields(fresh,
            action: :object_mutation_rollback_requested,
            outcome: :refused,
            reason: "invalid_rollback_evidence"
          )
        )

      {:error, request_error} ->
        Log.error(
          "object mutation rollback request failed (recovery converges)",
          Log.journal_fields(fresh,
            action: :object_mutation_rollback_requested,
            outcome: :error,
            reason: stable_reason_code(request_error)
          )
        )
    end

    {:error, reason}
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

    case ObjectMutation.request_rollback(journal, %{}) do
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

      # attrs-map API 把非法 authority/phase 统一收敛为 :invalid_rollback_evidence
      # （metadata_committed 及之后与终态都走这一支）。
      {:error, :invalid_rollback_evidence} ->
        Log.error(
          "object mutation rollback refused (metadata_committed no-rollback line)",
          Log.journal_fields(journal,
            action: :object_mutation_rollback_requested,
            outcome: :refused,
            reason: inspect(:invalid_rollback_evidence)
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

  # restore 永远使用**原始的、与 fingerprint 无关**的 claimed context（design D2 / G2 §5.2）。
  # journal 的其余字段在 claimed 与 published 之间完全一致，因此显式清空 fingerprint 就是
  # 逐字重建那个 claimed context——无论本次是经异常收敛还是经显式 rollback 进来的。
  defp attempt_restore(journal, storage_opts) do
    case MutationContext.from_journal(journal) do
      {:ok, %MutationContext{} = ctx} ->
        Failpoint.hit(:object_mutation_restore)
        apply_restore(%MutationContext{ctx | published_fingerprint: nil}, journal, storage_opts)

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

  # restore 失败是**非 proof 的运维失败**：它绝不能改写主失败证据。改用
  # evidence-preserving 的 `mark_operational_error/3`，让主 proof 失败证据的 term 与
  # JSON 字节原样保留供取证，backup 也保持不动（G2 §5.4）。raw 原因绝不落库或进日志。
  defp restore_failed(journal, _reason) do
    Log.error(
      "object mutation restore failed (backup retained; recovery converges)",
      Log.journal_fields(journal,
        action: :object_mutation_rollback_result,
        outcome: :error,
        reason: @stable_restore_failed
      )
    )

    # 刻意**不**改写 journal：主失败证据的 term/JSON 字节与主稳定 code 都是取证权威，
    # restore 这个次生运维失败不得覆盖它们中的任何一个。rollback CAS 已把
    # `next_attempt_at` 置为 now，因此 Recovery 立刻可见并继续收敛；backup 原样保留。
    :ok
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
