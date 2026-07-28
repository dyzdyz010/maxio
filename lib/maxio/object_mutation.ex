defmodule Maxio.ObjectMutation do
  @moduledoc "对象变更 journal 的唯一写入口；所有阶段和恢复租约更新均使用数据库 CAS。"

  import Ecto.Query

  alias Maxio.ObjectMutation.Journal
  alias Maxio.Repo

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
          | {:illegal_transition, String.t(), String.t()}
          | {:stale_journal, String.t(), non_neg_integer()}
          | Ecto.Changeset.t()

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
  Control/加速器的回滚请求入口（协议 §5：最终决定由 journal + backend CAS 作出）。

  phase ∈ prepared/claimed/published → CAS 到 rollback_pending 且 `next_attempt_at = now`
  （recovery 可立即接手）；rollback_pending/rolled_back 幂等；`metadata_committed` 及之后
  （含 finalize_pending/finalized）与 quarantined 一律
  `{:error, {:illegal_transition, phase, "rollback_pending"}}`——metadata_committed 禁回滚
  三层防线的 journal 前置层（另两层：`@pg_graph` 无回滚边、端点 restore 拒 committed epoch）。
  CAS 遵守与 transition 相同的 lease 匹配规则。
  """
  @spec request_rollback(Journal.t(), keyword()) ::
          {:ok, Journal.t()} | {:error, mutation_error()}
  def request_rollback(%Journal{} = journal, opts \\ []) do
    cond do
      journal.phase in @rollback_requestable ->
        request_rollback_cas(journal, opts)

      journal.phase in @rollback_requested_idempotent ->
        idempotent_result(journal, opts)

      true ->
        {:error, {:illegal_transition, journal.phase, "rollback_pending"}}
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
  defp request_rollback_cas(journal, opts) do
    repo = Keyword.get(opts, :repo, Repo)
    now = Keyword.get_lazy(opts, :now, &now/0)

    changeset = Journal.changeset(journal, %{phase: "rollback_pending", next_attempt_at: now})

    if changeset.valid? do
      updates =
        changeset.changes
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
      cas_result(repo, journal, count, "rollback_pending", now)
    else
      {:error, changeset}
    end
  rescue
    error -> {:error, {:journal_rollback_request_failed, Exception.message(error)}}
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

  defp error_text(reason) do
    reason
    |> inspect(limit: 50, printable_limit: @max_error_chars)
    |> String.slice(0, @max_error_chars)
  end

  defp positive_int(value, _default) when is_integer(value) and value > 0, do: value
  defp positive_int(_value, default), do: default
  defp non_negative_int(value, _default) when is_integer(value) and value >= 0, do: value
  defp non_negative_int(_value, default), do: default
  defp now, do: DateTime.utc_now()
end
