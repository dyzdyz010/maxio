defmodule Maxio.ObjectMutationTest do
  use Maxio.DataCase, async: false

  alias Maxio.ObjectMutation

  @now ~U[2026-07-10 06:00:00.000000Z]

  test "normal graph reaches finalized and committed metadata can never roll back" do
    assert {:ok, row} = ObjectMutation.prepare(attrs(), now: @now)
    assert row.phase == "prepared"

    assert {:ok, row} =
             ObjectMutation.transition(
               row,
               "claimed",
               %{previous_epoch: previous_epoch()},
               now: @now
             )

    assert {:ok, row} =
             ObjectMutation.transition(
               row,
               "published",
               %{published_fingerprint: fingerprint()},
               now: @now
             )

    assert {:ok, row} = ObjectMutation.transition(row, "metadata_committed", %{}, now: @now)
    assert row.metadata_committed_at == @now

    assert {:error, {:illegal_transition, "metadata_committed", "rollback_pending"}} =
             ObjectMutation.transition(row, "rollback_pending", %{}, now: @now)

    assert {:ok, row} = ObjectMutation.transition(row, "finalize_pending", %{}, now: @now)
    assert {:ok, row} = ObjectMutation.transition(row, "finalized", %{}, now: @now)
    assert row.finalized_at == @now

    assert {:error, {:illegal_transition, "finalized", "quarantined"}} =
             ObjectMutation.quarantine(row, :late, %{"check" => "terminal"}, now: @now)
  end

  test "pre-commit failure follows the explicit rollback branch" do
    {:ok, row} = ObjectMutation.prepare(attrs(), now: @now)
    {:ok, row} = ObjectMutation.transition(row, "claimed", %{}, now: @now)

    {:ok, row} =
      ObjectMutation.transition(
        row,
        "published",
        %{published_fingerprint: fingerprint()},
        now: @now
      )

    {:ok, row} = ObjectMutation.transition(row, "rollback_pending", %{}, now: @now)
    assert {:ok, rolled_back} = ObjectMutation.transition(row, "rolled_back", %{}, now: @now)
    assert rolled_back.rolled_back_at == @now
  end

  test "transition CAS is idempotent only at the exact requested phase" do
    {:ok, prepared} = ObjectMutation.prepare(attrs(), now: @now)
    assert {:ok, claimed} = ObjectMutation.transition(prepared, "claimed", %{}, now: @now)
    assert {:ok, ^claimed} = ObjectMutation.transition(prepared, "claimed", %{}, now: @now)

    assert {:ok, published} =
             ObjectMutation.transition(
               claimed,
               "published",
               %{published_fingerprint: fingerprint()},
               now: @now
             )

    assert {:error, {:stale_journal, "published", 0}} =
             ObjectMutation.transition(prepared, "claimed", %{}, now: @now)

    assert ObjectMutation.get(prepared.id).phase == published.phase
  end

  test "mark_error fences by phase and attempts while retaining retry evidence" do
    {:ok, prepared} = ObjectMutation.prepare(attrs(), now: @now)

    assert {:ok, failed_once} =
             ObjectMutation.mark_error(
               prepared,
               :enoent,
               %{"kind" => "missing_final", "kept_backup" => true},
               now: @now,
               backoff_ms: 2_500
             )

    assert failed_once.attempts == 1
    assert failed_once.next_attempt_at == DateTime.add(@now, 2_500, :millisecond)
    assert failed_once.last_error == ":enoent"
    assert failed_once.recovery_evidence == %{"kind" => "missing_final", "kept_backup" => true}

    assert {:error, {:stale_journal, "prepared", 1}} =
             ObjectMutation.mark_error(prepared, :late, %{"kind" => "stale"}, now: @now)
  end

  test "mark_error rejects unsafe evidence before CAS and leaves the journal unchanged" do
    {:ok, prepared} = ObjectMutation.prepare(attrs(), now: @now)

    too_deep =
      Enum.reduce(1..17, "leaf", fn depth, acc -> %{"level#{depth}" => acc} end)

    invalid_evidence = [
      %{kind: "atom-key"},
      %{"blob" => String.duplicate("x", 66_000)},
      too_deep
    ]

    Enum.each(invalid_evidence, fn evidence ->
      assert {:error, changeset} =
               ObjectMutation.mark_error(prepared, :invalid_evidence, evidence, now: @now)

      assert errors_on(changeset).recovery_evidence

      unchanged = ObjectMutation.get(prepared.id)
      assert unchanged.attempts == 0
      assert unchanged.next_attempt_at == prepared.next_attempt_at
      assert is_nil(unchanged.recovery_evidence)
      assert is_nil(unchanged.last_error)
    end)
  end

  test "quarantine is terminal and preserves exact recovery evidence" do
    {:ok, row} = ObjectMutation.prepare(attrs(), now: @now)
    {:ok, row} = ObjectMutation.transition(row, "claimed", %{}, now: @now)

    evidence = %{
      "final" => "missing",
      "epoch_quorum" => false,
      "backup" => "retained"
    }

    assert {:ok, quarantined} =
             ObjectMutation.quarantine(
               row,
               :insufficient_fencing_evidence,
               evidence,
               now: @now
             )

    assert quarantined.phase == "quarantined"
    assert quarantined.quarantined_at == @now
    assert quarantined.recovery_evidence == evidence
    assert quarantined.last_error =~ "insufficient_fencing_evidence"
  end

  test "due listing and lease claim are atomic and lease expiry makes work due again" do
    {:ok, row} = ObjectMutation.prepare(attrs(), now: @now)
    assert [due] = ObjectMutation.list_due(now: @now)
    assert due.id == row.id

    assert {:ok, claimed} = ObjectMutation.claim(row, "recovery-a", now: @now, lease_ms: 1_000)
    assert claimed.lease_owner == "recovery-a"
    assert claimed.lease_expires_at == DateTime.add(@now, 1_000, :millisecond)
    assert [] == ObjectMutation.list_due(now: @now)
    assert {:error, :not_due_or_leased} = ObjectMutation.claim(row.id, "recovery-b", now: @now)

    after_expiry = DateTime.add(@now, 1_001, :millisecond)
    assert [due_again] = ObjectMutation.list_due(now: after_expiry)
    assert due_again.id == row.id
    assert {:ok, reclaimed} = ObjectMutation.claim(row.id, "recovery-b", now: after_expiry)
    assert reclaimed.lease_owner == "recovery-b"
  end

  test "an expired lease holder cannot advance a journal reclaimed by another worker" do
    {:ok, row} = ObjectMutation.prepare(attrs(), now: @now)
    {:ok, first_lease} = ObjectMutation.claim(row, "recovery-a", now: @now, lease_ms: 1_000)

    after_expiry = DateTime.add(@now, 1_001, :millisecond)
    {:ok, second_lease} = ObjectMutation.claim(row, "recovery-b", now: after_expiry)

    assert {:error, {:stale_journal, "prepared", 0}} =
             ObjectMutation.transition(first_lease, "claimed", %{}, now: after_expiry)

    assert {:ok, claimed} =
             ObjectMutation.transition(second_lease, "claimed", %{}, now: after_expiry)

    assert claimed.phase == "claimed"
    assert claimed.lease_owner == "recovery-b"
    assert claimed.lease_expires_at == second_lease.lease_expires_at
  end

  test "an expired lease holder cannot transition or overwrite evidence before reclaim" do
    {:ok, row} = ObjectMutation.prepare(attrs(), now: @now)
    {:ok, lease} = ObjectMutation.claim(row, "recovery-a", now: @now, lease_ms: 1_000)
    expired_at = DateTime.add(@now, 1_001, :millisecond)

    assert {:error, {:stale_journal, "prepared", 0}} =
             ObjectMutation.transition(lease, "claimed", %{}, now: expired_at)

    assert {:error, {:stale_journal, "prepared", 0}} =
             ObjectMutation.mark_error(
               lease,
               :late,
               %{"source" => "expired"},
               now: expired_at
             )

    current = ObjectMutation.get(row.id)
    assert current.phase == "prepared"
    assert current.attempts == 0
    assert is_nil(current.last_error)
  end

  test "target shape validation rejects ambiguous multipart identity" do
    invalid =
      attrs()
      |> Map.merge(%{
        target_kind: "multipart_part",
        version_id: "null",
        upload_id: "upload-1",
        part_number: 1
      })

    assert {:error, changeset} = ObjectMutation.prepare(invalid, now: @now)
    assert "is not valid for this target kind" in errors_on(changeset).version_id
  end

  test "journal and epoch share multipart part and object key target validation" do
    multipart_part =
      attrs()
      |> Map.merge(%{
        target_kind: "multipart_part",
        version_id: nil,
        upload_id: "upload-1",
        part_number: 42
      })

    assert {:ok, row} = ObjectMutation.prepare(multipart_part, now: @now)
    assert row.target_kind == "multipart_part"
    assert row.part_number == 42

    traversal = Map.put(attrs(), :object_key, "../escape")
    assert {:error, traversal_changeset} = ObjectMutation.prepare(traversal, now: @now)
    assert errors_on(traversal_changeset).object_key

    invalid_part = Map.put(multipart_part, :part_number, 10_001)
    assert {:error, part_changeset} = ObjectMutation.prepare(invalid_part, now: @now)
    assert errors_on(part_changeset).part_number

    blank_upload = Map.put(multipart_part, :upload_id, "   ")
    assert {:error, upload_changeset} = ObjectMutation.prepare(blank_upload, now: @now)
    assert errors_on(upload_changeset).upload_id
  end

  test "object key byte bound and blank lease owners fail before database writes" do
    oversized = Map.put(attrs(), :object_key, String.duplicate("界", 342))
    assert byte_size(oversized.object_key) > 1024
    assert {:error, changeset} = ObjectMutation.prepare(oversized, now: @now)
    assert errors_on(changeset).object_key

    {:ok, row} = ObjectMutation.prepare(attrs(), now: @now)
    assert {:error, :invalid_lease_owner} = ObjectMutation.claim(row, "   ", now: @now)
    assert is_nil(ObjectMutation.get(row.id).lease_owner)
  end

  test "nonterminal transitions retain lease and explicit renew and release are fenced" do
    {:ok, row} = ObjectMutation.prepare(attrs(), now: @now)
    {:ok, lease} = ObjectMutation.claim(row, "recovery-a", now: @now, lease_ms: 2_000)
    within_lease = DateTime.add(@now, 500, :millisecond)

    assert {:ok, claimed} = ObjectMutation.transition(lease, "claimed", %{}, now: within_lease)
    assert claimed.lease_owner == lease.lease_owner
    assert claimed.lease_expires_at == lease.lease_expires_at

    assert {:ok, renewed} =
             ObjectMutation.renew_lease(claimed,
               now: DateTime.add(@now, 600, :millisecond),
               lease_ms: 5_000
             )

    assert DateTime.compare(renewed.lease_expires_at, claimed.lease_expires_at) == :gt

    assert {:error, {:stale_journal, "claimed", 0}} =
             ObjectMutation.transition(claimed, "claimed", %{}, now: within_lease)

    assert {:ok, released} =
             ObjectMutation.release_lease(
               renewed,
               now: DateTime.add(@now, 700, :millisecond)
             )

    assert is_nil(released.lease_owner)
    assert is_nil(released.lease_expires_at)
  end

  test "mark_error retains a live lease until explicit release" do
    {:ok, row} = ObjectMutation.prepare(attrs(), now: @now)
    {:ok, lease} = ObjectMutation.claim(row, "recovery-a", now: @now, lease_ms: 2_000)

    assert {:ok, failed} =
             ObjectMutation.mark_error(
               lease,
               :retry,
               %{"final" => "unchanged"},
               now: DateTime.add(@now, 100, :millisecond),
               backoff_ms: 0
             )

    assert failed.lease_owner == "recovery-a"
    assert failed.lease_expires_at == lease.lease_expires_at

    assert {:ok, released} =
             ObjectMutation.release_lease(
               failed,
               now: DateTime.add(@now, 200, :millisecond)
             )

    assert is_nil(released.lease_owner)
  end

  test "terminal transitions clear a valid recovery lease" do
    {:ok, row} = ObjectMutation.prepare(attrs(), now: @now)
    {:ok, row} = ObjectMutation.claim(row, "recovery-a", now: @now, lease_ms: 5_000)
    {:ok, row} = ObjectMutation.transition(row, "claimed", %{}, now: @now)

    {:ok, row} =
      ObjectMutation.transition(
        row,
        "published",
        %{published_fingerprint: fingerprint()},
        now: @now
      )

    {:ok, row} = ObjectMutation.transition(row, "rollback_pending", %{}, now: @now)
    assert {:ok, terminal} = ObjectMutation.transition(row, "rolled_back", %{}, now: @now)
    assert is_nil(terminal.lease_owner)
    assert is_nil(terminal.lease_expires_at)
  end

  test "prepare rejects caller supplied protocol state" do
    injected =
      attrs()
      |> Map.merge(%{
        phase: "finalized",
        attempts: 99,
        next_attempt_at: @now,
        lease_owner: "forged",
        lease_expires_at: DateTime.add(@now, 60, :second),
        previous_epoch: %{},
        published_fingerprint: fingerprint(),
        recovery_evidence: %{},
        finalized_at: @now
      })

    assert {:error, changeset} = ObjectMutation.prepare(injected, now: @now)
    errors = errors_on(changeset)
    assert errors.phase
    assert errors.attempts
    assert errors.next_attempt_at
    assert errors.lease_owner
    assert errors.lease_expires_at
    assert errors.previous_epoch
    assert errors.published_fingerprint
    assert errors.recovery_evidence
    assert errors.finalized_at
    assert Repo.aggregate(Maxio.ObjectMutation.Journal, :count) == 0
  end

  test "sidecar publish is the authority commit line and can only finalize" do
    {:ok, row} = ObjectMutation.prepare(%{attrs() | authority_mode: "sidecar"}, now: @now)
    {:ok, row} = ObjectMutation.transition(row, "claimed", %{}, now: @now)

    {:ok, row} =
      ObjectMutation.transition(
        row,
        "published",
        %{published_fingerprint: fingerprint()},
        now: @now
      )

    assert {:error, {:illegal_transition, "published", "rollback_pending"}} =
             ObjectMutation.transition(row, "rollback_pending", %{}, now: @now)

    assert {:error, {:illegal_transition, "published", "metadata_committed"}} =
             ObjectMutation.transition(row, "metadata_committed", %{}, now: @now)

    assert {:ok, row} = ObjectMutation.transition(row, "finalize_pending", %{}, now: @now)
    assert is_nil(row.metadata_committed_at)
    assert {:ok, finalized} = ObjectMutation.transition(row, "finalized", %{}, now: @now)
    assert finalized.phase == "finalized"
  end

  test "JSON evidence requires recursive string keys and depth and size bounds" do
    atom_keyed = Map.put(attrs(), :placement_snapshot, %{endpoint: "disk-a"})
    assert {:error, atom_changeset} = ObjectMutation.prepare(atom_keyed, now: @now)
    assert errors_on(atom_changeset).placement_snapshot

    oversized =
      Map.put(attrs(), :placement_snapshot, %{"blob" => String.duplicate("x", 66_000)})

    assert {:error, size_changeset} = ObjectMutation.prepare(oversized, now: @now)
    assert errors_on(size_changeset).placement_snapshot

    too_deep =
      Enum.reduce(1..17, "leaf", fn depth, acc -> %{"level#{depth}" => acc} end)

    assert {:error, depth_changeset} =
             attrs()
             |> Map.put(:placement_snapshot, too_deep)
             |> ObjectMutation.prepare(now: @now)

    assert errors_on(depth_changeset).placement_snapshot
  end

  test "previous epoch and published fingerprint require concrete complete shapes" do
    {:ok, row} = ObjectMutation.prepare(attrs(), now: @now)

    assert {:error, previous_changeset} =
             ObjectMutation.transition(
               row,
               "claimed",
               %{previous_epoch: %{"generation" => 6}},
               now: @now
             )

    assert errors_on(previous_changeset).previous_epoch

    {:ok, row} =
      ObjectMutation.transition(
        row,
        "claimed",
        %{previous_epoch: previous_epoch()},
        now: @now
      )

    assert {:error, fingerprint_changeset} =
             ObjectMutation.transition(
               row,
               "published",
               %{published_fingerprint: %{"etag" => "abc"}},
               now: @now
             )

    assert errors_on(fingerprint_changeset).published_fingerprint
  end

  # --- Task 3 R1：rollback attrs-map CAS + evidence-preserving operational updates ---
  #
  # 正式 design D6 与 plan Task 3 Step 2 冻结了三个持久化 API：
  #
  #   request_rollback(journal, attrs, opts \\ [])
  #   mark_operational_error(journal, reason, opts \\ [])
  #   quarantine_preserving_evidence(journal, reason, opts \\ [])
  #
  # `attrs` 只允许 :published_fingerprint / :recovery_evidence / :last_error；phase、
  # authority、fingerprint/evidence domain、JSON/65,536-byte 与 bounded last error 全部在
  # SQL 之前校验，随后由单条 update_all 原子写入。零写入断言一律比较**完整持久化行**
  # （`Map.from_struct/1` 去掉 `:__meta__`），固定时间戳不得给写入留藏身处。

  @proof_unavailable_error "published_proof_failed:proof:unavailable"
  @contract_violation_error "published_proof_contract_violation:proof"
  @journal_transition_error "published_proof_journal_transition:failed"
  @restore_error "object_mutation:restore_failed"

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

  # 编译安全的 capability seam：未实现的正式 API 以具名断言失败，而不是 undefined-function
  # 编译警告或 UndefinedFunctionError。G1 之后机械替换为直呼公共函数。
  defp task3_capability!(fun, arity) do
    assert Code.ensure_loaded?(ObjectMutation)

    assert function_exported?(ObjectMutation, fun, arity),
           "T3-R1: Maxio.ObjectMutation.#{fun}/#{arity} 尚未实现" <>
             "（正式 design D6 / plan Task 3 Step 2）"
  end

  defp task3_request_rollback(journal, attrs, opts) do
    task3_capability!(:request_rollback, 3)
    ObjectMutation.request_rollback(journal, attrs, opts)
  end

  defp task3_request_rollback(journal, attrs) do
    task3_capability!(:request_rollback, 2)
    ObjectMutation.request_rollback(journal, attrs)
  end

  defp task3_mark_operational_error(journal, reason, opts) do
    task3_capability!(:mark_operational_error, 3)
    ObjectMutation.mark_operational_error(journal, reason, opts)
  end

  defp task3_quarantine_preserving_evidence(journal, reason, opts) do
    task3_capability!(:quarantine_preserving_evidence, 3)
    ObjectMutation.quarantine_preserving_evidence(journal, reason, opts)
  end

  # --- journal fixtures ---

  defp prepared_journal!(overrides) do
    {:ok, row} = ObjectMutation.prepare(Map.merge(attrs(), overrides), now: @now)
    row
  end

  defp claimed_journal!(overrides \\ %{}) do
    row = prepared_journal!(overrides)

    {:ok, row} =
      ObjectMutation.transition(row, "claimed", %{previous_epoch: previous_epoch()}, now: @now)

    row
  end

  defp published_journal!(overrides \\ %{}) do
    row = claimed_journal!(overrides)

    {:ok, published} =
      ObjectMutation.transition(
        row,
        "published",
        %{published_fingerprint: fingerprint(), recovery_evidence: proof_wrapper!()},
        now: @now
      )

    published
  end

  defp finalize_pending_journal!(overrides) do
    row = published_journal!(overrides)
    {:ok, row} = ObjectMutation.transition(row, "metadata_committed", %{}, now: @now)
    {:ok, row} = ObjectMutation.transition(row, "finalize_pending", %{}, now: @now)
    row
  end

  # --- canonical evidence fixtures ---

  defp proof_wrapper!() do
    {:ok, wrapper} =
      Maxio.Storage.PublishedProof.journal_evidence("published", successful_proof!(), nil)

    wrapper
  end

  defp successful_proof!() do
    {:ok, {:verified, proof}} =
      Maxio.Storage.PublishedProof.classify(1, [
        {"local", Maxio.Storage.PublishedProof.verified("local", %{})}
      ])

    proof
  end

  # 与 proof_wrapper!/0 term 不同、但独立看同样合法的成功 canonical wrapper：
  # 两个 verified endpoint 使 required/verified/observed_owned 计数不同。
  defp alternate_proof_wrapper!() do
    {:ok, {:verified, proof}} =
      Maxio.Storage.PublishedProof.classify(2, [
        {"ordinal:0", Maxio.Storage.PublishedProof.verified("ordinal:0", %{})},
        {"ordinal:1", Maxio.Storage.PublishedProof.verified("ordinal:1", %{})}
      ])

    {:ok, wrapper} =
      Maxio.Storage.PublishedProof.journal_evidence("published", proof, nil)

    wrapper
  end

  defp nil_proof_failure_wrapper!() do
    {:error, {:published_proof_failed, :unavailable, failure}} =
      Maxio.Storage.PublishedProof.classify(1, [
        {"local", Maxio.Storage.PublishedProof.failed(:unavailable, "local", %{owned: true})}
      ])

    {:ok, wrapper} =
      Maxio.Storage.PublishedProof.journal_evidence("rollback_pending", nil, failure)

    wrapper
  end

  # JSON-safe、但绝不是合法 canonical wrapper 的取证残留（多一个 key）。运维更新必须原样保留
  # 它以供取证，而不是修复或覆写。
  defp malformed_forensic_wrapper!() do
    Map.put(proof_wrapper!(), "forensic_note", "durable_validator_invalid")
  end

  # 按 `byte_size(Jason.encode!/1)` 精确校准的 ASCII padding generic evidence。
  defp generic_evidence_of_bytes!(total) do
    base = %{"authority_mode" => "pg", "stage" => "restore", "pad" => ""}
    overhead = byte_size(Jason.encode!(base))
    evidence = %{base | "pad" => String.duplicate("x", total - overhead)}

    assert byte_size(Jason.encode!(evidence)) == total
    evidence
  end

  # --- 完整行快照 / 直接播种 / SQL 取证 ---

  defp row_snapshot!(id) do
    id |> ObjectMutation.get() |> Map.from_struct() |> Map.delete(:__meta__)
  end

  defp assert_row_unchanged!(id, snapshot), do: assert(row_snapshot!(id) == snapshot)

  # 窄口径 `Repo.update_all` 旁路：只用于把「已观察到的」取证 term 直接播种进测试行，
  # 绕过 changeset，从而独立隔离 request_rollback 自身的 size/preservation 谓词。
  defp seed_recovery_evidence!(journal, evidence) do
    {1, _} =
      Repo.update_all(
        from(j in Maxio.ObjectMutation.Journal, where: j.id == ^journal.id),
        set: [recovery_evidence: evidence]
      )

    ObjectMutation.get(journal.id)
  end

  # 相等的字段值无法证明某列不在 SQL update set 中，因此经既有 Repo telemetry 捕获真实
  # UPDATE 语句并断言精确 SET 列名。
  # 捕获必须无竞态且单语句：只接受与本测试进程同源的 callback，目标函数返回后先 detach
  # 唯一 handler 再排空信箱，最后要求 object_mutations 的 UPDATE 恰好只有一条。
  defp capture_repo_queries(fun) do
    ref = make_ref()
    parent = self()
    handler_id = {:task3_repo_query_capture, ref}

    :telemetry.attach(
      handler_id,
      [:maxio, :repo, :query],
      fn _event, _measurements, metadata, _config ->
        if self() == parent, do: send(parent, {ref, metadata.query})
      end,
      nil
    )

    try do
      result = fun.()
      :telemetry.detach(handler_id)
      {result, drain_queries(ref, [])}
    after
      # detach 幂等：已解绑时返回 {:error, :not_found}。
      :telemetry.detach(handler_id)
    end
  end

  defp drain_queries(ref, acc) do
    receive do
      {^ref, query} -> drain_queries(ref, [query | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp update_set_columns!(queries) do
    updates =
      Enum.filter(queries, fn query ->
        String.starts_with?(query, "UPDATE") and String.contains?(query, "object_mutations")
      end)

    assert [sql] = updates,
           "object_mutations 的 UPDATE 语句必须恰好一条：#{inspect(updates)}"

    assert [_full, set_clause] = Regex.run(~r/ SET (.+?) WHERE /s, sql)

    set_clause
    |> String.split(", ")
    |> Enum.map(fn assignment ->
      assignment |> String.split(" = ") |> hd() |> String.trim() |> String.trim("\"")
    end)
    |> Enum.sort()
  end

  # --- §3 公共 API 形态与非法 authority/phase 结果 ---

  @tag :task3_red_core
  test "task3 red: rollback public API is exactly the attrs-map arities" do
    assert Code.ensure_loaded?(ObjectMutation)

    # 新 attrs-map API：/3 与默认 opts 的 /2。
    assert function_exported?(ObjectMutation, :request_rollback, 3),
           "T3-R1: Maxio.ObjectMutation.request_rollback/3 尚未实现"

    assert function_exported?(ObjectMutation, :request_rollback, 2),
           "T3-R1: Maxio.ObjectMutation.request_rollback/2（默认 opts）尚未实现"

    # 旧 arity-1 入口必须彻底消失：不留歧义 shim。
    refute function_exported?(ObjectMutation, :request_rollback, 1),
           "T3-R1: 旧 Maxio.ObjectMutation.request_rollback/1 仍被导出，attrs-map 迁移未完成"
  end

  @tag :task3_red_core
  test "task3 red: default-opts request_rollback/2 behaves identically to /3" do
    evidence = nil_proof_failure_wrapper!()

    supplied = %{
      published_fingerprint: nil,
      recovery_evidence: evidence,
      last_error: @proof_unavailable_error
    }

    explicit = claimed_journal!(%{object_key: "path/to/explicit.bin"})
    defaulted = claimed_journal!(%{object_key: "path/to/defaulted.bin"})

    assert {:ok, explicit_row} = task3_request_rollback(explicit, supplied, [])
    assert {:ok, defaulted_row} = task3_request_rollback(defaulted, supplied)

    for row <- [explicit_row, defaulted_row] do
      assert row.phase == "rollback_pending"
      assert is_nil(row.published_fingerprint)
      assert row.recovery_evidence == evidence
      assert row.last_error == @proof_unavailable_error
    end
  end

  @tag :task3_red_core
  test "task3 red: a legacy keyword list is never reinterpreted as rollback attrs" do
    journal = claimed_journal!()
    snapshot = row_snapshot!(journal.id)
    task3_capability!(:request_rollback, 3)

    # 故意用错类型（keyword list 而非 attrs map）：保留 apply/3 能力缝隙，避免类型检查器
    # 在编译期发出 incompatible-types 诊断（G1 review 契约第 6 条）。
    outcome =
      try do
        apply(ObjectMutation, :request_rollback, [journal, [now: @now]])
      rescue
        error -> {:raised, error}
      end

    # 冻结契约只规定 attrs 是 map；关键不变量是旧 keyword-opts 调用绝不会被当成 attrs
    # 静默完成一次回滚。
    refute match?({:ok, _row}, outcome)
    assert_row_unchanged!(journal.id, snapshot)
  end

  @tag :task3_red_core
  test "task3 red: invalid authority or phase returns the exact invalid_rollback_evidence result" do
    journal = published_journal!()
    {:ok, committed} = ObjectMutation.transition(journal, "metadata_committed", %{}, now: @now)
    snapshot = row_snapshot!(committed.id)

    assert task3_request_rollback(
             committed,
             %{last_error: @proof_unavailable_error},
             now: @now
           ) == {:error, :invalid_rollback_evidence}

    assert_row_unchanged!(committed.id, snapshot)

    finalize_pending = finalize_pending_journal!(%{object_key: "path/to/finalizing.bin"})
    finalize_snapshot = row_snapshot!(finalize_pending.id)

    assert task3_request_rollback(
             finalize_pending,
             %{last_error: @proof_unavailable_error},
             now: @now
           ) == {:error, :invalid_rollback_evidence}

    assert_row_unchanged!(finalize_pending.id, finalize_snapshot)
  end

  @tag :task3_red_core
  test "task3 red: rollback attrs allowlist rejects unknown and string-form keys before SQL" do
    journal = claimed_journal!()
    snapshot = row_snapshot!(journal.id)

    assert task3_request_rollback(
             journal,
             %{
               :published_fingerprint => nil,
               :bogus => 1,
               "last_error" => @proof_unavailable_error
             },
             now: @now
           ) == {:error, {:invalid_rollback_attrs, Enum.sort([:bogus, "last_error"])}}

    assert task3_request_rollback(journal, %{"recovery_evidence" => %{}}, now: @now) ==
             {:error, {:invalid_rollback_attrs, ["recovery_evidence"]}}

    assert_row_unchanged!(journal.id, snapshot)
  end

  @tag :task3_red_core
  test "task3 red: initial proof failure atomically writes phase, nil fingerprint, canonical evidence and stable error" do
    journal = claimed_journal!()
    evidence = nil_proof_failure_wrapper!()
    encoded = Jason.encode!(evidence)

    assert {:ok, rolled} =
             task3_request_rollback(
               journal,
               %{
                 published_fingerprint: nil,
                 recovery_evidence: evidence,
                 last_error: @proof_unavailable_error
               },
               now: @now
             )

    assert rolled.phase == "rollback_pending"
    assert rolled.next_attempt_at == @now
    assert is_nil(rolled.published_fingerprint)
    assert rolled.recovery_evidence == evidence
    assert Jason.encode!(rolled.recovery_evidence) == encoded
    # 稳定 code 逐字持久化：绝不经 inspect/1，绝不多出引号。
    assert rolled.last_error == @proof_unavailable_error
    refute String.contains?(rolled.last_error, "\"")
    assert rolled.attempts == journal.attempts

    persisted = ObjectMutation.get(journal.id)
    assert persisted.phase == "rollback_pending"
    assert persisted.recovery_evidence == evidence
    assert Jason.encode!(persisted.recovery_evidence) == encoded
    assert persisted.last_error == @proof_unavailable_error
  end

  # --- §4 两个 exact generic 创建形态的完整否定矩阵 ---

  @tag :task3_red_core
  test "task3 red: exact PG contract-violation evidence is created only from observed pg claimed" do
    creator = claimed_journal!(%{object_key: "path/to/contract-ok.bin"})

    assert {:ok, rolled} =
             task3_request_rollback(
               creator,
               %{
                 published_fingerprint: nil,
                 recovery_evidence: @contract_violation_evidence,
                 last_error: @contract_violation_error
               },
               now: @now
             )

    assert rolled.phase == "rollback_pending"
    assert rolled.recovery_evidence == @contract_violation_evidence
    assert map_size(rolled.recovery_evidence) == 4
    assert rolled.last_error == @contract_violation_error
    assert is_nil(rolled.published_fingerprint)

    legal_attrs = %{
      published_fingerprint: nil,
      recovery_evidence: @contract_violation_evidence,
      last_error: @contract_violation_error
    }

    # 1) 错误 authority：sidecar 在 claimed。
    sidecar = claimed_journal!(%{authority_mode: "sidecar", object_key: "path/to/sidecar.bin"})
    assert_rollback_rejected!(sidecar, legal_attrs)

    # 2) 错误 observed phase：PG 在 prepared，以及 PG 在 published。
    assert_rollback_rejected!(
      prepared_journal!(%{object_key: "path/to/prepared.bin"}),
      legal_attrs
    )

    assert_rollback_rejected!(
      published_journal!(%{object_key: "path/to/pub-cv.bin"}),
      legal_attrs
    )

    # 3) 形态漂移：缺 key、多 key、每个字段值漂移、错误 stable last_error、非 nil fingerprint。
    target = claimed_journal!(%{object_key: "path/to/contract-neg.bin"})

    # 每一个 key 都必须是强制的：逐个 Map.delete/2，而不是抽样。
    missing_key =
      Enum.map(
        Map.keys(@contract_violation_evidence),
        &Map.delete(@contract_violation_evidence, &1)
      )

    assert length(missing_key) == 4

    drifted =
      (missing_key ++
         [
           Map.put(@contract_violation_evidence, "extra", "x"),
           Map.put(@contract_violation_evidence, "authority_mode", "sidecar"),
           Map.put(@contract_violation_evidence, "stage", "finalize"),
           Map.put(@contract_violation_evidence, "outcome", "failed"),
           Map.put(@contract_violation_evidence, "mode", "finalize")
         ])
      |> Enum.map(&%{legal_attrs | recovery_evidence: &1})

    for attrs <- drifted, do: assert_rollback_rejected!(target, attrs)

    assert_rollback_rejected!(target, %{legal_attrs | last_error: @journal_transition_error})
    assert_rollback_rejected!(target, %{legal_attrs | last_error: @proof_unavailable_error})
    assert_rollback_rejected!(target, %{legal_attrs | published_fingerprint: fingerprint()})
  end

  @tag :task3_red_core
  test "task3 red: exact journal publish-transition evidence is created only from observed pg claimed" do
    creator = claimed_journal!(%{object_key: "path/to/transition-ok.bin"})

    assert {:ok, rolled} =
             task3_request_rollback(
               creator,
               %{
                 published_fingerprint: nil,
                 recovery_evidence: @journal_transition_evidence,
                 last_error: @journal_transition_error
               },
               now: @now
             )

    assert rolled.phase == "rollback_pending"
    assert rolled.recovery_evidence == @journal_transition_evidence
    assert map_size(rolled.recovery_evidence) == 3
    assert rolled.last_error == @journal_transition_error
    assert is_nil(rolled.published_fingerprint)

    legal_attrs = %{
      published_fingerprint: nil,
      recovery_evidence: @journal_transition_evidence,
      last_error: @journal_transition_error
    }

    sidecar =
      claimed_journal!(%{authority_mode: "sidecar", object_key: "path/to/sidecar-tx.bin"})

    assert_rollback_rejected!(sidecar, legal_attrs)

    assert_rollback_rejected!(
      prepared_journal!(%{object_key: "path/to/prepared-tx.bin"}),
      legal_attrs
    )

    assert_rollback_rejected!(
      published_journal!(%{object_key: "path/to/pub-tx.bin"}),
      legal_attrs
    )

    target = claimed_journal!(%{object_key: "path/to/transition-neg.bin"})

    missing_key =
      Enum.map(
        Map.keys(@journal_transition_evidence),
        &Map.delete(@journal_transition_evidence, &1)
      )

    assert length(missing_key) == 3

    drifted =
      (missing_key ++
         [
           Map.put(@journal_transition_evidence, "mode", "proof"),
           Map.put(@journal_transition_evidence, "authority_mode", "sidecar"),
           Map.put(@journal_transition_evidence, "stage", "verify_published"),
           Map.put(@journal_transition_evidence, "outcome", "contract_violation")
         ])
      |> Enum.map(&%{legal_attrs | recovery_evidence: &1})

    for attrs <- drifted, do: assert_rollback_rejected!(target, attrs)

    assert_rollback_rejected!(target, %{legal_attrs | last_error: @contract_violation_error})
    assert_rollback_rejected!(target, %{legal_attrs | last_error: @proof_unavailable_error})
    assert_rollback_rejected!(target, %{legal_attrs | published_fingerprint: fingerprint()})
  end

  defp assert_rollback_rejected!(journal, attrs) do
    snapshot = row_snapshot!(journal.id)

    assert task3_request_rollback(journal, attrs, now: @now) ==
             {:error, :invalid_rollback_evidence}

    assert_row_unchanged!(journal.id, snapshot)
  end

  # --- §5 preservation domain ---

  @tag :task3_red_core
  test "task3 red: a valid successful wrapper and fingerprint cross a pre-metadata rollback unchanged" do
    published = published_journal!()
    wrapper = published.recovery_evidence
    encoded = Jason.encode!(wrapper)

    assert published.published_fingerprint == fingerprint()
    refute is_nil(published.published_fingerprint)

    # metadata transaction 失败路径：同时逐字提交已观察到的非 nil fingerprint 与 wrapper。
    assert {:ok, rolled} =
             task3_request_rollback(
               published,
               %{
                 published_fingerprint: published.published_fingerprint,
                 recovery_evidence: wrapper
               },
               now: @now
             )

    assert rolled.phase == "rollback_pending"
    assert rolled.recovery_evidence == wrapper
    assert Jason.encode!(rolled.recovery_evidence) == encoded
    assert rolled.published_fingerprint == fingerprint()

    persisted = ObjectMutation.get(published.id)
    assert persisted.recovery_evidence == wrapper
    assert Jason.encode!(persisted.recovery_evidence) == encoded
    assert persisted.published_fingerprint == fingerprint()

    # fingerprint 漂移必须整行零写入地拒绝。
    drifting = published_journal!(%{object_key: "path/to/fp-drift.bin"})

    assert_rollback_rejected!(drifting, %{
      published_fingerprint: %{fingerprint() | "etag" => "drifted"},
      recovery_evidence: drifting.recovery_evidence
    })

    # 另一个「独立看也合法」的成功 canonical wrapper 同样不得替换已观察到的 wrapper。
    # 前置条件必须自身合法，否则隔离不到 replacement 谓词：它的 published_proof 非 nil、
    # last_failure 为 nil，并配合同一个已观察到的非 nil fingerprint。
    replacing = published_journal!(%{object_key: "path/to/wrapper-swap.bin"})
    alternate = alternate_proof_wrapper!()

    assert %{"published_proof" => %{"status" => "verified"}, "last_failure" => nil} = alternate
    refute is_nil(alternate["published_proof"])
    refute alternate == replacing.recovery_evidence
    refute is_nil(replacing.published_fingerprint)

    # 控制：replacement 本身经既有 PublishedProof 公共契约在 observed phase 与
    # rollback 目标 phase 上都合法，因此拒绝只能来自「非逐字相等的替换」。
    for phase <- ~w(published rollback_pending) do
      assert {:ok, ^alternate} =
               Maxio.Storage.PublishedProof.journal_evidence(
                 phase,
                 alternate["published_proof"],
                 nil
               )
    end

    assert_rollback_rejected!(replacing, %{
      published_fingerprint: replacing.published_fingerprint,
      recovery_evidence: alternate
    })
  end

  @tag :task3_red_core
  test "task3 red: sidecar authority and terminal phases reject rollback independently of evidence shape" do
    # 与两个 exact generic 形态无关的 authority gate：sidecar 行即使 attrs 为空或只做保留
    # 也必须拒绝。
    sidecar = claimed_journal!(%{authority_mode: "sidecar", object_key: "path/to/sc-gate.bin"})
    assert_rollback_rejected!(sidecar, %{})
    assert_rollback_rejected!(sidecar, %{last_error: @restore_error})

    {:ok, sidecar_with_evidence} =
      ObjectMutation.mark_error(
        sidecar,
        :restore_failed,
        %{"authority_mode" => "sidecar", "stage" => "restore"},
        now: @now,
        backoff_ms: 0
      )

    assert_rollback_rejected!(sidecar_with_evidence, %{
      recovery_evidence: sidecar_with_evidence.recovery_evidence
    })

    # 终态 phase 一律拒绝（rollback_pending / rolled_back 的 replay 语义另行冻结）。
    journal = finalize_pending_journal!(%{object_key: "path/to/terminal-final.bin"})
    {:ok, finalized} = ObjectMutation.transition(journal, "finalized", %{}, now: @now)
    assert_rollback_rejected!(finalized, %{})
    assert_rollback_rejected!(finalized, %{last_error: @proof_unavailable_error})

    quarantined_source = claimed_journal!(%{object_key: "path/to/terminal-quar.bin"})

    {:ok, quarantined} =
      ObjectMutation.quarantine(
        quarantined_source,
        :insufficient_fencing_evidence,
        %{"authority_mode" => "pg", "stage" => "restore"},
        now: @now
      )

    assert_rollback_rejected!(quarantined, %{})

    assert_rollback_rejected!(quarantined, %{
      recovery_evidence: quarantined.recovery_evidence
    })
  end

  @tag :task3_red_core
  test "task3 red: arbitrary generic evidence may only be preserved term-equal from the observed journal" do
    journal = claimed_journal!()
    observed = %{"authority_mode" => "pg", "stage" => "restore", "outcome" => "failed"}

    {:ok, journal} =
      ObjectMutation.mark_error(journal, :restore_failed, observed, now: @now, backoff_ms: 0)

    assert journal.recovery_evidence == observed

    # 与 observed journal 逐字相同：允许原样跨越 rollback。
    assert {:ok, rolled} =
             task3_request_rollback(
               journal,
               %{recovery_evidence: observed, last_error: @restore_error},
               now: @now
             )

    assert rolled.recovery_evidence == observed
    assert Jason.encode!(rolled.recovery_evidence) == Jason.encode!(observed)

    # 已观察到 generic evidence 的行上，替换成另一个 generic term 必须整行零写入地拒绝。
    replaceable = claimed_journal!(%{object_key: "path/to/replaceable.bin"})

    {:ok, replaceable} =
      ObjectMutation.mark_error(replaceable, :restore_failed, observed, now: @now, backoff_ms: 0)

    assert_rollback_rejected!(replaceable, %{
      recovery_evidence: %{observed | "outcome" => "conflict"},
      last_error: @restore_error
    })

    # 全新 generic map 同样不得由 request_rollback 引入。
    assert_rollback_rejected!(claimed_journal!(%{object_key: "path/to/fresh.bin"}), %{
      recovery_evidence: %{"authority_mode" => "pg", "stage" => "invented"}
    })
  end

  # --- §2 Journal 65,536/65,537-byte generic 门（与 60-KiB proof 门相互独立）---

  @tag :task3_red_core
  test "task3 red: an observed 65,537-byte forensic evidence term is rejected by the Journal size gate" do
    over_limit = generic_evidence_of_bytes!(65_537)

    journal =
      claimed_journal!(%{object_key: "path/to/oversized.bin"})
      |> seed_recovery_evidence!(over_limit)

    # 已观察到的行确实携带 65,537 byte 取证 term：因此拒绝只能来自尺寸门，
    # 而不是 preservation domain。
    assert journal.recovery_evidence == over_limit
    assert byte_size(Jason.encode!(journal.recovery_evidence)) == 65_537

    snapshot = row_snapshot!(journal.id)

    assert task3_request_rollback(
             journal,
             %{recovery_evidence: over_limit, last_error: @restore_error},
             now: @now
           ) == {:error, :invalid_rollback_evidence}

    assert_row_unchanged!(journal.id, snapshot)
  end

  @tag :task3_red_core
  test "task3 red: an observed 65,536-byte forensic evidence term crosses rollback term-equal" do
    at_limit = generic_evidence_of_bytes!(65_536)

    journal =
      claimed_journal!(%{object_key: "path/to/at-limit.bin"})
      |> seed_recovery_evidence!(at_limit)

    assert byte_size(Jason.encode!(journal.recovery_evidence)) == 65_536

    assert {:ok, rolled} =
             task3_request_rollback(
               journal,
               %{recovery_evidence: at_limit, last_error: @restore_error},
               now: @now
             )

    assert rolled.phase == "rollback_pending"
    assert rolled.recovery_evidence == at_limit
    assert byte_size(Jason.encode!(rolled.recovery_evidence)) == 65_536
  end

  # --- §6 CAS 丢失：真实 stale phase / attempts / lease ---

  @tag :task3_red_core
  test "task3 red: a real stale observed phase loses the rollback CAS with zero writes" do
    journal = claimed_journal!()
    evidence = nil_proof_failure_wrapper!()

    supplied = %{
      published_fingerprint: nil,
      recovery_evidence: evidence,
      last_error: @proof_unavailable_error
    }

    # 持久化行推进到 published，调用方仍持有 claimed 时的旧观察结构。
    {:ok, _published} =
      ObjectMutation.transition(
        journal,
        "published",
        %{published_fingerprint: fingerprint(), recovery_evidence: proof_wrapper!()},
        now: @now
      )

    snapshot = row_snapshot!(journal.id)

    assert task3_request_rollback(journal, supplied, now: @now) ==
             {:error, {:stale_journal, "published", 0}}

    assert_row_unchanged!(journal.id, snapshot)
  end

  @tag :task3_red_core
  test "task3 red: stale attempts and stale lease both lose the rollback CAS with zero writes" do
    evidence = nil_proof_failure_wrapper!()

    supplied = %{
      published_fingerprint: nil,
      recovery_evidence: evidence,
      last_error: @proof_unavailable_error
    }

    stale_attempts = claimed_journal!(%{object_key: "path/to/stale-attempts.bin"})

    {:ok, _advanced} =
      ObjectMutation.mark_error(stale_attempts, :retry, %{"stage" => "restore"}, now: @now)

    attempts_snapshot = row_snapshot!(stale_attempts.id)

    assert task3_request_rollback(stale_attempts, supplied, now: @now) ==
             {:error, {:stale_journal, "claimed", 1}}

    assert_row_unchanged!(stale_attempts.id, attempts_snapshot)

    leased = claimed_journal!(%{object_key: "path/to/stale-lease.bin"})
    {:ok, first} = ObjectMutation.claim(leased, "recovery-a", now: @now, lease_ms: 1_000)
    expired_at = DateTime.add(@now, 1_001, :millisecond)
    {:ok, _second} = ObjectMutation.claim(leased, "recovery-b", now: expired_at)
    lease_snapshot = row_snapshot!(leased.id)

    assert task3_request_rollback(first, supplied, now: expired_at) ==
             {:error, {:stale_journal, "claimed", 0}}

    assert_row_unchanged!(leased.id, lease_snapshot)
  end

  # --- replay / 终态幂等 / last_error 归一 ---

  @tag :task3_red_core
  test "task3 red: rollback_pending replay is term-equal idempotent and conflicts in exact field order" do
    journal = claimed_journal!()
    evidence = nil_proof_failure_wrapper!()

    supplied = %{
      published_fingerprint: nil,
      recovery_evidence: evidence,
      last_error: @proof_unavailable_error
    }

    assert {:ok, rolled} = task3_request_rollback(journal, supplied, now: @now)
    snapshot = row_snapshot!(rolled.id)

    # 逐字相同的 replay 成功且不改写任何字段。
    assert {:ok, replayed} = task3_request_rollback(rolled, supplied, now: @now)
    assert replayed.recovery_evidence == evidence
    assert replayed.last_error == @proof_unavailable_error
    assert_row_unchanged!(rolled.id, snapshot)

    # 差异按 [:published_fingerprint, :recovery_evidence, :last_error] 确定性短路。
    conflicts = [
      {%{
         published_fingerprint: fingerprint(),
         recovery_evidence: @contract_violation_evidence,
         last_error: "other"
       }, :published_fingerprint},
      {%{
         published_fingerprint: nil,
         recovery_evidence: @contract_violation_evidence,
         last_error: "other"
       }, :recovery_evidence},
      {%{published_fingerprint: nil, recovery_evidence: evidence, last_error: "other"},
       :last_error}
    ]

    for {attrs, field} <- conflicts do
      assert task3_request_rollback(rolled, attrs, now: @now) ==
               {:error, {:rollback_evidence_conflict, field}}

      assert_row_unchanged!(rolled.id, snapshot)
    end
  end

  @tag :task3_red_core
  test "task3 red: rolled_back validates supplied attrs, is terminally idempotent and never rewritten" do
    journal = claimed_journal!()
    evidence = nil_proof_failure_wrapper!()

    supplied = %{
      published_fingerprint: nil,
      recovery_evidence: evidence,
      last_error: @proof_unavailable_error
    }

    {:ok, rolled} = task3_request_rollback(journal, supplied, now: @now)
    {:ok, terminal} = ObjectMutation.transition(rolled, "rolled_back", %{}, now: @now)
    snapshot = row_snapshot!(terminal.id)

    # 无 attrs：终态幂等。
    assert {:ok, %{phase: "rolled_back"}} = task3_request_rollback(terminal, %{}, now: @now)

    # 有 attrs：先校验，逐字相同才成功。
    assert {:ok, %{phase: "rolled_back"}} = task3_request_rollback(terminal, supplied, now: @now)

    assert task3_request_rollback(
             terminal,
             %{published_fingerprint: nil, recovery_evidence: evidence, last_error: "other"},
             now: @now
           ) == {:error, {:rollback_evidence_conflict, :last_error}}

    assert task3_request_rollback(terminal, %{:bogus => 1}, now: @now) ==
             {:error, {:invalid_rollback_attrs, [:bogus]}}

    assert_row_unchanged!(terminal.id, snapshot)
  end

  @tag :task3_red_core
  test "task3 red: supplied last_error binaries are normalized once and stored verbatim" do
    journal = claimed_journal!()
    long = String.duplicate("界", 3_000)

    assert {:ok, rolled} = task3_request_rollback(journal, %{last_error: long}, now: @now)

    assert rolled.last_error == String.slice(long, 0, 2_000)
    assert String.length(rolled.last_error) == 2_000
    refute String.contains?(rolled.last_error, "\"")

    snapshot = row_snapshot!(rolled.id)

    # replay 比较发生在同一次 String.slice/3 规范化之后：原始超长输入仍视为 term-equal。
    assert {:ok, %{phase: "rollback_pending"}} =
             task3_request_rollback(rolled, %{last_error: long}, now: @now)

    assert task3_request_rollback(rolled, %{last_error: :not_a_binary}, now: @now) ==
             {:error, :invalid_rollback_evidence}

    assert_row_unchanged!(rolled.id, snapshot)
  end

  # --- §7 evidence-preserving 运维更新：精确 SQL update set ---

  @later DateTime.add(@now, 5, :second)

  defp forensic_operational_row!(key) do
    journal = finalize_pending_journal!(%{object_key: key})

    {:ok, leased} =
      ObjectMutation.claim(journal, "recovery-sentinel", now: @now, lease_ms: 60_000)

    seed_recovery_evidence!(leased, malformed_forensic_wrapper!())
  end

  @tag :task3_red_core
  test "task3 red: mark_operational_error updates only attempts, next attempt, last error and updated_at" do
    row = forensic_operational_row!("path/to/operational.bin")
    evidence = row.recovery_evidence
    encoded = Jason.encode!(evidence)

    # 起点携带互不相同的 lease / 时间戳 / fingerprint / evidence sentinel。
    assert evidence == malformed_forensic_wrapper!()
    assert row.lease_owner == "recovery-sentinel"
    assert row.published_fingerprint == fingerprint()
    assert row.metadata_committed_at == @now

    {result, queries} =
      capture_repo_queries(fn ->
        task3_mark_operational_error(row, "object_mutation:object_locked",
          now: @later,
          backoff_ms: 2_500
        )
      end)

    assert {:ok, updated} = result

    # 只允许这四列出现在 SQL update set 中。
    assert update_set_columns!(queries) == [
             "attempts",
             "last_error",
             "next_attempt_at",
             "updated_at"
           ]

    assert updated.attempts == row.attempts + 1
    assert updated.next_attempt_at == DateTime.add(@later, 2_500, :millisecond)
    assert updated.last_error == "object_mutation:object_locked"
    refute String.contains?(updated.last_error, "\"")

    # phase、lease、fingerprint、evidence 与全部终态时间戳原样保留。
    assert updated.phase == "finalize_pending"
    assert updated.lease_owner == row.lease_owner
    assert updated.lease_expires_at == row.lease_expires_at
    assert updated.published_fingerprint == row.published_fingerprint
    assert updated.metadata_committed_at == row.metadata_committed_at
    assert is_nil(updated.finalized_at)
    assert is_nil(updated.quarantined_at)
    assert is_nil(updated.rolled_back_at)
    assert updated.recovery_evidence == evidence
    assert Jason.encode!(updated.recovery_evidence) == encoded

    # updated_at 必须精确推进到调用方注入的 @later，返回行与回读行一致。
    assert updated.updated_at == @later

    persisted = ObjectMutation.get(row.id)
    assert persisted.updated_at == @later
    assert persisted.recovery_evidence == evidence
    assert Jason.encode!(persisted.recovery_evidence) == encoded
    assert persisted.published_fingerprint == row.published_fingerprint
  end

  @tag :task3_red_core
  test "task3 red: quarantine_preserving_evidence updates only quarantine phase, lease cleanup, last error and updated_at" do
    row = forensic_operational_row!("path/to/quarantine.bin")
    evidence = row.recovery_evidence
    encoded = Jason.encode!(evidence)

    {result, queries} =
      capture_repo_queries(fn ->
        task3_quarantine_preserving_evidence(row, "published_proof_invalid:durable", now: @later)
      end)

    assert {:ok, quarantined} = result

    assert update_set_columns!(queries) == [
             "last_error",
             "lease_expires_at",
             "lease_owner",
             "phase",
             "quarantined_at",
             "updated_at"
           ]

    assert quarantined.phase == "quarantined"
    assert quarantined.quarantined_at == @later
    assert is_nil(quarantined.lease_owner)
    assert is_nil(quarantined.lease_expires_at)
    assert quarantined.last_error == "published_proof_invalid:durable"
    refute String.contains?(quarantined.last_error, "\"")

    # attempts、next-attempt、fingerprint、evidence 与无关时间戳原样保留。
    assert quarantined.attempts == row.attempts
    assert quarantined.next_attempt_at == row.next_attempt_at
    assert quarantined.published_fingerprint == row.published_fingerprint
    assert quarantined.metadata_committed_at == row.metadata_committed_at
    assert is_nil(quarantined.finalized_at)
    assert quarantined.recovery_evidence == evidence
    assert Jason.encode!(quarantined.recovery_evidence) == encoded

    assert quarantined.updated_at == @later

    persisted = ObjectMutation.get(row.id)
    assert persisted.phase == "quarantined"
    assert persisted.updated_at == @later
    assert persisted.recovery_evidence == evidence
    assert Jason.encode!(persisted.recovery_evidence) == encoded
    assert persisted.published_fingerprint == row.published_fingerprint
  end

  @tag :task3_red_core
  test "task3 red: both operational APIs slice an over-long binary reason exactly once" do
    long = String.duplicate("界", 3_000)
    expected = String.slice(long, 0, 2_000)

    assert String.length(long) == 3_000
    assert String.length(expected) == 2_000

    operational = forensic_operational_row!("path/to/long-operational.bin")

    assert {:ok, updated} =
             task3_mark_operational_error(operational, long, now: @later, backoff_ms: 0)

    quarantine_row = forensic_operational_row!("path/to/long-quarantine.bin")

    assert {:ok, quarantined} =
             task3_quarantine_preserving_evidence(quarantine_row, long, now: @later)

    # 两个 API 共用同一个 bounded 边界：binary 逐字保留后只切一次到 2,000 graphemes，
    # 绝不经 inspect/1，绝不多出引号或省略号。
    for row <- [
          updated,
          quarantined,
          ObjectMutation.get(operational.id),
          ObjectMutation.get(quarantine_row.id)
        ] do
      assert row.last_error == expected
      assert String.length(row.last_error) == 2_000
      refute String.contains?(row.last_error, "\"")
      refute String.contains?(row.last_error, "...")
    end
  end

  # --- passing controls ---

  @tag :task3_red_core
  test "task3 control: rollback fixtures and direct forensic seeding hold today" do
    assert %{"published_proof" => nil, "last_failure" => %{"mode" => "proof"}} =
             nil_proof_failure_wrapper!()

    assert %{"published_proof" => %{"status" => "verified"}, "last_failure" => nil} =
             proof_wrapper!()

    # replacement fixture 独立看必须合法：成功 proof 非 nil、last_failure 为 nil，
    # 且经既有公共契约在 observed 与 rollback 目标 phase 上都可持久化，但 term 与
    # observed wrapper 不同。
    alternate = alternate_proof_wrapper!()

    assert %{"published_proof" => %{"status" => "verified"}, "last_failure" => nil} = alternate
    refute alternate == proof_wrapper!()

    for phase <- ~w(published rollback_pending) do
      assert {:ok, ^alternate} =
               Maxio.Storage.PublishedProof.journal_evidence(
                 phase,
                 alternate["published_proof"],
                 nil
               )
    end

    published = published_journal!()
    assert published.phase == "published"
    assert published.published_fingerprint == fingerprint()

    # 直接播种旁路可写入 changeset 拒绝的取证 term，并可被完整读回。
    seeded =
      claimed_journal!(%{object_key: "path/to/seeded.bin"})
      |> seed_recovery_evidence!(generic_evidence_of_bytes!(65_537))

    assert byte_size(Jason.encode!(seeded.recovery_evidence)) == 65_537

    malformed = malformed_forensic_wrapper!()
    assert map_size(malformed) == 3
    assert match?({:ok, _bytes}, Jason.encode(malformed))
  end

  @tag :task3_red_core
  test "task3 control: existing Journal generic gate accepts 65,536 and rejects 65,537 bytes" do
    journal = claimed_journal!(%{object_key: "path/to/gate.bin"})

    assert {:ok, at_limit} =
             ObjectMutation.mark_error(
               journal,
               :restore_failed,
               generic_evidence_of_bytes!(65_536),
               now: @now
             )

    assert byte_size(Jason.encode!(at_limit.recovery_evidence)) == 65_536

    assert {:error, changeset} =
             ObjectMutation.mark_error(
               at_limit,
               :restore_failed,
               generic_evidence_of_bytes!(65_537),
               now: @now
             )

    assert errors_on(changeset).recovery_evidence
    assert ObjectMutation.get(journal.id).attempts == at_limit.attempts
  end

  @tag :task3_red_core
  test "task3 control: repo telemetry capture yields the exact SET columns of a known update" do
    journal = claimed_journal!(%{object_key: "path/to/telemetry.bin"})

    {result, queries} =
      capture_repo_queries(fn ->
        ObjectMutation.mark_error(journal, :restore_failed, %{"stage" => "restore"}, now: @now)
      end)

    assert {:ok, _updated} = result

    # 既有 mark_error/4 会写 recovery_evidence：证明 §7 的 SET 列取证机制本身可用且精确。
    assert update_set_columns!(queries) == [
             "attempts",
             "last_error",
             "next_attempt_at",
             "recovery_evidence",
             "updated_at"
           ]
  end

  @tag :task3_red_core
  test "task3 control: metadata_committed still forbids the raw rollback transition" do
    journal = published_journal!()
    {:ok, committed} = ObjectMutation.transition(journal, "metadata_committed", %{}, now: @now)

    # 低层 transition/4 保留旧的 illegal_transition 结果；attrs-map API 的精确结果
    # 由上面的 §3 RED 单独冻结。
    assert ObjectMutation.transition(committed, "rollback_pending", %{}, now: @now) ==
             {:error, {:illegal_transition, "metadata_committed", "rollback_pending"}}
  end

  # --- Task 3 G1-FIX-R：G1 review 三路复审认定的契约缺陷 RED ---
  #
  # 冻结契约（task-3-g1-review-fix.md）四条非协商架构：
  #   1. 校验先于保留与 replay 裁决；与持久化 term 相等**绝不是**校验旁路；
  #   2. 保留是严格 term 保留（`===`/`!==`，`3` 与 `3.0` 是冲突），JSON 字节必须精确不变，
  #      published 行的非 nil fingerprint 不能被 `published_fingerprint: nil` 清空；
  #   3. 初始 nil-fingerprint proof 创建是**唯一一个原子三元组**：三个 key 必须齐备，
  #      fingerprint 恰为 nil，evidence 是 phase-valid canonical wrapper，last_error 必须与
  #      该 wrapper 的 outcome 精确对应（fenced 聚合禁止）；
  #   4. CAS 输家绝不能把未持久化的变更报告为成功。
  #   5. 运维错误 API 只接受稳定 binary reason。

  @g1r_stable_unavailable "published_proof_failed:proof:unavailable"
  @g1r_stable_corrupt "published_proof_failed:proof:corrupt"
  @g1r_stable_superseded "published_proof_superseded:proof"

  # --- G1-FIX-R fixtures ---

  defp g1r_proof_failure_wrapper!(class) do
    {:error, {:published_proof_failed, ^class, failure}} =
      Maxio.Storage.PublishedProof.classify(1, [
        {"local", Maxio.Storage.PublishedProof.failed(class, "local", %{owned: true})}
      ])

    {:ok, wrapper} =
      Maxio.Storage.PublishedProof.journal_evidence("rollback_pending", nil, failure)

    wrapper
  end

  defp g1r_superseded_wrapper!() do
    {:ok, {:superseded, summary}} =
      Maxio.Storage.PublishedProof.classify(1, [
        {"local", Maxio.Storage.PublishedProof.superseded("local")}
      ])

    {:ok, wrapper} =
      Maxio.Storage.PublishedProof.journal_evidence("rollback_pending", nil, summary)

    wrapper
  end

  # finalize-mode canonical wrapper：在 finalize_pending 合法，在 rollback_pending 非法。
  defp g1r_finalize_wrapper!() do
    {:ok, {:verified, proof}} =
      Maxio.Storage.PublishedProof.classify(1, [
        {"local", Maxio.Storage.PublishedProof.verified("local", %{})}
      ])

    {:ok, {:cleanup_pending, cleanup}} =
      Maxio.Storage.PublishedProof.classify_finalize(1, [
        {"ordinal:0", Maxio.Storage.PublishedProof.endpoint_finalized("ordinal:0", %{})},
        {"ordinal:1", Maxio.Storage.PublishedProof.endpoint_cleanup_pending("ordinal:1", %{})}
      ])

    {:ok, wrapper} =
      Maxio.Storage.PublishedProof.journal_evidence("finalize_pending", proof, cleanup)

    wrapper
  end

  # 按 `byte_size(Jason.encode!/1)` 精确校准的**语义合法** canonical verified wrapper。
  defp g1r_canonical_wrapper_of_bytes!(total) do
    probe = %{"published_proof" => g1r_verified_proof(1, 1), "last_failure" => nil}
    overhead = byte_size(Jason.encode!(probe)) - 3
    remaining = total - overhead

    {required_digits, verified_digits} =
      if rem(remaining, 2) == 1,
        do: {1, div(remaining - 1, 2)},
        else: {2, div(remaining - 2, 2)}

    wrapper = %{
      "published_proof" =>
        g1r_verified_proof(
          Integer.pow(10, required_digits - 1),
          Integer.pow(10, verified_digits - 1)
        ),
      "last_failure" => nil
    }

    assert byte_size(Jason.encode!(wrapper)) == total
    wrapper
  end

  defp g1r_verified_proof(required, verified) do
    %{
      "scope" => "aggregate",
      "mode" => "proof",
      "status" => "verified",
      "required" => required,
      "verified" => verified,
      "observed_owned" => verified,
      "unavailable" => 0,
      "degraded" => [],
      "omitted" => 0,
      "debt" => 0
    }
  end

  # 结构相等（`==`）会把 3 与 3.0 视为同一；取证保真必须比较编码字节。
  defp g1r_json_snapshot!(id) do
    row = ObjectMutation.get(id)

    %{
      fingerprint: row.published_fingerprint && Jason.encode!(row.published_fingerprint),
      evidence: row.recovery_evidence && Jason.encode!(row.recovery_evidence),
      last_error: row.last_error,
      phase: row.phase,
      attempts: row.attempts
    }
  end

  defp assert_g1r_json_unchanged!(id, snapshot), do: assert(g1r_json_snapshot!(id) == snapshot)

  # --- G1-FIX-R2：完整行严格 `===` 快照 + Repo telemetry 零写入/单次写入 oracle ---
  #
  # 「调用后值相同」不是零写入证明（同值 UPDATE 一样会执行 SQL），因此所有 pre-SQL 拒绝
  # 一律用 Repo telemetry 统计 `object_mutations` 的 UPDATE 语句条数。完整行比较必须用
  # `===`：结构相等会把 `3` 与 `3.0` 视为同一，正是本轮要证伪的漂移。

  defp strict_row_snapshot!(id) do
    id |> ObjectMutation.get() |> Map.from_struct() |> Map.delete(:__meta__)
  end

  defp assert_row_identical!(id, snapshot) do
    assert strict_row_snapshot!(id) === snapshot
  end

  defp object_mutation_updates(queries) do
    Enum.filter(queries, fn query ->
      String.starts_with?(query, "UPDATE") and String.contains?(query, "object_mutations")
    end)
  end

  defp assert_zero_object_mutation_updates!(queries) do
    assert object_mutation_updates(queries) == [],
           "该路径必须在 SQL 之前拒绝：不得出现任何 object_mutations UPDATE"
  end

  defp assert_one_object_mutation_update!(queries) do
    assert length(object_mutation_updates(queries)) == 1,
           "真实 CAS 输家必须恰好尝试一次 object_mutations UPDATE：" <>
             inspect(object_mutation_updates(queries))
  end

  # 完整 pre-SQL 零写入取证：精确公共结果 + 零 UPDATE + 完整行严格 `===` + 精确编码字节。
  defp assert_pre_sql_rejection!(journal, expected, fun) do
    id = journal.id
    strict = strict_row_snapshot!(id)
    json = g1r_json_snapshot!(id)

    {result, queries} = capture_repo_queries(fun)

    assert result == expected
    assert_zero_object_mutation_updates!(queries)
    assert_row_identical!(id, strict)
    assert_g1r_json_unchanged!(id, json)
    result
  end

  defp seed_fingerprint!(journal, fingerprint) do
    {1, _} =
      Repo.update_all(
        from(j in Maxio.ObjectMutation.Journal, where: j.id == ^journal.id),
        set: [published_fingerprint: fingerprint]
      )

    ObjectMutation.get(journal.id)
  end

  # 直接播种 phase 时必须同时满足 DB 的 phase/timestamp check constraint。
  defp seed_phase!(journal, phase) do
    {1, _} =
      Repo.update_all(
        from(j in Maxio.ObjectMutation.Journal, where: j.id == ^journal.id),
        set: [{:phase, phase} | g1r_phase_timestamp(phase)]
      )

    ObjectMutation.get(journal.id)
  end

  defp g1r_phase_timestamp("metadata_committed"), do: [metadata_committed_at: @now]
  defp g1r_phase_timestamp("finalized"), do: [finalized_at: @now]
  defp g1r_phase_timestamp("rolled_back"), do: [rolled_back_at: @now]
  defp g1r_phase_timestamp("quarantined"), do: [quarantined_at: @now]
  defp g1r_phase_timestamp(_phase), do: []

  # --- 契约 2：published 行的非 nil fingerprint 不可被 nil 清空 ---

  @tag :task3_g1_review_red
  test "g1 review red: a published row rejects a supplied nil fingerprint and keeps its own" do
    published = published_journal!(%{object_key: "g1r/nil-clear.bin"})
    refute is_nil(published.published_fingerprint)

    assert_pre_sql_rejection!(published, {:error, :invalid_rollback_evidence}, fn ->
      ObjectMutation.request_rollback(
        published,
        %{published_fingerprint: nil, recovery_evidence: published.recovery_evidence},
        now: @now
      )
    end)

    refute is_nil(ObjectMutation.get(published.id).published_fingerprint)
  end

  # --- 契约 2：整数/浮点漂移是冲突，且绝不能改写持久化 JSON ---

  @tag :task3_g1_review_red
  test "g1 review red: fingerprint integer/float drift is rejected and cannot rewrite persisted JSON" do
    published = published_journal!(%{object_key: "g1r/fp-float.bin"})
    drifted = %{fingerprint() | "size" => 3.0}

    # 结构比较视二者相同，正是缺陷所在：严格保留必须按 `===` 判为冲突。
    assert drifted == published.published_fingerprint
    refute drifted === published.published_fingerprint
    refute Jason.encode!(drifted) == Jason.encode!(published.published_fingerprint)

    assert_pre_sql_rejection!(published, {:error, :invalid_rollback_evidence}, fn ->
      ObjectMutation.request_rollback(
        published,
        %{published_fingerprint: drifted, recovery_evidence: published.recovery_evidence},
        now: @now
      )
    end)
  end

  @tag :task3_g1_review_red
  test "g1 review red: generic evidence integer/float drift is rejected and cannot rewrite persisted JSON" do
    observed = %{"authority_mode" => "pg", "stage" => "restore", "attempt" => 1}

    journal =
      claimed_journal!(%{object_key: "g1r/ev-float.bin"})
      |> seed_recovery_evidence!(observed)

    drifted = %{observed | "attempt" => 1.0}

    assert drifted == journal.recovery_evidence
    refute drifted === journal.recovery_evidence
    refute Jason.encode!(drifted) == Jason.encode!(journal.recovery_evidence)

    # 整数/浮点漂移绝不能通过 replay/preservation 比较，也绝不能改写持久化 JSON 字节。
    assert_pre_sql_rejection!(journal, {:error, :invalid_rollback_evidence}, fn ->
      ObjectMutation.request_rollback(
        journal,
        %{recovery_evidence: drifted, last_error: @restore_error},
        now: @now
      )
    end)
  end

  # --- 契约 4：CAS 输家绝不能报告未持久化的变更 ---

  @tag :task3_g1_review_red
  test "g1 review red: the differing-evidence rollback loser loses exactly on recovery_evidence" do
    observed = claimed_journal!(%{object_key: "g1r/race.bin"})
    winner_evidence = g1r_proof_failure_wrapper!(:unavailable)

    assert {:ok, winner} =
             ObjectMutation.request_rollback(
               observed,
               %{
                 published_fingerprint: nil,
                 recovery_evidence: winner_evidence,
                 last_error: @g1r_stable_unavailable
               },
               now: @now
             )

    assert winner.recovery_evidence == winner_evidence
    strict = strict_row_snapshot!(observed.id)
    json = g1r_json_snapshot!(observed.id)

    # 第二个调用方持同一份旧 claimed 快照，但提交完全不同的 evidence：这是真实 CAS 输家，
    # 不是 pre-SQL 拒绝，因此必须恰好尝试一次 UPDATE，并精确返回 evidence 冲突。
    {loser, queries} =
      capture_repo_queries(fn ->
        ObjectMutation.request_rollback(
          observed,
          %{
            published_fingerprint: nil,
            recovery_evidence: @contract_violation_evidence,
            last_error: @contract_violation_error
          },
          now: @now
        )
      end)

    assert loser == {:error, {:rollback_evidence_conflict, :recovery_evidence}}
    assert_one_object_mutation_update!(queries)

    # winner 的完整行与取证字节保持权威。
    assert_row_identical!(observed.id, strict)
    assert_g1r_json_unchanged!(observed.id, json)
    assert ObjectMutation.get(observed.id).recovery_evidence == winner_evidence
  end

  @g1r_winner_last_error "object_mutation:restore_failed"
  @g1r_loser_last_error "object_mutation:object_locked"

  @tag :task3_g1_review_red
  test "g1 review red: the last-error-only rollback loser loses exactly on last_error" do
    observed = claimed_journal!(%{object_key: "g1r/race-last-error.bin"})

    # 两个 binary 必须**各自独立合法**：last-error-only 的 attrs 不供应 fingerprint 与
    # evidence，因此不涉及任何 outcome/stable-code 对应关系，冻结的稳定映射矩阵不受影响。
    # `task3_red_core` 的「supplied last_error binaries are normalized once and stored
    # verbatim」已经证明 claimed journal + `%{last_error: binary}` 是活的合法路径。
    assert is_binary(@g1r_winner_last_error)
    assert is_binary(@g1r_loser_last_error)
    refute @g1r_winner_last_error == @g1r_loser_last_error

    assert {:ok, winner} =
             ObjectMutation.request_rollback(
               observed,
               %{last_error: @g1r_winner_last_error},
               now: @now
             )

    assert winner.phase == "rollback_pending"
    assert winner.last_error == @g1r_winner_last_error

    strict = strict_row_snapshot!(observed.id)
    json = g1r_json_snapshot!(observed.id)

    # 第二个调用方持**同一份旧 claimed 快照**，同样只供应一个各自合法的 binary
    # last_error。fingerprint 与 evidence 都未供应，因此二者在 replay 比较中逐字一致，
    # 唯一差异落在 last_error：这是真实 CAS 输家，不是 pre-SQL 拒绝，冲突字段必须精确
    # 落在 :last_error，绝不能被当成幂等成功。
    {loser, queries} =
      capture_repo_queries(fn ->
        ObjectMutation.request_rollback(
          observed,
          %{last_error: @g1r_loser_last_error},
          now: @now
        )
      end)

    assert loser == {:error, {:rollback_evidence_conflict, :last_error}}
    assert_one_object_mutation_update!(queries)

    # winner 的完整行与取证字节保持权威。
    assert_row_identical!(observed.id, strict)
    assert_g1r_json_unchanged!(observed.id, json)
    assert ObjectMutation.get(observed.id).last_error == @g1r_winner_last_error
  end

  @tag :task3_g1_review_red
  test "g1 review red: the different-reason quarantine loser returns the exact stale journal result" do
    observed = finalize_pending_journal!(%{object_key: "g1r/quar-race.bin"})

    assert {:ok, winner} =
             ObjectMutation.quarantine_preserving_evidence(
               observed,
               "published_proof_invalid:durable",
               now: @now
             )

    assert winner.last_error == "published_proof_invalid:durable"
    assert winner.phase == "quarantined"
    strict = strict_row_snapshot!(observed.id)
    json = g1r_json_snapshot!(observed.id)

    # 不同 reason 的竞争者是真实 CAS 输家：恰好一次 UPDATE 尝试，随后 fresh-read 精确
    # 判定为 stale，绝不允许走 generic terminal 幂等成功。
    {loser, queries} =
      capture_repo_queries(fn ->
        ObjectMutation.quarantine_preserving_evidence(
          observed,
          "published_proof_contract_violation:finalize",
          now: @now
        )
      end)

    assert loser == {:error, {:stale_journal, "quarantined", winner.attempts}}
    assert_one_object_mutation_update!(queries)
    assert_row_identical!(observed.id, strict)
    assert_g1r_json_unchanged!(observed.id, json)
    assert ObjectMutation.get(observed.id).last_error == "published_proof_invalid:durable"
  end

  # --- 契约 3：初始 nil-fingerprint 创建是唯一的原子三元组 ---

  @tag :task3_g1_review_red
  test "g1 review red: the initial nil-fingerprint wrapper requires all three keys" do
    wrapper = g1r_proof_failure_wrapper!(:unavailable)

    complete = %{
      published_fingerprint: nil,
      recovery_evidence: wrapper,
      last_error: @g1r_stable_unavailable
    }

    for missing <- [:published_fingerprint, :recovery_evidence, :last_error] do
      journal = claimed_journal!(%{object_key: "g1r/missing-#{missing}.bin"})

      assert_pre_sql_rejection!(journal, {:error, :invalid_rollback_evidence}, fn ->
        ObjectMutation.request_rollback(journal, Map.delete(complete, missing), now: @now)
      end)
    end
  end

  # design D2 / plan Task 3 Step 2 冻结的 outcome → stable last_error 逐字映射。
  @g1r_stable_codes %{
    unavailable: "published_proof_failed:proof:unavailable",
    corrupt: "published_proof_failed:proof:corrupt",
    mismatch: "published_proof_failed:proof:mismatch",
    placement_drift: "published_proof_failed:proof:placement_drift",
    superseded: "published_proof_superseded:proof"
  }

  defp g1r_outcome_wrapper!(:superseded), do: g1r_superseded_wrapper!()
  defp g1r_outcome_wrapper!(class), do: g1r_proof_failure_wrapper!(class)

  @tag :task3_g1_review_red
  test "g1 review control: every frozen outcome/stable-code pair creates the atomic triple" do
    # 五个正控必须逐一成立，否则下面的否定矩阵无法隔离「code 必须精确对应」这一谓词。
    assert map_size(@g1r_stable_codes) == 5
    assert @g1r_stable_codes.unavailable == @g1r_stable_unavailable
    assert @g1r_stable_codes.corrupt == @g1r_stable_corrupt
    assert @g1r_stable_codes.superseded == @g1r_stable_superseded

    for {outcome, code} <- @g1r_stable_codes do
      wrapper = g1r_outcome_wrapper!(outcome)
      journal = claimed_journal!(%{object_key: "g1r/stable-#{outcome}.bin"})

      assert {:ok, rolled} =
               ObjectMutation.request_rollback(
                 journal,
                 %{
                   published_fingerprint: nil,
                   recovery_evidence: wrapper,
                   last_error: code
                 },
                 now: @now
               ),
             "冻结正控必须成立：#{outcome}"

      assert rolled.phase == "rollback_pending"
      assert is_nil(rolled.published_fingerprint)
      assert rolled.recovery_evidence === wrapper
      assert rolled.last_error == code
      assert Jason.encode!(rolled.recovery_evidence) == Jason.encode!(wrapper)
    end
  end

  @tag :task3_g1_review_red
  test "g1 review red: every outcome rejects a wrong or arbitrary stable code before SQL" do
    outcomes = Map.keys(@g1r_stable_codes)

    # 每个 outcome 都要有：全部其余四个 code 的 wrong-code 负控，外加一个任意 code 负控。
    negatives =
      for outcome <- outcomes,
          wrong <-
            Enum.map(outcomes -- [outcome], &Map.fetch!(@g1r_stable_codes, &1)) ++
              ["totally-arbitrary-code"] do
        {outcome, wrong}
      end

    assert length(negatives) == 25

    for {{outcome, wrong_code}, index} <- Enum.with_index(negatives) do
      wrapper = g1r_outcome_wrapper!(outcome)
      journal = claimed_journal!(%{object_key: "g1r/code-mismatch-#{index}.bin"})

      assert_pre_sql_rejection!(journal, {:error, :invalid_rollback_evidence}, fn ->
        ObjectMutation.request_rollback(
          journal,
          %{
            published_fingerprint: nil,
            recovery_evidence: wrapper,
            last_error: wrong_code
          },
          now: @now
        )
      end)
    end
  end

  # --- 契约 1：与持久化 term 相等绝不是校验旁路 ---

  @tag :task3_g1_review_red
  test "g1 review red: wrong-phase persisted equality does not bypass published-proof validation" do
    finalize_wrapper = g1r_finalize_wrapper!()

    # finalize-mode wrapper 在 rollback_pending 目标 phase 上非法，即使它已被持久化。
    assert Maxio.Storage.PublishedProof.validate_durable_evidence(
             "rollback_pending",
             finalize_wrapper
           ) == {:error, :invalid_proof_evidence}

    journal =
      published_journal!(%{object_key: "g1r/wrong-phase.bin"})
      |> seed_recovery_evidence!(finalize_wrapper)

    assert_pre_sql_rejection!(journal, {:error, :invalid_rollback_evidence}, fn ->
      ObjectMutation.request_rollback(
        journal,
        %{recovery_evidence: finalize_wrapper},
        now: @now
      )
    end)
  end

  @tag :task3_g1_review_red
  test "g1 review red: an exact generic shape persisted in a forbidden phase is rejected on term-identical replay" do
    # 精确允许的 PG contract-violation generic 形态本身合法，但它在 `published` 这个 phase
    # 上的 domain 是被禁止的：把它直接播种进 published 行，再连同已归一化的伴随字段逐字
    # 重新提交，必须仍在 SQL 之前得到同一个精确拒绝。
    journal =
      published_journal!(%{object_key: "g1r/generic-wrong-phase.bin"})
      |> seed_recovery_evidence!(@contract_violation_evidence)

    assert journal.phase == "published"
    assert journal.recovery_evidence === @contract_violation_evidence
    refute is_nil(journal.published_fingerprint)

    assert_pre_sql_rejection!(journal, {:error, :invalid_rollback_evidence}, fn ->
      ObjectMutation.request_rollback(
        journal,
        %{
          published_fingerprint: journal.published_fingerprint,
          recovery_evidence: @contract_violation_evidence,
          last_error: @contract_violation_error
        },
        now: @now
      )
    end)
  end

  # 【G1-FIX-R2 修订】旧版这里记录的「61,441-byte canonical evidence 客观不可构造」阻塞
  # 结论已被批准的 durable-JSON adjudication 取代。正确的 oracle 不要求数据库真的装载过一个
  # 61,441-byte term（那确实不可能：任何超过 1,024 位十进制的计数器写进 JSONB 后就再也解不
  # 回来），而是行使**真实的信任边界**：真实 PG 行持有 nil / 普通安全 evidence，只把调用方
  # 内存中的 observed struct 伪造成 61,441-byte huge-counter wrapper 并原样重新提交。
  # 校验必须发生在 equality 与 CAS 之前，因此这次调用绝不能越过 SQL 边界。见下方
  # `g1r2 red: the forged 61,441-byte observed wrapper is rejected before equality and CAS`。

  @tag :task3_g1_review_red
  test "g1 review red: 65,537-byte replay evidence is rejected in rollback_pending and rolled_back" do
    over_limit = generic_evidence_of_bytes!(65_537)

    for phase <- ~w(rollback_pending rolled_back) do
      journal =
        claimed_journal!(%{object_key: "g1r/replay-#{phase}.bin"})
        |> seed_recovery_evidence!(over_limit)
        |> seed_phase!(phase)

      assert journal.phase == phase
      assert byte_size(Jason.encode!(journal.recovery_evidence)) == 65_537

      # replay 路径同样必须先校验：与快照逐字相等不能豁免 65,536-byte Journal 门。
      assert_pre_sql_rejection!(journal, {:error, :invalid_rollback_evidence}, fn ->
        ObjectMutation.request_rollback(journal, %{recovery_evidence: over_limit}, now: @now)
      end)
    end
  end

  @tag :task3_g1_review_red
  test "g1 review red: a malformed fingerprint shape is rejected before SQL" do
    published = published_journal!(%{object_key: "g1r/fp-shape.bin"})

    malformed = [
      %{fingerprint() | "size" => 3.0},
      %{fingerprint() | "size" => -1},
      Map.delete(fingerprint(), "sidecar_sha256"),
      Map.put(fingerprint(), "extra", "x"),
      %{fingerprint() | "etag" => ""},
      "not-a-map"
    ]

    for shape <- malformed do
      assert_pre_sql_rejection!(published, {:error, :invalid_rollback_evidence}, fn ->
        ObjectMutation.request_rollback(
          published,
          %{published_fingerprint: shape, recovery_evidence: published.recovery_evidence},
          now: @now
        )
      end)
    end
  end

  # --- 契约 5：运维 API 只接受稳定 binary reason ---

  @tag :task3_g1_review_red
  test "g1 review red: mark_operational_error rejects every non-binary reason before SQL" do
    for {reason, index} <-
          Enum.with_index([
            :object_locked,
            {:published_proof_failed, :unavailable},
            42,
            nil,
            ["x"]
          ]) do
      row = forensic_operational_row!("g1r/nonbinary-op-#{index}.bin")

      # 故意错误类型的公共调用保留 apply/3 能力缝隙，避免类型检查器在编译期发出
      # incompatible-types 诊断（G1 review 契约第 6 条）。
      assert_pre_sql_rejection!(row, {:error, :invalid_operational_reason}, fn ->
        apply(ObjectMutation, :mark_operational_error, [row, reason, [now: @later]])
      end)
    end
  end

  @tag :task3_g1_review_red
  test "g1 review red: quarantine_preserving_evidence rejects every non-binary reason before SQL" do
    for {reason, index} <-
          Enum.with_index([
            :object_locked,
            {:published_proof_failed, :unavailable},
            42,
            nil,
            ["x"]
          ]) do
      row = forensic_operational_row!("g1r/nonbinary-quar-#{index}.bin")

      assert_pre_sql_rejection!(row, {:error, :invalid_operational_reason}, fn ->
        apply(ObjectMutation, :quarantine_preserving_evidence, [row, reason, [now: @later]])
      end)
    end
  end

  # --- passing controls：fixtures 与精确 replay 路径必须是活的 ---

  @tag :task3_g1_review_red
  test "g1 review control: canonical wrapper and byte-calibrated fixtures are live" do
    for class <- [:unavailable, :corrupt, :mismatch, :placement_drift] do
      wrapper = g1r_proof_failure_wrapper!(class)
      assert is_nil(wrapper["published_proof"])

      assert Maxio.Storage.PublishedProof.validate_durable_evidence("rollback_pending", wrapper) ==
               :ok
    end

    superseded = g1r_superseded_wrapper!()
    assert superseded["last_failure"]["status"] == "superseded"

    assert Maxio.Storage.PublishedProof.validate_durable_evidence(
             "rollback_pending",
             superseded
           ) == :ok

    finalize_wrapper = g1r_finalize_wrapper!()

    assert Maxio.Storage.PublishedProof.validate_durable_evidence(
             "finalize_pending",
             finalize_wrapper
           ) == :ok

    # 【G1-FIX-R2 修订】exact-61,440 huge-counter wrapper 不再是 durable positive：它的
    # 计数器十进制 token 远超 1,024 bytes，Jason 解不回来，因此 61,440 与 61,441 都只是
    # 拒绝 oracle。尺寸谓词由 `test/maxio/durable_json_test.exs` 用 codec-roundtrippable
    # 字符串 payload 独立隔离。
    assert byte_size(Jason.encode!(g1r_canonical_wrapper_of_bytes!(61_440))) == 61_440
    assert byte_size(Jason.encode!(g1r_canonical_wrapper_of_bytes!(61_441))) == 61_441
  end

  @tag :task3_g1_review_red
  test "g1 review control: the exact atomic triple and exact replay still succeed" do
    wrapper = g1r_proof_failure_wrapper!(:unavailable)

    complete = %{
      published_fingerprint: nil,
      recovery_evidence: wrapper,
      last_error: @g1r_stable_unavailable
    }

    journal = claimed_journal!(%{object_key: "g1r/happy.bin"})

    assert {:ok, rolled} = ObjectMutation.request_rollback(journal, complete, now: @now)
    assert rolled.phase == "rollback_pending"
    assert rolled.recovery_evidence == wrapper
    assert Jason.encode!(rolled.recovery_evidence) == Jason.encode!(wrapper)
    assert rolled.last_error == @g1r_stable_unavailable
    assert is_nil(rolled.published_fingerprint)

    snapshot = g1r_json_snapshot!(journal.id)

    # 逐字相同的 replay 仍然成功且零写入。
    assert {:ok, replayed} = ObjectMutation.request_rollback(rolled, complete, now: @now)
    assert replayed.phase == "rollback_pending"
    assert_g1r_json_unchanged!(journal.id, snapshot)

    # binary reason 的运维更新与隔离仍然成功。
    operational = finalize_pending_journal!(%{object_key: "g1r/binary-ok.bin"})
    evidence_bytes = Jason.encode!(operational.recovery_evidence)

    assert {:ok, marked} =
             ObjectMutation.mark_operational_error(
               operational,
               "object_mutation:object_locked",
               now: @now,
               backoff_ms: 0
             )

    assert marked.last_error == "object_mutation:object_locked"
    assert Jason.encode!(marked.recovery_evidence) == evidence_bytes

    assert {:ok, quarantined} =
             ObjectMutation.quarantine_preserving_evidence(
               marked,
               "published_proof_invalid:durable",
               now: @now
             )

    assert quarantined.phase == "quarantined"
    assert Jason.encode!(quarantined.recovery_evidence) == evidence_bytes
  end

  @tag :task3_g1_review_red
  test "g1 review control: direct seeding of phase and fingerprint is live" do
    journal = claimed_journal!(%{object_key: "g1r/seed.bin"})
    seeded = seed_phase!(journal, "rolled_back")
    assert seeded.phase == "rolled_back"

    fingerprinted = seed_fingerprint!(seeded, fingerprint())
    assert fingerprinted.published_fingerprint == fingerprint()
    assert Jason.encode!(fingerprinted.published_fingerprint) == Jason.encode!(fingerprint())
  end

  # --- Task 3 / G1-FIX-R2：clean intended-canonical wrapper 的真实 JSONB 往返 ---
  #
  # adjudication 要求「至少一次真实 transaction-scoped JSONB insert/read」，且该 wrapper 必须
  # 是 clean intended-canonical 形态、省略每一个已知 over-permissive detail 字段。下面是
  # handoff 的确定性配方，在本文件中**独立重建**（不跨测试文件复用 fixture）。

  defp g1r2_huge_token_integer, do: Integer.pow(10, 1_023)

  defp g1r2_detail_identity(index) do
    "ordinal:" <>
      String.duplicate("9", 118) <> String.pad_leading(Integer.to_string(index), 2, "0")
  end

  defp g1r2_clean_degraded_proof do
    n = g1r2_huge_token_integer()

    %{
      "scope" => "aggregate",
      "mode" => "proof",
      "status" => "degraded",
      "required" => n,
      "verified" => n,
      "observed_owned" => n,
      "unavailable" => n,
      "degraded" => [],
      "omitted" => n,
      "debt" => n
    }
  end

  defp g1r2_clean_finalize_failure do
    n = g1r2_huge_token_integer()
    label = String.duplicate("a", 128)

    details =
      for index <- 1..32 do
        identity = g1r2_detail_identity(index)
        assert byte_size(identity) == 128

        {:error, {:published_proof_failed, :unavailable, summary}} =
          Maxio.Storage.PublishedProof.endpoint_finalize_failed(:unavailable, identity, %{
            owned: false,
            code: label,
            layout: label,
            phase: label
          })

        # clean 形态：不含 orphan_reason，也不 owned——即不含任何已知 over-permissive 字段。
        refute Map.has_key?(summary, "orphan_reason")
        assert summary["owned"] == false
        summary
      end

    %{
      "scope" => "aggregate",
      "mode" => "finalize",
      "status" => "failed",
      "class" => "unavailable",
      "required" => n + 1,
      "verified" => n,
      "finalized" => n,
      "observed_owned" => n,
      "unavailable" => n,
      "omitted" => n,
      "debt" => n + 32,
      "orphaned" => n,
      "orphan_omitted" => n,
      "orphan_hints" => [],
      "degraded" => details
    }
  end

  defp g1r2_clean_large_wrapper! do
    {:ok, wrapper} =
      Maxio.Storage.PublishedProof.journal_evidence(
        "finalize_pending",
        g1r2_clean_degraded_proof(),
        g1r2_clean_finalize_failure()
      )

    wrapper
  end

  @tag :task3_g1_review_red
  test "g1r2 control: the clean large wrapper passes public validation and a real JSONB round trip" do
    wrapper = g1r2_clean_large_wrapper!()
    encoded = Jason.encode!(wrapper)

    # 实测尺寸：严格大于 32 KiB 且不超过 60 KiB。
    assert byte_size(encoded) > 32 * 1024
    assert byte_size(encoded) <= 60 * 1024

    assert Maxio.Storage.PublishedProof.validate_durable_evidence("finalize_pending", wrapper) ==
             :ok

    assert Jason.decode!(encoded) === wrapper

    journal = finalize_pending_journal!(%{object_key: "g1r2/clean-large.bin"})

    # 真实 transaction-scoped JSONB insert/read：同一事务内写入并回读整行。
    {:ok, reloaded} =
      Repo.transaction(fn ->
        {1, _} =
          Repo.update_all(
            from(j in Maxio.ObjectMutation.Journal, where: j.id == ^journal.id),
            set: [recovery_evidence: wrapper]
          )

        Repo.get!(Maxio.ObjectMutation.Journal, journal.id)
      end)

    # 从 PostgreSQL JSONB 装载回来的 term 必须严格 `===` 相等，编码字节也必须逐字不变。
    assert reloaded.recovery_evidence === wrapper
    assert Jason.encode!(reloaded.recovery_evidence) == encoded

    # 事务外再读一次，证明不是事务内缓存。
    persisted = ObjectMutation.get(journal.id)
    assert persisted.recovery_evidence === wrapper
    assert Jason.encode!(persisted.recovery_evidence) == encoded

    # 这不是穷尽的最大值声明：60 KiB 仍是 absolute defense，不宣称可达 exact positive endpoint。
    refute byte_size(encoded) == 60 * 1024
  end

  # --- Task 3 / G1-FIX-R2：Journal 公共边界的 U+0000 拒绝（绝不提交给真实 JSONB）---

  @tag :task3_g1_review_red
  test "g1 review red: the Journal changeset and JSON predicate reject a U+0000 map key" do
    journal = claimed_journal!(%{object_key: "g1r2/nul-key.bin"})
    evidence = %{("nul" <> <<0>> <> "key") => "v"}

    # Jason 能编解码它，PostgreSQL JSONB 不能（SQLSTATE 22P05）：因此 codec 往返
    # 不足以定义 JSONB-safe domain，公共边界必须在 SQL 之前拒绝。
    assert match?({:ok, _bytes}, Jason.encode(evidence))

    refute Maxio.ObjectMutation.Journal.json_evidence_valid?(evidence)

    changeset =
      Maxio.ObjectMutation.Journal.changeset(journal, %{recovery_evidence: evidence})

    refute changeset.valid?
    assert errors_on(changeset).recovery_evidence
  end

  @tag :task3_g1_review_red
  test "g1 review red: the Journal changeset and JSON predicate reject a U+0000 binary value" do
    journal = claimed_journal!(%{object_key: "g1r2/nul-value.bin"})
    evidence = %{"k" => "nul" <> <<0>> <> "value"}

    assert match?({:ok, _bytes}, Jason.encode(evidence))

    refute Maxio.ObjectMutation.Journal.json_evidence_valid?(evidence)

    changeset =
      Maxio.ObjectMutation.Journal.changeset(journal, %{recovery_evidence: evidence})

    refute changeset.valid?
    assert errors_on(changeset).recovery_evidence
  end

  # --- Task 3 / G1-FIX-R2：validation 必须先于 equality 与 CAS（tests-only rejecting repo）---
  #
  # 真实 PG `prepared` 行的 evidence 为 nil；只把调用方内存中的 observed struct 伪造成
  # 非 durable term 并原样重新提交。旧行为下 `evidence == journal.recovery_evidence` 会把
  # 校验短路掉并直冲 CAS，于是 rejecting repo 收到 call message 并抛出 sentinel；冻结契约下
  # 必须在 SQL 之前返回精确的 `{:error, :invalid_rollback_evidence}`，信箱里不会有任何消息。

  @rejecting_repo Maxio.Test.RejectingObjectMutationRepo

  defp assert_forged_observed_rejected_before_sql!(journal, forged_evidence) do
    forged = %{journal | recovery_evidence: forged_evidence}

    before_row = Repo.get!(Maxio.ObjectMutation.Journal, journal.id)
    assert is_nil(before_row.recovery_evidence)

    {result, queries} =
      capture_repo_queries(fn ->
        ObjectMutation.request_rollback(
          forged,
          %{recovery_evidence: forged_evidence},
          now: @now,
          repo: @rejecting_repo
        )
      end)

    # 1) 精确公共结果。
    assert result == {:error, :invalid_rollback_evidence}

    # 2) 绝不越过 SQL 边界：rejecting repo 的固定 call message 一条都不能收到。
    assert @rejecting_repo.message_tag() == :rejecting_object_mutation_repo
    refute_received {:rejecting_object_mutation_repo, _callback}

    # 3) 真实 Repo 上零 object_mutations UPDATE。
    assert_zero_object_mutation_updates!(queries)

    # 4) 真实行调用前后都存在，且完整 term 严格 `===`。
    after_row = Repo.get!(Maxio.ObjectMutation.Journal, journal.id)

    assert Map.delete(Map.from_struct(after_row), :__meta__) ===
             Map.delete(Map.from_struct(before_row), :__meta__)

    # 5) 持久化 evidence 明确不是被伪造的 term。
    refute after_row.recovery_evidence == forged_evidence
    assert is_nil(after_row.recovery_evidence)

    # 6) 精确编码取证字段不变。
    assert is_nil(after_row.published_fingerprint)
    assert after_row.last_error === before_row.last_error
    assert after_row.phase === "prepared"
  end

  @tag :task3_g1_review_red
  test "g1r2 red: the forged 61,441-byte observed wrapper is rejected before equality and CAS" do
    wrapper = g1r_canonical_wrapper_of_bytes!(61_441)
    assert byte_size(Jason.encode!(wrapper)) == 61_441

    # 该 term 低于 Journal 的 65,536-byte 上限，因此拒绝不可能来自 generic 尺寸门；
    # 它之所以非 durable，是因为计数器十进制 token 远超 1,024 bytes。
    assert byte_size(Jason.encode!(wrapper)) < 65_536
    assert byte_size(Integer.to_string(wrapper["published_proof"]["verified"])) > 1_024

    journal = prepared_journal!(%{object_key: "g1r2/forged-61441.bin"})
    assert journal.phase == "prepared"

    assert_forged_observed_rejected_before_sql!(journal, wrapper)
  end

  @tag :task3_g1_review_red
  test "g1r2 red: a forged U+0000 observed evidence term is rejected before equality and CAS" do
    forged = %{"authority_mode" => "pg", "stage" => "restore" <> <<0>> <> "nul"}
    assert match?({:ok, _bytes}, Jason.encode(forged))

    journal = prepared_journal!(%{object_key: "g1r2/forged-nul.bin"})
    assert journal.phase == "prepared"

    # U+0000 绝不提交给真实 JSONB：rejecting repo 保证本用例不产生任何 SQL。
    assert_forged_observed_rejected_before_sql!(journal, forged)
  end

  @tag :task3_g1_review_red
  test "g1r2 control: the rejecting repo seam is live and never reaches PostgreSQL" do
    journal = prepared_journal!(%{object_key: "g1r2/seam.bin"})

    # 直接调用 seam：证明 call message 与 sentinel 都是真的，因此上面的
    # `refute_received` 是有意义的零消息断言，而不是永远为真的空断言。
    assert_raise RuntimeError, @rejecting_repo.sentinel(), fn ->
      @rejecting_repo.update_all(Maxio.ObjectMutation.Journal, set: [attempts: 1])
    end

    assert_received {:rejecting_object_mutation_repo, :update_all}

    assert_raise RuntimeError, @rejecting_repo.sentinel(), fn ->
      @rejecting_repo.get(Maxio.ObjectMutation.Journal, journal.id)
    end

    assert_received {:rejecting_object_mutation_repo, :get}

    # 真实行未被触碰。
    assert ObjectMutation.get(journal.id).phase == "prepared"
  end

  # --- Task 3 / G1-FIX-G-R1：省略 attrs 时必须校验 effective JSON state ---
  #
  # 独立审查 I1-B：旧实现只校验 `attrs` 里**显式出现**的 key，因此 attrs 省略时，一个已观察
  # 到的畸形 / phase-invalid evidence 或 fingerprint 会被原样保留并随 phase 变更跨过 SQL。
  # 冻结契约（parent handoff §7.2）要求：任何会被 rollback phase 变更保留的 JSON term，
  # 都必须在 SQL 之前校验。
  #
  # 这些用例全部注入 tests-only rejecting repo：只要越过 SQL 边界就会收到固定 call message
  # 并被 sentinel 打断，因此「无 repo 调用」是可证伪的强断言，而不是空断言。

  defp assert_effective_state_rejected!(journal) do
    {result, queries} =
      capture_repo_queries(fn ->
        ObjectMutation.request_rollback(journal, %{}, now: @now, repo: @rejecting_repo)
      end)

    assert result == {:error, :invalid_rollback_evidence}
    refute_received {:rejecting_object_mutation_repo, _callback}
    assert_zero_object_mutation_updates!(queries)
  end

  @tag :task3_g1_green_review_correction
  test "g1 correction: omitted attrs cannot retain a malformed canonical-namespace evidence" do
    journal =
      claimed_journal!(%{object_key: "g1c/effective-malformed-wrapper.bin"})
      |> seed_recovery_evidence!(%{"published_proof" => "malformed"})

    assert journal.phase == "claimed"
    assert journal.recovery_evidence == %{"published_proof" => "malformed"}

    assert_effective_state_rejected!(journal)
  end

  @tag :task3_g1_green_review_correction
  test "g1 correction: omitted attrs cannot retain an observed non-nil malformed fingerprint" do
    # DB 的 `object_mutations_published_fingerprint_check` 只约束 published 及其后续 phase，
    # 因此畸形 fingerprint 只能在 requestable 的 `claimed` 行上取证——这同时证明拒绝来自
    # 应用层的 effective-state 校验，而不是数据库约束。
    malformed = [
      # durable 与语义双重非法：JSONB 会把它读回成 float。
      %{fingerprint() | "size" => 3.0},
      # durable 合法、语义非法：多一个 key。
      Map.put(fingerprint(), "extra", "x"),
      # durable 合法、语义非法：sidecar_sha256 形状错误。
      %{fingerprint() | "sidecar_sha256" => "short"}
    ]

    for {shape, index} <- Enum.with_index(malformed) do
      journal =
        claimed_journal!(%{object_key: "g1c/effective-malformed-fp-#{index}.bin"})
        |> seed_fingerprint!(shape)

      assert journal.phase == "claimed"
      refute is_nil(journal.published_fingerprint)

      assert_effective_state_rejected!(journal)
    end
  end

  @tag :task3_g1_green_review_correction
  test "g1 correction: a published row with omitted attrs requires its successful canonical wrapper" do
    # observed evidence 本身是 durable 的合法 generic term，但 `published` 这个 phase 的
    # evidence domain 只接受它自己的 phase-valid 成功 canonical wrapper。
    generic = %{"authority_mode" => "pg", "stage" => "restore"}

    journal =
      published_journal!(%{object_key: "g1c/effective-generic-published.bin"})
      |> seed_recovery_evidence!(generic)

    assert journal.phase == "published"
    assert Maxio.ObjectMutation.Journal.json_evidence_valid?(generic)

    assert_effective_state_rejected!(journal)
  end

  @tag :task3_g1_green_review_correction
  test "g1 correction: omitted attrs still succeed when the complete observed state is valid" do
    # 正控：合法 Commit caller 路径不得被这次修正误伤——published 行同时持有合法 fingerprint
    # 与合法成功 canonical wrapper 时，省略 attrs 的回滚请求必须照常恰好写一次。
    journal = published_journal!(%{object_key: "g1c/effective-valid.bin"})

    assert journal.published_fingerprint == fingerprint()
    assert journal.recovery_evidence == proof_wrapper!()

    {result, queries} =
      capture_repo_queries(fn ->
        ObjectMutation.request_rollback(journal, %{}, now: @now)
      end)

    assert {:ok, rolled} = result
    assert rolled.phase == "rollback_pending"
    assert rolled.published_fingerprint === fingerprint()
    assert rolled.recovery_evidence === proof_wrapper!()
    assert_one_object_mutation_update!(queries)
  end

  # --- Task 3 / G1-FIX-G-R2：source-phase / evidence-origin gate ---
  #
  # 独立复审 C0/I1/M0：R1 之后，durable/shape 合法性与 **source-phase / origin 合法性**
  # 仍是两件事，而 `not supplied? -> :ok` 与 `evidence === observed -> :ok` 发生在后者之前。
  # 因此一个结构完全合法的 term 仍能靠「省略」或「显式相等」取得 origin，从而越过 SQL：
  #
  #   A) published 行持有一个「对 rollback_pending 合法、但对 published 非法」的 canonical
  #      wrapper（nil-proof failure / superseded），attrs 省略或显式相等都会越过；
  #   B) ordinary prepared/claimed 行已经持有 rollback-domain canonical evidence——canonical
  #      来源非法，attrs 省略或显式相等都会越过；observed generic 的严格保留是合法正控。
  #
  # 两者是同一个根因的两种表现：origin 必须在 omission / equality / stable-code / replay /
  # CAS 之前独立成门。下面全部经 tests-only rejecting repo 取证：越过 SQL 边界就会收到固定
  # call message，因此「无 repo 调用」是可证伪的强断言。

  defp assert_r2_origin_rejected!(journal, attrs, label) do
    {result, queries} =
      capture_repo_queries(fn ->
        ObjectMutation.request_rollback(journal, attrs, now: @now, repo: @rejecting_repo)
      end)

    assert result == {:error, :invalid_rollback_evidence}, "source-phase/origin 必须拒绝：#{label}"
    refute_received {:rejecting_object_mutation_repo, _callback}
    assert_zero_object_mutation_updates!(queries)
  end

  @tag :task3_g1_green_review_correction_r2
  test "g1 r2: a published row rejects every published-invalid canonical wrapper it already holds" do
    wrappers = [
      {"nil-proof unavailable failure", g1r_proof_failure_wrapper!(:unavailable)},
      {"nil-proof corrupt failure", g1r_proof_failure_wrapper!(:corrupt)},
      {"nil-proof superseded", g1r_superseded_wrapper!()}
    ]

    for {{label, wrapper}, index} <- Enum.with_index(wrappers) do
      # 前置证明：该 wrapper 对 rollback 目标域合法，但对 source phase `published` 非法。
      assert Maxio.Storage.PublishedProof.validate_durable_evidence("rollback_pending", wrapper) ==
               :ok

      assert Maxio.Storage.PublishedProof.validate_durable_evidence("published", wrapper) ==
               {:error, :invalid_proof_evidence}

      journal =
        published_journal!(%{object_key: "g1r2/published-invalid-#{index}.bin"})
        |> seed_recovery_evidence!(wrapper)

      assert journal.phase == "published"
      refute is_nil(journal.published_fingerprint)
      assert journal.recovery_evidence === wrapper

      # 省略 attrs 与「显式供应且严格相等」必须得到同一个精确拒绝。
      assert_r2_origin_rejected!(journal, %{}, "#{label} / omitted")

      assert_r2_origin_rejected!(
        journal,
        %{recovery_evidence: wrapper},
        "#{label} / explicit equal"
      )

      assert_r2_origin_rejected!(
        journal,
        %{published_fingerprint: journal.published_fingerprint, recovery_evidence: wrapper},
        "#{label} / explicit equal with fingerprint"
      )
    end
  end

  # 【test-contract correction】本用例的早期版本把 ordinary prepared/claimed 上**已观察
  # generic evidence** 的保留也判为 invalid。那是一个协调设计缺陷：parent Green §7.2 明确
  # “requestable phases may only preserve a strictly `===` observed generic term”，而冻结的
  # `mark_error/4` 本来就会在 claimed 上写入合法 generic forensic evidence。架构再裁决后，
  # generic 保留是**正控**（见下一个用例），此处只保留真正的 canonical 负控。
  @tag :task3_g1_green_review_correction_r2
  test "g1 r2: ordinary prepared and claimed rows may never retain an observed canonical wrapper" do
    # proof 尚未通过，canonical 证据不可能合法地先于它存在：omission 与显式相等都不得
    # 为它建立 origin。唯一的 canonical 非 nil 入口是 observed nil + 完整显式原子三元组。
    wrappers = [
      {"rollback-domain nil-proof failure", g1r_proof_failure_wrapper!(:unavailable)},
      {"rollback-domain superseded", g1r_superseded_wrapper!()},
      {"successful published wrapper", proof_wrapper!()}
    ]

    sources = [
      {"prepared", &prepared_journal!/1},
      {"claimed", &claimed_journal!/1}
    ]

    for {{phase_label, factory}, phase_index} <- Enum.with_index(sources),
        {{label, wrapper}, index} <- Enum.with_index(wrappers) do
      journal =
        factory.(%{object_key: "g1r2/pre-proof-canonical-#{phase_index}-#{index}.bin"})
        |> seed_recovery_evidence!(wrapper)

      assert journal.phase == phase_label
      assert journal.recovery_evidence === wrapper
      assert is_nil(journal.published_fingerprint)

      assert_r2_origin_rejected!(journal, %{}, "#{phase_label} / #{label} / omitted")

      assert_r2_origin_rejected!(
        journal,
        %{recovery_evidence: wrapper},
        "#{phase_label} / #{label} / explicit equal"
      )
    end
  end

  @tag :task3_g1_green_review_correction_r2
  test "g1 r2 control: observed generic forensic evidence still crosses rollback on a pre-proof row" do
    # parent Green §7.2 的严格保留语义：已观察 generic term 在 Journal durable 校验后，
    # 省略与显式 `===` 供应都必须原样跨越 rollback；只有 fresh/replacement generic 被禁止。
    observed = %{"authority_mode" => "pg", "stage" => "restore", "outcome" => "failed"}
    encoded = Jason.encode!(observed)

    # 完整笛卡尔积：{prepared, claimed} × {省略 attrs, 显式严格相等}。
    sources = [
      {"prepared", &prepared_journal!/1},
      {"claimed", &claimed_journal!/1}
    ]

    modes = [
      {"omitted", %{}},
      {"explicit strict-equal", %{recovery_evidence: observed, last_error: @restore_error}}
    ]

    for {{phase_label, factory}, phase_index} <- Enum.with_index(sources),
        {{mode_label, attrs}, mode_index} <- Enum.with_index(modes) do
      row =
        factory.(%{object_key: "g1r2/generic-keep-#{phase_index}-#{mode_index}.bin"})
        |> seed_recovery_evidence!(observed)

      assert row.phase == phase_label
      assert row.recovery_evidence === observed

      {result, queries} =
        capture_repo_queries(fn -> ObjectMutation.request_rollback(row, attrs, now: @now) end)

      assert {:ok, kept} = result, "generic 保留必须成功：#{phase_label} / #{mode_label}"
      assert kept.phase == "rollback_pending"
      assert kept.recovery_evidence === observed
      assert Jason.encode!(kept.recovery_evidence) == encoded

      # 既有 CAS 行为不变：恰好一条 object_mutations UPDATE。
      assert_one_object_mutation_update!(queries)

      persisted = ObjectMutation.get(row.id)
      assert persisted.phase == "rollback_pending"
      assert persisted.recovery_evidence === observed
    end

    # fresh / replacement generic 仍必须被拒绝，且不越过 SQL。
    replacement_row =
      claimed_journal!(%{object_key: "g1r2/generic-replace.bin"})
      |> seed_recovery_evidence!(observed)

    assert_r2_origin_rejected!(
      replacement_row,
      %{recovery_evidence: %{observed | "outcome" => "conflict"}},
      "replacement generic"
    )

    assert_r2_origin_rejected!(
      claimed_journal!(%{object_key: "g1r2/generic-fresh.bin"}),
      %{recovery_evidence: %{"authority_mode" => "pg", "stage" => "invented"}},
      "fresh generic on nil-evidence row"
    )
  end

  # --- R2 正控：修正绝不能误伤任何一条合法路径 ---

  @tag :task3_g1_green_review_correction_r2
  test "g1 r2 control: a published row with its successful canonical wrapper still rolls back once" do
    journal = published_journal!(%{object_key: "g1r2/positive-published.bin"})

    assert journal.recovery_evidence === proof_wrapper!()
    assert journal.published_fingerprint === fingerprint()

    assert Maxio.Storage.PublishedProof.validate_durable_evidence(
             "published",
             journal.recovery_evidence
           ) == :ok

    {result, queries} =
      capture_repo_queries(fn ->
        ObjectMutation.request_rollback(journal, %{}, now: @now)
      end)

    assert {:ok, rolled} = result
    assert rolled.phase == "rollback_pending"
    assert rolled.recovery_evidence === proof_wrapper!()
    assert rolled.published_fingerprint === fingerprint()
    assert_one_object_mutation_update!(queries)
  end

  @tag :task3_g1_green_review_correction_r2
  test "g1 r2 control: the frozen claimed creation triples and nil-evidence path still succeed" do
    # 1) 初始 nil-proof 完整显式三元组。
    wrapper = g1r_proof_failure_wrapper!(:unavailable)

    assert {:ok, nil_proof_rolled} =
             ObjectMutation.request_rollback(
               claimed_journal!(%{object_key: "g1r2/positive-triple.bin"}),
               %{
                 published_fingerprint: nil,
                 recovery_evidence: wrapper,
                 last_error: @g1r_stable_unavailable
               },
               now: @now
             )

    assert nil_proof_rolled.phase == "rollback_pending"
    assert nil_proof_rolled.recovery_evidence === wrapper

    # 2) 两个 exact generic 完整显式三元组。
    generic_triples = [
      {@contract_violation_evidence, @contract_violation_error},
      {@journal_transition_evidence, @journal_transition_error}
    ]

    for {{evidence, code}, index} <- Enum.with_index(generic_triples) do
      assert {:ok, rolled} =
               ObjectMutation.request_rollback(
                 claimed_journal!(%{object_key: "g1r2/positive-generic-#{index}.bin"}),
                 %{
                   published_fingerprint: nil,
                   recovery_evidence: evidence,
                   last_error: code
                 },
                 now: @now
               )

      assert rolled.recovery_evidence === evidence
      assert rolled.last_error == code
    end

    # 3) effective evidence 为 nil 的 pre-proof 行：last-error-only 竞争依赖这条路径。
    assert {:ok, last_error_only} =
             ObjectMutation.request_rollback(
               claimed_journal!(%{object_key: "g1r2/positive-nil-evidence.bin"}),
               %{last_error: "object_mutation:restore_failed"},
               now: @now
             )

    assert last_error_only.phase == "rollback_pending"
    assert is_nil(last_error_only.recovery_evidence)
  end

  @tag :task3_g1_green_review_correction_r2
  test "g1 r2 control: rollback replay still validates then compares in the frozen order" do
    wrapper = g1r_proof_failure_wrapper!(:unavailable)

    complete = %{
      published_fingerprint: nil,
      recovery_evidence: wrapper,
      last_error: @g1r_stable_unavailable
    }

    {:ok, rolled} =
      ObjectMutation.request_rollback(
        claimed_journal!(%{object_key: "g1r2/positive-replay.bin"}),
        complete,
        now: @now
      )

    # 逐字相同的 replay 仍然零写入成功。
    {replayed, queries} =
      capture_repo_queries(fn -> ObjectMutation.request_rollback(rolled, complete, now: @now) end)

    assert {:ok, %{phase: "rollback_pending"}} = replayed
    assert_zero_object_mutation_updates!(queries)

    # 有序严格冲突不变。
    assert ObjectMutation.request_rollback(
             rolled,
             %{complete | last_error: "other"},
             now: @now
           ) == {:error, {:rollback_evidence_conflict, :last_error}}

    # generic rollback-domain term 的 replay 同样先校验再比较。
    generic = %{"authority_mode" => "pg", "stage" => "restore"}

    generic_row =
      claimed_journal!(%{object_key: "g1r2/positive-replay-generic.bin"})
      |> seed_recovery_evidence!(generic)
      |> seed_phase!("rollback_pending")

    assert {:ok, %{phase: "rollback_pending"}} =
             ObjectMutation.request_rollback(generic_row, %{recovery_evidence: generic},
               now: @now
             )
  end

  # --- BEGIN Task 3 / G1-FIX-G-R3 ---
  #
  # 独立复审 I1：effective-state 校验目前只校验**非 nil** fingerprint，然后就执行
  # `not supplied? -> :ok`，从未建立「PG `published` 在 attr 省略时必须有非 nil
  # fingerprint」这条 source-phase 不变量。于是一个 fingerprint 为 nil 的 published 行
  # （evidence 是对 `published` 与 `rollback_pending` 双域都合法的成功 canonical wrapper）
  # 会越过 SQL 边界。
  #
  # 该规则对「省略」「显式 nil」「含 nil fingerprint 的完整显式三元组」完全一致：claimed 行的
  # 原子创建例外是 phase-scoped 的，绝不能被 published 复用来授权 nil fingerprint。
  #
  # 全部经 tests-only rejecting repo 取证：越过 SQL 就会收到固定 call message。

  # DB 的 `object_mutations_published_fingerprint_check` 禁止 published 行持久化 nil
  # fingerprint，因此该状态只能作为**调用方内存中的 observed Journal value** 出现——这正是
  # 独立复审的复现形态（effective fingerprint 为 nil + attrs 省略）。整个用例经 rejecting
  # repo 取证，本来就不产生任何 SQL，因此不需要、也不允许把它写进数据库。
  defp r3_published_nil_fingerprint_row!(key) do
    journal = published_journal!(%{object_key: key})
    %{journal | published_fingerprint: nil}
  end

  defp assert_r3_rejected_before_sql!(journal, attrs, label) do
    {result, queries} =
      capture_repo_queries(fn ->
        ObjectMutation.request_rollback(journal, attrs, now: @now, repo: @rejecting_repo)
      end)

    assert result == {:error, :invalid_rollback_evidence},
           "published + effective nil fingerprint 必须 pre-SQL 拒绝：#{label}"

    refute_received {:rejecting_object_mutation_repo, _callback}
    assert_zero_object_mutation_updates!(queries)
  end

  @tag :task3_g1_green_review_correction_r3
  test "g1 r3: a published row with an effective nil fingerprint is rejected before any repo call" do
    journal = r3_published_nil_fingerprint_row!("g1r3/published-nil-fp.bin")

    # 前置条件：evidence 是对 source `published` 与 target `rollback_pending` 双域都合法的
    # 成功 canonical wrapper，因此拒绝只能来自 fingerprint 的 source-phase 不变量。
    assert journal.phase == "published"
    assert is_nil(journal.published_fingerprint)
    assert journal.recovery_evidence === proof_wrapper!()

    assert Maxio.Storage.PublishedProof.validate_durable_evidence(
             "published",
             journal.recovery_evidence
           ) == :ok

    assert Maxio.Storage.PublishedProof.validate_durable_evidence(
             "rollback_pending",
             journal.recovery_evidence
           ) == :ok

    cases = [
      {"omitted fingerprint", %{}},
      {"explicit nil fingerprint", %{published_fingerprint: nil}},
      {"complete explicit triple with nil fingerprint",
       %{
         published_fingerprint: nil,
         recovery_evidence: journal.recovery_evidence,
         last_error: @g1r_stable_unavailable
       }}
    ]

    for {label, attrs} <- cases do
      assert_r3_rejected_before_sql!(journal, attrs, label)
    end
  end

  # --- R3 正控：修正是 phase-scoped 的，不得误伤任何既有合法路径 ---

  @tag :task3_g1_green_review_correction_r3
  test "g1 r3 control: pre-proof rows with effective nil fingerprint still roll back" do
    sources = [
      {"prepared", &prepared_journal!/1},
      {"claimed", &claimed_journal!/1}
    ]

    for {{phase_label, factory}, index} <- Enum.with_index(sources) do
      row = factory.(%{object_key: "g1r3/pre-proof-nil-fp-#{index}.bin"})

      assert row.phase == phase_label
      assert is_nil(row.published_fingerprint)

      {result, queries} =
        capture_repo_queries(fn -> ObjectMutation.request_rollback(row, %{}, now: @now) end)

      assert {:ok, rolled} = result, "pre-proof nil fingerprint 必须仍然成功：#{phase_label}"
      assert rolled.phase == "rollback_pending"
      assert is_nil(rolled.published_fingerprint)
      assert_one_object_mutation_update!(queries)
    end
  end

  @tag :task3_g1_green_review_correction_r3
  test "g1 r3 control: claimed initial nil-proof triple and nil-fingerprint replay still succeed" do
    wrapper = g1r_proof_failure_wrapper!(:unavailable)

    complete = %{
      published_fingerprint: nil,
      recovery_evidence: wrapper,
      last_error: @g1r_stable_unavailable
    }

    # claimed 行的完整显式原子三元组（fingerprint 恰为 nil）仍然合法。
    assert {:ok, rolled} =
             ObjectMutation.request_rollback(
               claimed_journal!(%{object_key: "g1r3/claimed-triple.bin"}),
               complete,
               now: @now
             )

    assert rolled.phase == "rollback_pending"
    assert is_nil(rolled.published_fingerprint)
    assert rolled.recovery_evidence === wrapper

    # rollback 域对合法 nil fingerprint 的 replay 仍是零写入幂等。
    {replayed, queries} =
      capture_repo_queries(fn -> ObjectMutation.request_rollback(rolled, complete, now: @now) end)

    assert {:ok, %{phase: "rollback_pending"}} = replayed
    assert_zero_object_mutation_updates!(queries)

    # 显式 nil fingerprint 的 replay 同样成功且零写入。
    {nil_replayed, nil_queries} =
      capture_repo_queries(fn ->
        ObjectMutation.request_rollback(rolled, %{published_fingerprint: nil}, now: @now)
      end)

    assert {:ok, %{phase: "rollback_pending"}} = nil_replayed
    assert_zero_object_mutation_updates!(nil_queries)
  end

  @tag :task3_g1_green_review_correction_r3
  test "g1 r3 control: a published row with a valid three-key fingerprint still performs one update" do
    journal = published_journal!(%{object_key: "g1r3/published-valid-fp.bin"})

    assert journal.published_fingerprint === fingerprint()
    assert Maxio.ObjectMutation.Journal.fingerprint_valid?(journal.published_fingerprint)

    {result, queries} =
      capture_repo_queries(fn -> ObjectMutation.request_rollback(journal, %{}, now: @now) end)

    assert {:ok, rolled} = result
    assert rolled.phase == "rollback_pending"
    assert rolled.published_fingerprint === fingerprint()
    assert rolled.recovery_evidence === proof_wrapper!()
    assert_one_object_mutation_update!(queries)
  end

  # --- END Task 3 / G1-FIX-G-R3 ---

  # --- BEGIN Task 3 / G2 shared stable-error amendment (R2b) ---
  #
  # 冻结契约（amendment §3）：`ObjectMutation` 是唯一的 journal mutation/CAS 拥有者，
  # 其**唯一**的 reason 转换规则是
  #
  #   1. binary reason → grapheme-bounded binary，除既有 2,000-grapheme 截断外逐字保留；
  #   2. 一切非 binary reason → 既有 legacy `inspect/2` 渲染 + 同一次既有截断。
  #
  # 当前生产的 `error_text/1` 把**每一个** reason 都送进 `inspect/2`，因此像
  # `published_proof_failed:finalize:unavailable` 这样的稳定 code 会被加上引号持久化，
  # 违反冻结的稳定 code 契约。G2 Commit 与 G3 Recovery 都必须在同一次 journal CAS 里
  # 写入精确的稳定 code，且不得绕过 `ObjectMutation`、不得直写 Repo、不得事后剥引号，
  # 也不得改用 `mark_operational_error/3`（后者刻意不更新 recovery evidence）。
  #
  # 下面六个用例各自独立（每个用 fresh journal），因此任何一个断言都不会掩盖另一个入口
  # 或 bound oracle。全部只经公共 API，绝不直接调用私有 helper。本轮**不**添加生产
  # binary 子句。

  @shared_error_finalize_unavailable "published_proof_failed:finalize:unavailable"
  @shared_error_finalize_corrupt "published_proof_failed:finalize:corrupt"
  @shared_error_tuple {:published_proof_failed, :unavailable}

  # legacy 非 binary 渲染的既有实现：inspect(limit: 50, printable_limit: 2_000) + 单次截断。
  defp legacy_inspect_text(reason) do
    reason
    |> inspect(limit: 50, printable_limit: 2_000)
    |> String.slice(0, 2_000)
  end

  @tag :task3_g2_shared_error_red
  test "g2 shared error red: mark_error persists a short binary stable code verbatim" do
    journal = claimed_journal!(%{object_key: "g2se/mark-error-short.bin"})
    evidence = %{"authority_mode" => "pg", "stage" => "finalize"}

    assert {:ok, marked} =
             ObjectMutation.mark_error(journal, @shared_error_finalize_unavailable, evidence,
               now: @now,
               backoff_ms: 2_500
             )

    # 稳定 code 必须逐字持久化，绝不加引号。
    assert marked.last_error === @shared_error_finalize_unavailable
    refute marked.last_error == inspect(@shared_error_finalize_unavailable)
    refute String.contains?(marked.last_error, "\"")

    # 既有的 evidence / attempts / backoff 语义保持不变。
    assert marked.recovery_evidence == evidence
    assert marked.attempts == journal.attempts + 1
    assert marked.next_attempt_at == DateTime.add(@now, 2_500, :millisecond)
  end

  @tag :task3_g2_shared_error_red
  test "g2 shared error red: quarantine persists a short binary stable code verbatim" do
    journal = claimed_journal!(%{object_key: "g2se/quarantine-short.bin"})
    evidence = %{"authority_mode" => "pg", "stage" => "finalize"}

    assert {:ok, quarantined} =
             ObjectMutation.quarantine(journal, @shared_error_finalize_corrupt, evidence,
               now: @now
             )

    assert quarantined.last_error === @shared_error_finalize_corrupt
    refute quarantined.last_error == inspect(@shared_error_finalize_corrupt)
    refute String.contains?(quarantined.last_error, "\"")

    # 既有的 phase / evidence 语义保持不变。
    assert quarantined.phase == "quarantined"
    assert quarantined.quarantined_at == @now
    assert quarantined.recovery_evidence == evidence
  end

  @tag :task3_g2_shared_error_red
  test "g2 shared error red: mark_error bounds an overlong valid UTF-8 binary at 2,000 graphemes" do
    journal = claimed_journal!(%{object_key: "g2se/mark-error-long.bin"})
    reason = String.duplicate("界", 2_005)
    expected = String.slice(reason, 0, 2_000)
    evidence = %{"authority_mode" => "pg", "stage" => "finalize"}

    assert String.length(reason) == 2_005
    assert String.valid?(reason)

    assert {:ok, marked} =
             ObjectMutation.mark_error(journal, reason, evidence, now: @now, backoff_ms: 1_500)

    # 新的 binary 子句必须委派给既有 bounded_error/1，而不是直接返回无界 binary。
    assert marked.last_error === expected
    assert String.length(marked.last_error) == 2_000
    refute String.contains?(marked.last_error, "\"")
    refute String.contains?(marked.last_error, "...")

    assert marked.recovery_evidence == evidence
    assert marked.attempts == journal.attempts + 1
    assert marked.next_attempt_at == DateTime.add(@now, 1_500, :millisecond)
  end

  @tag :task3_g2_shared_error_red
  test "g2 shared error red: quarantine bounds an overlong valid UTF-8 binary at 2,000 graphemes" do
    journal = claimed_journal!(%{object_key: "g2se/quarantine-long.bin"})
    reason = String.duplicate("界", 2_005)
    expected = String.slice(reason, 0, 2_000)
    evidence = %{"authority_mode" => "pg", "stage" => "finalize"}

    assert {:ok, quarantined} =
             ObjectMutation.quarantine(journal, reason, evidence, now: @now)

    # 第二个公共入口独立冻结同一个 bound。
    assert quarantined.last_error === expected
    assert String.length(quarantined.last_error) == 2_000
    refute String.contains?(quarantined.last_error, "\"")
    refute String.contains?(quarantined.last_error, "...")

    assert quarantined.phase == "quarantined"
    assert is_nil(quarantined.lease_owner)
    assert is_nil(quarantined.lease_expires_at)
    assert quarantined.recovery_evidence == evidence
  end

  @tag :task3_g2_shared_error_red
  test "g2 shared error control: mark_error keeps the legacy inspect rendering for a tuple reason" do
    journal = claimed_journal!(%{object_key: "g2se/mark-error-tuple.bin"})
    evidence = %{"authority_mode" => "pg", "stage" => "restore"}

    assert {:ok, marked} =
             ObjectMutation.mark_error(journal, @shared_error_tuple, evidence, now: @now)

    # 非 binary 一律保持既有 legacy 渲染：不得被「统统转字符串」的改写波及。
    assert marked.last_error === legacy_inspect_text(@shared_error_tuple)
    assert marked.last_error == "{:published_proof_failed, :unavailable}"
    assert marked.recovery_evidence == evidence
  end

  @tag :task3_g2_shared_error_red
  test "g2 shared error control: quarantine keeps the legacy inspect rendering for a tuple reason" do
    journal = claimed_journal!(%{object_key: "g2se/quarantine-tuple.bin"})
    evidence = %{"authority_mode" => "pg", "stage" => "restore"}

    assert {:ok, quarantined} =
             ObjectMutation.quarantine(journal, @shared_error_tuple, evidence, now: @now)

    assert quarantined.last_error === legacy_inspect_text(@shared_error_tuple)
    assert quarantined.last_error == "{:published_proof_failed, :unavailable}"
    assert quarantined.phase == "quarantined"
    assert quarantined.recovery_evidence == evidence
  end

  # --- END Task 3 / G2 shared stable-error amendment (R2b) ---

  defp attrs do
    %{
      target_kind: "object_version",
      bucket_name: "mutation-test",
      object_key: "path/to/object.bin",
      version_id: "null",
      generation: 7,
      operation: "put_object",
      authority_mode: "pg",
      backend: "Maxio.Storage.FS"
    }
  end

  defp fingerprint do
    %{
      "etag" => "abc",
      "size" => 3,
      "sidecar_sha256" => String.duplicate("a", 64)
    }
  end

  defp previous_epoch do
    {:ok, target} =
      Maxio.Storage.ObjectEpoch.object_target(
        "mutation-test",
        "path/to/object.bin",
        "null"
      )

    {:ok, token} =
      Maxio.Storage.ObjectEpoch.token(6, "00000000-0000-0000-0000-000000000006")

    {:ok, epoch} =
      Maxio.Storage.ObjectEpoch.new(target, token, %{
        operation: "put_object",
        phase: "committed",
        value_type: "object",
        fingerprint: fingerprint(),
        updated_at: @now
      })

    {:ok, bytes} = Maxio.Storage.ObjectEpoch.encode(epoch)
    Jason.decode!(bytes)
  end
end
