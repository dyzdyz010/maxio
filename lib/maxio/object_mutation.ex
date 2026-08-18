defmodule Maxio.ObjectMutation do
  @moduledoc "对象变更 journal 的唯一写入口；所有阶段和恢复租约更新均使用数据库 CAS。"

  import Ecto.Query

  alias Maxio.ObjectMutation.Journal
  alias Maxio.Repo
  alias Maxio.Storage.PublishedProof

  @pg_graph %{
    "prepared" => ~w(claimed rollback_pending quarantined),
    "claimed" => ~w(published rollback_pending quarantined),
    "published" => ~w(metadata_committed rollback_pending quarantined),
    "metadata_committed" => ~w(finalize_pending quarantined),
    "finalize_pending" => ~w(finalized quarantined),
    "rollback_pending" => ~w(rolled_back quarantined),
    "finalized" => [],
    "rolled_back" => [],
    "quarantined" => []
  }

  @sidecar_published_targets ~w(finalize_pending quarantined)
  @nonterminal ~w(prepared claimed published metadata_committed finalize_pending rollback_pending)
  @terminal ~w(finalized rolled_back quarantined)
  @rollback_requestable ~w(prepared claimed published)
  @rollback_requested_idempotent ~w(rollback_pending rolled_back)
  @rollback_attr_keys ~w(published_fingerprint recovery_evidence last_error)a
  @rollback_replay_order ~w(published_fingerprint recovery_evidence last_error)a

  # design D6 冻结的两个 exact generic PG 形态，只能由 PG `claimed` 创建。
  @contract_violation_evidence %{
    "authority_mode" => "pg",
    "stage" => "verify_published",
    "outcome" => "contract_violation",
    "mode" => "proof"
  }
  @contract_violation_error "published_proof_contract_violation:proof"
  @journal_transition_evidence %{
    "authority_mode" => "pg",
    "stage" => "journal_publish",
    "outcome" => "transition_failed"
  }
  @journal_transition_error "published_proof_journal_transition:failed"

  # design D2 / plan Task 3 Step 2 冻结的 outcome → stable last_error 逐字映射。
  # 它只是**初始创建规则**，绝不是 replay 冲突的捷径。
  @stable_rollback_codes %{
    unavailable: "published_proof_failed:proof:unavailable",
    corrupt: "published_proof_failed:proof:corrupt",
    mismatch: "published_proof_failed:proof:mismatch",
    placement_drift: "published_proof_failed:proof:placement_drift",
    superseded: "published_proof_superseded:proof"
  }
  @transition_fields ~w(placement_snapshot previous_epoch published_fingerprint recovery_evidence last_error)a
  @default_lease_ms 60_000
  @default_backoff_ms 60_000
  @max_error_chars 2_000
  @prepare_managed_fields ~w(
    phase attempts next_attempt_at lease_owner lease_expires_at last_error
    previous_epoch published_fingerprint recovery_evidence metadata_committed_at
    finalized_at rolled_back_at quarantined_at
  )a

  @type mutation_error ::
          :not_found
          | :invalid_lease_owner
          | :not_leased
          | :not_due_or_leased
          | :invalid_operational_reason
          | {:illegal_transition, String.t(), String.t()}
          | {:stale_journal, String.t(), non_neg_integer()}
          | Ecto.Changeset.t()

  @type rollback_error ::
          :invalid_rollback_evidence
          | {:invalid_rollback_attrs, [atom() | String.t()]}
          | {:rollback_evidence_conflict,
             :published_fingerprint | :recovery_evidence | :last_error}
          | mutation_error()

  @doc """
  创建 prepared journal；`:id` 可由调用者指定为磁盘 epoch 的 mutation_id。

  `opts[:initial_backoff_ms]`（默认 0）把 next_attempt_at 偏移到未来——请求路径用 60s
  宽限防 recovery 误扫健康 in-flight 请求（协议 §5 / 实现计划 D5），其余语义不变。
  """
  @spec prepare(map(), keyword()) :: {:ok, Journal.t()} | {:error, Ecto.Changeset.t()}
  def prepare(attrs, opts \\ []) when is_map(attrs) do
    repo = Keyword.get(opts, :repo, Repo)
    now = Keyword.get_lazy(opts, :now, &now/0)
    initial_backoff_ms = non_negative_int(Keyword.get(opts, :initial_backoff_ms), 0)
    {id, attrs} = pop_id(attrs)
    injections = protocol_injections(attrs)

    attrs =
      attrs
      |> drop_protocol_fields()
      |> Map.merge(%{
        phase: "prepared",
        attempts: 0,
        next_attempt_at: DateTime.add(now, initial_backoff_ms, :millisecond)
      })

    changeset = Journal.changeset(%Journal{id: id}, attrs)

    injections
    |> Enum.reduce(changeset, fn field, acc ->
      Ecto.Changeset.add_error(acc, field, "is managed by the mutation protocol")
    end)
    |> repo.insert()
  end

  @doc "按严格状态图推进 journal；SQL 同时比较 id 与调用者观察到的旧 phase。"
  @spec transition(Journal.t(), String.t(), map(), keyword()) ::
          {:ok, Journal.t()} | {:error, mutation_error()}
  def transition(%Journal{} = journal, target_phase, attrs \\ %{}, opts \\ [])
      when is_binary(target_phase) and is_map(attrs) do
    cond do
      target_phase == journal.phase ->
        idempotent_result(journal, opts)

      target_phase not in legal_targets(journal) ->
        {:error, {:illegal_transition, journal.phase, target_phase}}

      true ->
        transition_cas(journal, target_phase, attrs, opts)
    end
  end

  @doc "记录一次可重试错误；CAS 同时比较旧 phase 与 attempts，防止两个恢复器互相覆盖证据。"
  @spec mark_error(Journal.t(), term(), map(), keyword()) ::
          {:ok, Journal.t()} | {:error, mutation_error()}
  def mark_error(journal, reason, evidence, opts \\ [])

  def mark_error(%Journal{phase: phase} = journal, reason, evidence, opts)
      when phase in @nonterminal and is_map(evidence) do
    repo = Keyword.get(opts, :repo, Repo)
    now = Keyword.get_lazy(opts, :now, &now/0)
    backoff_ms = non_negative_int(Keyword.get(opts, :backoff_ms), @default_backoff_ms)

    changeset =
      Journal.changeset(journal, %{
        attempts: journal.attempts + 1,
        next_attempt_at: DateTime.add(now, backoff_ms, :millisecond),
        last_error: error_text(reason),
        recovery_evidence: evidence
      })

    if changeset.valid? do
      updates = changeset.changes |> Map.put(:updated_at, now) |> Map.to_list()

      query =
        Journal
        |> where(
          [j],
          j.id == ^journal.id and j.phase == ^journal.phase and
            j.attempts == ^journal.attempts
        )
        |> match_observed_lease(journal, now)

      {count, _} = repo.update_all(query, set: updates)
      cas_result(repo, journal, count, nil, now)
    else
      {:error, changeset}
    end
  rescue
    error -> {:error, {:journal_update_failed, Exception.message(error)}}
  end

  def mark_error(%Journal{} = journal, _reason, _evidence, _opts),
    do: {:error, {:illegal_error_update, journal.phase}}

  @doc "证据不足时进入 quarantined，并持久化原因与结构化恢复证据。"
  @spec quarantine(Journal.t(), term(), map(), keyword()) ::
          {:ok, Journal.t()} | {:error, mutation_error()}
  def quarantine(%Journal{} = journal, reason, evidence, opts \\ []) when is_map(evidence) do
    transition(
      journal,
      "quarantined",
      %{last_error: error_text(reason), recovery_evidence: evidence},
      opts
    )
  end

  @doc """
  Control/加速器/proof gate 的回滚请求入口（协议 §5、design D6）。

  `attrs` 是 map，只允许 `:published_fingerprint`、`:recovery_evidence`、`:last_error`
  三个 atom key；未知或 string 形态 key 在 SQL 之前返回
  `{:error, {:invalid_rollback_attrs, sorted_keys}}`。

  PG authority 且 phase ∈ prepared/claimed/published → **单条** CAS 原子写入
  `rollback_pending`、`next_attempt_at = now`、全部已提交的 evidence 字段、bounded
  `last_error` 与 `updated_at`，并同时比较 id + 观察到的 phase/attempts/lease。
  `rollback_pending`/`rolled_back` 是逐字相等的 replay：完全一致才成功且零写入，首个
  不一致字段按 `[:published_fingerprint, :recovery_evidence, :last_error]` 顺序返回
  `{:error, {:rollback_evidence_conflict, field}}`。其余 authority/phase 组合（含
  `metadata_committed` 及之后与终态）一律 `{:error, :invalid_rollback_evidence}`——
  metadata_committed 禁回滚三层防线的 journal 前置层。

  evidence domain 是 trust boundary：canonical wrapper 只能由 PG `claimed` 的初始 proof
  失败/superseded 规则引入（fingerprint 显式 nil），两个 exact generic PG 形态
  （`verify_published/contract_violation`、`journal_publish/transition_failed`）同样只能
  从 PG `claimed` 创建；其余一切 evidence 只能与已观察行逐字相等地保留。
  """
  @spec request_rollback(Journal.t(), map(), keyword()) ::
          {:ok, Journal.t()} | {:error, rollback_error()}
  def request_rollback(%Journal{} = journal, attrs, opts \\ []) when is_map(attrs) do
    with {:ok, supplied} <- validate_rollback_attrs(attrs),
         {:ok, supplied} <- normalize_rollback_last_error(supplied) do
      dispatch_rollback(journal, supplied, opts)
    end
  end

  # 单一校验入口：authority/phase 路由 → domain 与语义分类 → 共享 durable 校验 →
  # stable-code 创建规则 → 严格 replay/preservation 比较 → 零写入 replay 或恰好一次 CAS。
  # requestable 与 replay 两条路都必须先跨过**同一个** validation gate，绝不新增旁路。
  defp dispatch_rollback(%Journal{authority_mode: "pg"} = journal, supplied, opts) do
    cond do
      journal.phase in @rollback_requestable ->
        with :ok <- validate_rollback_evidence(journal, supplied) do
          request_rollback_cas(journal, supplied, opts)
        end

      journal.phase in @rollback_requested_idempotent ->
        with :ok <- validate_rollback_evidence(journal, supplied) do
          replay_rollback(journal, supplied, opts)
        end

      true ->
        {:error, :invalid_rollback_evidence}
    end
  end

  defp dispatch_rollback(%Journal{}, _supplied, _opts), do: {:error, :invalid_rollback_evidence}

  # 只接受三个 atom key；其余（含 string 形态）以确定性排序的 key 列表拒绝。
  defp validate_rollback_attrs(attrs) do
    case attrs |> Map.keys() |> Enum.reject(&(&1 in @rollback_attr_keys)) |> Enum.sort() do
      [] -> {:ok, Map.take(attrs, @rollback_attr_keys)}
      unknown -> {:error, {:invalid_rollback_attrs, unknown}}
    end
  end

  # binary 逐字保留，只按 grapheme 切一次；非 binary 一律拒绝，绝不经 inspect/1 洗白。
  defp normalize_rollback_last_error(supplied) do
    case Map.fetch(supplied, :last_error) do
      :error ->
        {:ok, supplied}

      {:ok, last_error} when is_binary(last_error) ->
        {:ok, Map.put(supplied, :last_error, String.slice(last_error, 0, @max_error_chars))}

      {:ok, _invalid} ->
        {:error, :invalid_rollback_evidence}
    end
  end

  defp validate_rollback_evidence(journal, supplied) do
    with :ok <- validate_rollback_fingerprint(journal, supplied) do
      validate_rollback_evidence_domain(journal, supplied)
    end
  end

  # 非 nil fingerprint 必须同时跨过 Journal durable JSON 与 schema 权威的 exact 三键形态，
  # 之后才轮到严格 `===` 比较；`3` 与 `3.0` 结构相等但不是同一个取证 term。
  # 显式 nil 只在初始 proof 失败/superseded 的原子三元组里合法：published 行绝不能被清空。
  # supplied presence 与 effective value 是两个不同概念：
  #   - supplied presence 决定「显式 nil / 省略」「原子三元组」「哪个字段先冲突」；
  #   - effective value 是「供应值优先，否则已观察值」，即**这次 rollback 之后真正会被保留
  #     的 term**，因此必须在 SQL 之前被完整校验，attrs 省略也不例外。
  defp validate_rollback_fingerprint(journal, supplied) do
    requestable? = journal.phase in @rollback_requestable
    supplied? = Map.has_key?(supplied, :published_fingerprint)
    effective = Map.get(supplied, :published_fingerprint, journal.published_fingerprint)

    cond do
      # 任何会被保留的非 nil fingerprint 都必须跨过 Journal durable JSON 与 exact 三键语义
      # 形态——包含 attrs 省略时沿用的已观察值。
      not is_nil(effective) and not durable_fingerprint?(effective) ->
        {:error, :invalid_rollback_evidence}

      # PG `published` 的 fingerprint source-phase 不变量：effective fingerprint 必须非 nil。
      # 它位于 authority/phase 路由之后、omission / replay / creation / equality / CAS 之前，
      # 因此对「省略」「显式 nil」「含 nil fingerprint 的完整显式三元组」完全一致地生效——
      # claimed 行的原子创建例外是 phase-scoped 的，永远不能为 published 授权 nil。
      journal.phase == "published" and is_nil(effective) ->
        {:error, :invalid_rollback_evidence}

      # 省略：effective 就是已观察值，上面已校验完毕。
      not supplied? ->
        :ok

      # replay 域只需通过校验，差异由后续严格比较裁决为有序冲突。
      not requestable? ->
        :ok

      is_nil(effective) ->
        cond do
          # published 行绝不能被显式 nil 清空。
          not is_nil(journal.published_fingerprint) -> {:error, :invalid_rollback_evidence}
          # 显式 nil fingerprint 就是初始创建形态：三个 key 必须齐备。
          complete_rollback_triple?(supplied) -> :ok
          true -> {:error, :invalid_rollback_evidence}
        end

      effective === journal.published_fingerprint ->
        :ok

      true ->
        {:error, :invalid_rollback_evidence}
    end
  end

  defp complete_rollback_triple?(supplied),
    do: Map.has_key?(supplied, :recovery_evidence) and Map.has_key?(supplied, :last_error)

  defp durable_fingerprint?(fingerprint),
    do: Journal.json_evidence_valid?(fingerprint) and Journal.fingerprint_valid?(fingerprint)

  # evidence domain 分类。顺序固定：canonical-wrapper 命名空间归属 → 该 domain 的
  # durable/phase 校验 → 严格保留或精确创建规则。与持久化 term 相等**绝不是**校验旁路。
  defp validate_rollback_evidence_domain(journal, supplied) do
    supplied? = Map.has_key?(supplied, :recovery_evidence)
    effective = Map.get(supplied, :recovery_evidence, journal.recovery_evidence)

    if is_nil(effective) do
      validate_nil_effective_evidence(journal)
    else
      classify_rollback_evidence(journal, supplied, effective, supplied?)
    end
  end

  # correction handoff §7：PG `published` 必须持有它自己的 phase-valid 成功 canonical
  # wrapper——即使两个 attrs 都被省略。没有 evidence 的 published 行不是合法的 rollback
  # 前置状态，必须在 SQL 之前精确拒绝。proof 之前的 prepared/claimed 则可以没有 evidence
  # （last-error-only 竞争依赖这一点）。
  defp validate_nil_effective_evidence(%Journal{phase: "published"}),
    do: {:error, :invalid_rollback_evidence}

  defp validate_nil_effective_evidence(_journal), do: :ok

  # durable/shape 合法性与 source-phase/origin 合法性是**两道独立的门**，且顺序固定：
  #
  #   1. 分类 canonical namespace 与 generic
  #   2. 校验 rollback 目标域的 durable/semantic 形态
  #   3. 校验 source-phase 与 origin 合法性
  #   4. 才轮到创建规则或严格保留/replay 规则
  #   5. 之后才是 stable-code / 严格比较 / CAS
  #
  # 「省略」与「显式相等」都**不能**建立 origin：结构合法的 term 仍必须证明它在该 source
  # phase 上有合法来源，否则一律精确 fail closed。
  defp classify_rollback_evidence(journal, supplied, evidence, supplied?) do
    with :ok <- validate_rollback_evidence_shape(evidence) do
      validate_rollback_evidence_origin(journal, supplied, evidence, supplied?)
    end
  end

  # 第 2 道门：目标 rollback 域的形态。一旦声称 canonical wrapper 命名空间，就绝不允许在
  # 畸形时回落成 generic evidence。
  defp validate_rollback_evidence_shape(evidence) do
    valid? =
      if canonical_wrapper_namespace?(evidence) do
        PublishedProof.validate_durable_evidence("rollback_pending", evidence) == :ok
      else
        Journal.json_evidence_valid?(evidence)
      end

    if valid?, do: :ok, else: {:error, :invalid_rollback_evidence}
  end

  # 第 3 道门：source-phase / evidence-origin 矩阵。

  # replay 域：形态已验，差异交给冻结的有序严格比较；省略字段仍是零写入 replay。
  defp validate_rollback_evidence_origin(
         %Journal{phase: phase},
         _supplied,
         _evidence,
         _supplied?
       )
       when phase in @rollback_requested_idempotent,
       do: :ok

  # PG `published`：effective evidence 必须是**对 source phase `published` 也合法**的成功
  # canonical published wrapper，而不只是对 rollback 目标域合法。generic evidence、
  # nil-proof/failure/superseded wrapper 与其余 published-invalid wrapper 一律拒绝；
  # 省略与「显式供应且严格相等」适用同一条规则。
  defp validate_rollback_evidence_origin(
         %Journal{phase: "published"} = journal,
         _supplied,
         evidence,
         supplied?
       ) do
    cond do
      not (canonical_wrapper_namespace?(evidence) and
               PublishedProof.validate_durable_evidence("published", evidence) == :ok) ->
        {:error, :invalid_rollback_evidence}

      # 第 4 道门保持不变：严格保留。显式供应时必须与已观察 term 严格 `===`，
      # 绝不允许替换成另一个「独立看同样合法」的成功 wrapper。
      supplied? and evidence !== journal.recovery_evidence ->
        {:error, :invalid_rollback_evidence}

      true ->
        :ok
    end
  end

  # ordinary PG `prepared` / `claimed`（架构再裁决）：
  #
  #   * 冻结的完整显式原子三元组是唯一的**创建**入口，且各自仍要求 observed evidence 为
  #     nil 并通过既有 durable / exact-shape / stable-code / 三键齐备检查；
  #   * pre-proof 行上**已观察到的 canonical wrapper** 绝不是合法来源：proof 尚未通过，
  #     canonical 证据不可能合法地先于它存在，omission 与 equality 都不得建立 origin；
  #   * 已观察到的 **generic forensic evidence**（如冻结的 `mark_error/4` 在 claimed 上写入
  #     的重试证据）在通过 Journal durable 校验后，可原样跨越 rollback：省略即保留，显式
  #     供应必须严格 `===` 已观察值（parent Green §7.2）；
  #   * fresh / replacement generic evidence 一律拒绝。
  defp validate_rollback_evidence_origin(journal, supplied, evidence, supplied?) do
    cond do
      supplied? and initial_nil_proof_creation?(journal, supplied, evidence) -> :ok
      supplied? and exact_generic_creation?(journal, supplied, evidence) -> :ok
      canonical_wrapper_namespace?(evidence) -> {:error, :invalid_rollback_evidence}
      evidence === journal.recovery_evidence -> :ok
      true -> {:error, :invalid_rollback_evidence}
    end
  end

  # 只要出现这两个 key 之一，就属于 canonical wrapper domain。
  defp canonical_wrapper_namespace?(evidence) when is_map(evidence),
    do: Map.has_key?(evidence, "published_proof") or Map.has_key?(evidence, "last_failure")

  defp canonical_wrapper_namespace?(_evidence), do: false

  # 初始 nil-proof 原子三元组：PG `claimed`、observed fingerprint 与 evidence 均为 nil、
  # 三个 key 齐备、fingerprint 恰为 nil，且 last_error 与 wrapper outcome 精确对应。
  defp initial_nil_proof_creation?(%Journal{phase: "claimed"} = journal, supplied, evidence) do
    is_nil(journal.published_fingerprint) and is_nil(journal.recovery_evidence) and
      Map.fetch(supplied, :published_fingerprint) == {:ok, nil} and
      Map.has_key?(supplied, :recovery_evidence) and
      match?({:ok, _code}, Map.fetch(supplied, :last_error)) and
      nil_proof_wrapper_code(evidence) == Map.get(supplied, :last_error)
  end

  defp initial_nil_proof_creation?(_journal, _supplied, _evidence), do: false

  # 只有在 wrapper 已被证明是 canonical nil-proof 形态之后才推导期望 code。
  # failed `fenced` 不在映射里，因此永远无法匹配任何 last_error。
  defp nil_proof_wrapper_code(%{"published_proof" => nil, "last_failure" => failure})
       when is_map(failure) do
    case {Map.get(failure, "status"), Map.get(failure, "class")} do
      {"superseded", _class} -> @stable_rollback_codes.superseded
      {"failed", class} when is_binary(class) -> stable_failed_code(class)
      _other -> nil
    end
  end

  defp nil_proof_wrapper_code(_evidence), do: nil

  defp stable_failed_code(class) do
    Enum.find_value(@stable_rollback_codes, fn {outcome, code} ->
      outcome != :superseded and Atom.to_string(outcome) == class and code
    end)
  end

  # 必须逐字相等：map 字面量作为 **pattern** 只做子集匹配，会把「多一个 key」的漂移形态
  # 误判为合法创建，因此这里一律用显式 `===` 比较，绝不用 pattern。
  defp exact_generic_creation?(%Journal{phase: "claimed"} = journal, supplied, evidence) do
    is_nil(journal.published_fingerprint) and is_nil(journal.recovery_evidence) and
      Map.fetch(supplied, :published_fingerprint) == {:ok, nil} and
      cond do
        evidence === @contract_violation_evidence ->
          Map.get(supplied, :last_error) === @contract_violation_error

        evidence === @journal_transition_evidence ->
          Map.get(supplied, :last_error) === @journal_transition_error

        true ->
          false
      end
  end

  defp exact_generic_creation?(_journal, _supplied, _evidence), do: false

  # rollback_pending / rolled_back：校验已经成功，这里只做严格字段比较。完全一致才幂等
  # 成功，任何差异零写入并按确定顺序返回冲突字段。
  defp replay_rollback(journal, supplied, opts) do
    case first_strict_difference(journal, supplied) do
      nil -> replay_idempotent_result(journal, supplied, opts)
      field -> {:error, {:rollback_evidence_conflict, field}}
    end
  end

  defp first_strict_difference(row, supplied) do
    Enum.find(@rollback_replay_order, fn field ->
      case Map.fetch(supplied, field) do
        :error -> false
        {:ok, value} -> value !== Map.fetch!(row, field)
      end
    end)
  end

  # replay 先比调用方观察到的行，再对当前行做一次 fresh read 复核后才报告成功。
  defp replay_idempotent_result(journal, supplied, opts) do
    now = Keyword.get_lazy(opts, :now, &now/0)

    case get(journal.id, opts) do
      nil ->
        {:error, :not_found}

      %Journal{phase: phase} = current when phase == journal.phase ->
        cond do
          not idempotent_state?(journal, current, phase, now) ->
            {:error, {:stale_journal, current.phase, current.attempts}}

          field = first_strict_difference(current, supplied) ->
            {:error, {:rollback_evidence_conflict, field}}

          true ->
            {:ok, current}
        end

      %Journal{} = current ->
        {:error, {:stale_journal, current.phase, current.attempts}}
    end
  end

  @doc """
  按 object_version target 查 journal 已知的最大 generation（走 `obj_mut_target_idx`；
  无记录 → 0）。与 backend `current_epoch` 一起构成新 claim 的世代基数——两个来源取 max，
  避免读写 placement 分歧或 epoch 端点暂不可读时世代基数偏低（实现计划 B5 / B4 审查项 2）。
  """
  @spec max_generation(map(), keyword()) :: non_neg_integer()
  def max_generation(target, opts \\ [])

  def max_generation(%{bucket_name: bucket, object_key: key, version_id: version_id}, opts)
      when is_binary(bucket) and is_binary(key) and is_binary(version_id) do
    repo = Keyword.get(opts, :repo, Repo)

    Journal
    |> where(
      [j],
      j.bucket_name == ^bucket and j.object_key == ^key and j.version_id == ^version_id
    )
    |> select([j], max(j.generation))
    |> repo.one() || 0
  end

  @doc "读取单条 journal。"
  @spec get(Ecto.UUID.t(), keyword()) :: Journal.t() | nil
  def get(id, opts \\ []) when is_binary(id), do: Keyword.get(opts, :repo, Repo).get(Journal, id)

  @doc """
  列出当前到期且没有有效恢复租约的非终态 journal。

  `opts[:older_than_ms]`（可选，正整数）额外要求 `inserted_at <= now - older_than_ms`——
  CLI `--older-than SECONDS`（协议 §7 / 实现计划 B7）的落点：操作员可只处理创建已超过
  给定年龄的记录，避免与刚进入宽限窗口的 in-flight 请求擦肩。缺省不加该约束
  （`inserted_at` 是真实插入时刻，与调用者注入的逻辑 `:now` 属不同时钟，不得默认耦合）。
  """
  @spec list_due(keyword()) :: [Journal.t()]
  def list_due(opts \\ []) do
    repo = Keyword.get(opts, :repo, Repo)
    now = Keyword.get_lazy(opts, :now, &now/0)
    limit = positive_int(Keyword.get(opts, :limit), 100)

    Journal
    |> where(
      [j],
      j.phase in @nonterminal and j.next_attempt_at <= ^now and
        (is_nil(j.lease_expires_at) or j.lease_expires_at <= ^now)
    )
    |> older_than_filter(Keyword.get(opts, :older_than_ms), now)
    |> order_by([j], asc: j.next_attempt_at, asc: j.inserted_at, asc: j.id)
    |> limit(^limit)
    |> repo.all()
  end

  defp older_than_filter(query, older_than_ms, now)
       when is_integer(older_than_ms) and older_than_ms > 0 do
    inserted_before = DateTime.add(now, -older_than_ms, :millisecond)
    where(query, [j], j.inserted_at <= ^inserted_before)
  end

  defp older_than_filter(query, _older_than_ms, _now), do: query

  @doc "原子领取一个到期 journal 的恢复租约；不改变协议 phase。"
  @spec claim(Journal.t() | Ecto.UUID.t(), String.t(), keyword()) ::
          {:ok, Journal.t()} | {:error, mutation_error()}
  def claim(ref, lease_owner, opts \\ []) when is_binary(lease_owner) do
    if String.trim(lease_owner) == "" do
      {:error, :invalid_lease_owner}
    else
      claim_valid(ref, lease_owner, opts)
    end
  end

  defp claim_valid(ref, lease_owner, opts) do
    id = journal_id(ref)
    repo = Keyword.get(opts, :repo, Repo)
    now = Keyword.get_lazy(opts, :now, &now/0)
    lease_ms = positive_int(Keyword.get(opts, :lease_ms), @default_lease_ms)

    {count, _} =
      Journal
      |> where(
        [j],
        j.id == ^id and j.phase in @nonterminal and j.next_attempt_at <= ^now and
          (is_nil(j.lease_expires_at) or j.lease_expires_at <= ^now)
      )
      |> repo.update_all(
        set: [
          lease_owner: lease_owner,
          lease_expires_at: DateTime.add(now, lease_ms, :millisecond),
          updated_at: now
        ]
      )

    case {count, repo.get(Journal, id)} do
      {1, %Journal{} = row} -> {:ok, row}
      {0, nil} -> {:error, :not_found}
      {0, %Journal{}} -> {:error, :not_due_or_leased}
    end
  rescue
    error -> {:error, {:journal_claim_failed, Exception.message(error)}}
  end

  @doc "续租仍有效且身份完全匹配的恢复租约。"
  @spec renew_lease(Journal.t(), keyword()) :: {:ok, Journal.t()} | {:error, mutation_error()}
  def renew_lease(%Journal{} = journal, opts \\ []) do
    repo = Keyword.get(opts, :repo, Repo)
    now = Keyword.get_lazy(opts, :now, &now/0)
    lease_ms = positive_int(Keyword.get(opts, :lease_ms), @default_lease_ms)

    if active_lease?(journal, now) do
      query =
        Journal
        |> where(
          [j],
          j.id == ^journal.id and j.phase == ^journal.phase and
            j.attempts == ^journal.attempts
        )
        |> match_observed_lease(journal, now)

      {count, _} =
        repo.update_all(query,
          set: [lease_expires_at: DateTime.add(now, lease_ms, :millisecond), updated_at: now]
        )

      cas_result(repo, journal, count, nil, now)
    else
      {:error, :not_due_or_leased}
    end
  end

  @doc "显式释放仍有效且身份完全匹配的恢复租约。"
  @spec release_lease(Journal.t(), keyword()) :: {:ok, Journal.t()} | {:error, mutation_error()}
  def release_lease(%Journal{} = journal, opts \\ []) do
    repo = Keyword.get(opts, :repo, Repo)
    now = Keyword.get_lazy(opts, :now, &now/0)

    if active_lease?(journal, now) do
      query =
        Journal
        |> where(
          [j],
          j.id == ^journal.id and j.phase == ^journal.phase and
            j.attempts == ^journal.attempts
        )
        |> match_observed_lease(journal, now)

      {count, _} =
        repo.update_all(query, set: [lease_owner: nil, lease_expires_at: nil, updated_at: now])

      cas_result(repo, journal, count, nil, now)
    else
      {:error, :not_leased}
    end
  end

  # 与 transition_cas 同源的独立 CAS：除推进 rollback_pending 外强制 next_attempt_at = now
  # （普通 transition 不改 next_attempt_at；回滚请求必须让 recovery 立即可见）。
  defp request_rollback_cas(journal, supplied, opts) do
    repo = Keyword.get(opts, :repo, Repo)
    now = Keyword.get_lazy(opts, :now, &now/0)

    changeset =
      Journal.changeset(
        journal,
        Map.merge(supplied, %{phase: "rollback_pending", next_attempt_at: now})
      )

    if changeset.valid? do
      updates =
        changeset.changes
        |> Map.merge(supplied)
        |> Map.put(:next_attempt_at, now)
        |> Map.put(:updated_at, now)
        |> Map.to_list()

      query =
        Journal
        |> where(
          [j],
          j.id == ^journal.id and j.phase == ^journal.phase and
            j.attempts == ^journal.attempts
        )
        |> match_observed_lease(journal, now)

      {count, _} = repo.update_all(query, set: updates)
      rollback_cas_result(repo, journal, supplied, count, now)
    else
      {:error, :invalid_rollback_evidence}
    end
  rescue
    error -> {:error, {:journal_rollback_request_failed, Exception.message(error)}}
  end

  # rollback 专用 CAS 结果：绝不复用 generic terminal 幂等，否则输家会把从未持久化的
  # 变更报告成成功。恰好一次 UPDATE、恰好一次 fresh read、无重试、绝不改写 winner。
  defp rollback_cas_result(repo, journal, supplied, count, now) do
    case {count, repo.get(Journal, journal.id)} do
      {1, %Journal{} = row} ->
        {:ok, row}

      {0, nil} ->
        {:error, :not_found}

      {0, %Journal{phase: phase} = current}
      when phase in @rollback_requested_idempotent ->
        if idempotent_state?(journal, current, phase, now) do
          case first_strict_difference(current, supplied) do
            nil -> {:ok, current}
            field -> {:error, {:rollback_evidence_conflict, field}}
          end
        else
          {:error, {:stale_journal, current.phase, current.attempts}}
        end

      {0, %Journal{} = current} ->
        {:error, {:stale_journal, current.phase, current.attempts}}
    end
  end

  @doc """
  保留取证的运维错误更新（design D6 §3.3）：SQL update set **只含** `attempts`、
  `next_attempt_at`、bounded `last_error` 与 `updated_at`。

  lock、lease、restore、generic exception、facade contract violation 与 invalid durable
  proof 等路径上，既有 `published_fingerprint` / `recovery_evidence` 是取证权威，绝不被
  改写。CAS 与 `mark_error/4` 同源：id + 观察到的 phase/attempts/lease。

  `reason` 必须是 binary：稳定 code 按既有 bounded binary 策略逐字保留（只切一次
  grapheme，绝不加引号、绝不经 `inspect/2`）。任何非 binary reason 一律返回精确的
  `{:error, :invalid_operational_reason}`，且发生在 opts 解析、时间/backoff 计算与任何
  repo 访问**之前**；本入口没有 `inspect/2` 兜底。
  """
  @spec mark_operational_error(Journal.t(), String.t(), keyword()) ::
          {:ok, Journal.t()} | {:error, mutation_error()}
  def mark_operational_error(journal, reason, opts \\ [])

  # 最高优先子句：非 binary reason 在 phase 路由、opts 解析、时间/backoff 计算与任何 repo
  # 调用之前就返回精确公共错误，绝不经 inspect/1 洗白成一个「稳定 code」。
  def mark_operational_error(%Journal{}, reason, _opts) when not is_binary(reason),
    do: {:error, :invalid_operational_reason}

  def mark_operational_error(%Journal{phase: phase} = journal, reason, opts)
      when phase in @nonterminal do
    repo = Keyword.get(opts, :repo, Repo)
    now = Keyword.get_lazy(opts, :now, &now/0)
    backoff_ms = non_negative_int(Keyword.get(opts, :backoff_ms), @default_backoff_ms)

    updates = [
      attempts: journal.attempts + 1,
      next_attempt_at: DateTime.add(now, backoff_ms, :millisecond),
      last_error: bounded_error(reason),
      updated_at: now
    ]

    {count, _} = repo.update_all(observed_identity_query(journal, now), set: updates)
    cas_result(repo, journal, count, nil, now)
  rescue
    error -> {:error, {:journal_update_failed, Exception.message(error)}}
  end

  def mark_operational_error(%Journal{} = journal, _reason, _opts),
    do: {:error, {:illegal_error_update, journal.phase}}

  @doc """
  保留取证的隔离（design D6 §3.3）：SQL update set **只含** quarantine phase/timestamp、
  lease 清理、bounded `last_error` 与 `updated_at`。

  `attempts`、`next_attempt_at`、`published_fingerprint` 与 `recovery_evidence`（含畸形
  取证 term 的 JSON 编码）一律原样保留，供后续取证使用。

  `reason` 必须是 binary，按既有 bounded binary 策略逐字保留；任何非 binary reason 一律
  返回精确的 `{:error, :invalid_operational_reason}`，且发生在 opts 解析、时间计算与任何
  repo 访问**之前**；本入口没有 `inspect/2` 兜底。
  """
  @spec quarantine_preserving_evidence(Journal.t(), String.t(), keyword()) ::
          {:ok, Journal.t()} | {:error, mutation_error()}
  def quarantine_preserving_evidence(journal, reason, opts \\ [])

  def quarantine_preserving_evidence(%Journal{}, reason, _opts) when not is_binary(reason),
    do: {:error, :invalid_operational_reason}

  def quarantine_preserving_evidence(%Journal{} = journal, reason, opts) do
    if "quarantined" in legal_targets(journal) do
      repo = Keyword.get(opts, :repo, Repo)
      now = Keyword.get_lazy(opts, :now, &now/0)

      updates = [
        phase: "quarantined",
        quarantined_at: now,
        lease_owner: nil,
        lease_expires_at: nil,
        last_error: bounded_error(reason),
        updated_at: now
      ]

      {count, _} = repo.update_all(observed_identity_query(journal, now), set: updates)

      # 不传 idempotent phase：不同 reason 的竞争者是真实 CAS 输家，绝不允许因为 winner
      # 已经 quarantined 就报告 `{:ok, winner}`。它恰好尝试一次 UPDATE，然后精确返回
      # `:not_found` 或 `{:stale_journal, phase, attempts}`。
      cas_result(repo, journal, count, nil, now)
    else
      {:error, {:illegal_transition, journal.phase, "quarantined"}}
    end
  rescue
    error -> {:error, {:journal_update_failed, Exception.message(error)}}
  end

  # 与 transition/mark_error 完全同源的观察身份匹配：id + phase + attempts + lease。
  defp observed_identity_query(journal, now) do
    Journal
    |> where(
      [j],
      j.id == ^journal.id and j.phase == ^journal.phase and j.attempts == ^journal.attempts
    )
    |> match_observed_lease(journal, now)
  end

  defp transition_cas(journal, target_phase, attrs, opts) do
    repo = Keyword.get(opts, :repo, Repo)
    now = Keyword.get_lazy(opts, :now, &now/0)

    attrs =
      attrs
      |> Map.take(@transition_fields)
      |> Map.put(:phase, target_phase)
      |> Map.merge(phase_timestamp(target_phase, now))

    changeset = Journal.changeset(journal, attrs)

    if changeset.valid? do
      updates =
        changeset.changes
        |> Map.merge(terminal_lease_update(target_phase))
        |> Map.put(:updated_at, now)
        |> Map.to_list()

      query =
        Journal
        |> where(
          [j],
          j.id == ^journal.id and j.phase == ^journal.phase and
            j.attempts == ^journal.attempts
        )
        |> match_observed_lease(journal, now)

      {count, _} = repo.update_all(query, set: updates)

      cas_result(repo, journal, count, target_phase, now)
    else
      {:error, changeset}
    end
  rescue
    error -> {:error, {:journal_transition_failed, Exception.message(error)}}
  end

  defp cas_result(repo, journal, count, idempotent_phase, now) do
    case {count, repo.get(Journal, journal.id)} do
      {1, %Journal{} = row} ->
        {:ok, row}

      {0, nil} ->
        {:error, :not_found}

      {0, %Journal{phase: ^idempotent_phase} = row} when not is_nil(idempotent_phase) ->
        if idempotent_state?(journal, row, idempotent_phase, now),
          do: {:ok, row},
          else: {:error, {:stale_journal, row.phase, row.attempts}}

      {0, %Journal{} = row} ->
        {:error, {:stale_journal, row.phase, row.attempts}}
    end
  end

  defp idempotent_result(journal, opts) do
    now = Keyword.get_lazy(opts, :now, &now/0)

    case get(journal.id, opts) do
      %Journal{phase: phase} = current when phase == journal.phase ->
        if idempotent_state?(journal, current, phase, now),
          do: {:ok, current},
          else: {:error, {:stale_journal, current.phase, current.attempts}}

      %Journal{} = current ->
        {:error, {:stale_journal, current.phase, current.attempts}}

      nil ->
        {:error, :not_found}
    end
  end

  defp phase_timestamp("metadata_committed", now), do: %{metadata_committed_at: now}
  defp phase_timestamp("finalized", now), do: %{finalized_at: now}
  defp phase_timestamp("rolled_back", now), do: %{rolled_back_at: now}
  defp phase_timestamp("quarantined", now), do: %{quarantined_at: now}
  defp phase_timestamp(_phase, _now), do: %{}

  defp journal_id(%Journal{id: id}), do: id
  defp journal_id(id) when is_binary(id), do: id

  defp match_observed_lease(query, %Journal{lease_owner: nil, lease_expires_at: nil}, _now) do
    where(query, [j], is_nil(j.lease_owner) and is_nil(j.lease_expires_at))
  end

  defp match_observed_lease(
         query,
         %Journal{lease_owner: owner, lease_expires_at: %DateTime{} = expires} = journal,
         now
       )
       when is_binary(owner) and owner != "" do
    where(
      query,
      [j],
      j.lease_owner == ^journal.lease_owner and
        j.lease_expires_at == ^expires and j.lease_expires_at > ^now
    )
  end

  defp match_observed_lease(query, _journal, _now), do: where(query, [j], false)

  defp legal_targets(%Journal{authority_mode: "sidecar", phase: "published"}),
    do: @sidecar_published_targets

  defp legal_targets(%Journal{phase: phase}), do: Map.get(@pg_graph, phase, [])

  defp terminal_lease_update(phase) when phase in @terminal,
    do: %{lease_owner: nil, lease_expires_at: nil}

  defp terminal_lease_update(_phase), do: %{}

  defp idempotent_state?(observed, current, target_phase, now) do
    observed.attempts == current.attempts and observed_lease_valid?(observed, now) and
      if target_phase in @terminal do
        is_nil(current.lease_owner) and is_nil(current.lease_expires_at)
      else
        same_lease?(observed, current)
      end
  end

  defp observed_lease_valid?(%Journal{lease_owner: nil, lease_expires_at: nil}, _now),
    do: true

  defp observed_lease_valid?(journal, now), do: active_lease?(journal, now)

  defp active_lease?(
         %Journal{lease_owner: owner, lease_expires_at: %DateTime{} = expires},
         now
       )
       when is_binary(owner) and owner != "",
       do: DateTime.compare(expires, now) == :gt

  defp active_lease?(_journal, _now), do: false

  defp same_lease?(left, right),
    do:
      left.lease_owner == right.lease_owner and
        left.lease_expires_at == right.lease_expires_at

  defp pop_id(attrs) do
    case Map.pop(attrs, :id) do
      {nil, rest} -> Map.pop(rest, "id")
      pair -> pair
    end
  end

  defp protocol_injections(attrs) do
    Enum.filter(@prepare_managed_fields, fn field ->
      Map.has_key?(attrs, field) or Map.has_key?(attrs, Atom.to_string(field))
    end)
  end

  defp drop_protocol_fields(attrs),
    do:
      Map.drop(
        attrs,
        @prepare_managed_fields ++ Enum.map(@prepare_managed_fields, &Atom.to_string/1)
      )

  # 唯一的共享 reason 转换边界（G2 shared stable-error amendment §3）：binary 稳定 code
  # 逐字保留（只经既有 `bounded_error/1` 的单次 grapheme 截断），非 binary 一律保持既有
  # legacy `inspect/2` 渲染。Commit/Recovery 因此不需要绕过 ObjectMutation、直写 Repo 或
  # 事后剥引号。
  defp error_text(reason) when is_binary(reason), do: bounded_error(reason)

  defp error_text(reason) do
    reason
    |> inspect(limit: 50, printable_limit: @max_error_chars)
    |> String.slice(0, @max_error_chars)
  end

  # design D6 §5.2 的 bounded 取证 reason：两个证据保全 API 只接受 binary，稳定 code 逐字
  # 保留（绝不加引号、绝不经 inspect/1），只切一次 grapheme。非 binary 已在最高优先子句
  # 返回 `:invalid_operational_reason`，因此这里不再有 inspect fallback。
  defp bounded_error(reason) when is_binary(reason),
    do: String.slice(reason, 0, @max_error_chars)

  defp positive_int(value, _default) when is_integer(value) and value > 0, do: value
  defp positive_int(_value, default), do: default
  defp non_negative_int(value, _default) when is_integer(value) and value >= 0, do: value
  defp non_negative_int(_value, default), do: default
  defp now, do: DateTime.utc_now()
end
