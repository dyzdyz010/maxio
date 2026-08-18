defmodule Maxio.ObjectMutation.StorageDispositionTest do
  # 纯函数分类器：无 Repo、无 backend、无全局状态，可以 async。
  use ExUnit.Case, async: true

  alias Maxio.Storage.PublishedProof

  # --- Task 3 / G2 §4.4：纯 authority-neutral 事实分类器 RED ---
  #
  # `Maxio.ObjectMutation.StorageDisposition` 只有两个公共函数：
  #
  #     proof(storage_result)
  #     finalize(storage_result)
  #
  # 它只接收 `Maxio.Storage` 已经规范化的公共返回，把事实分类，并把 canonical summary
  # **严格 term-identical** 地透传；它绝不做 journal/HTTP/retry 决策，也绝不校验、裁剪、
  # 重排、复制、编码或投影 summary。
  #
  # 任何 obsolete / malformed / 跨 mode / 未知 term 一律 fail closed 为固定标量，且该未知
  # term 绝不被 inspect、记录、持久化或返回。
  #
  # 本文件经 `apply/3` 调用尚未存在的模块：既避免 undefined-module 编译警告，也让
  # 「能力缺失」成为**独立**失败签名，不会掩盖 facade / Commit 的活体 RED。

  @proof_violation {:contract_violation, :proof}
  @finalize_violation {:contract_violation, :finalize}

  # 固定 raw sentinel：拒绝路径的返回值里绝不允许出现它。
  @raw_sentinel :g2_disposition_raw_sentinel

  defp capability!() do
    assert Code.ensure_loaded?(Maxio.ObjectMutation.StorageDisposition),
           "T3-G2: Maxio.ObjectMutation.StorageDisposition 尚未实现（handoff §3.2 / §5）"

    for {fun, arity} <- [proof: 1, finalize: 1] do
      assert function_exported?(Maxio.ObjectMutation.StorageDisposition, fun, arity),
             "T3-G2: Maxio.ObjectMutation.StorageDisposition.#{fun}/#{arity} 尚未实现"
    end
  end

  defp proof(term) do
    capability!()
    apply(Maxio.ObjectMutation.StorageDisposition, :proof, [term])
  end

  defp finalize(term) do
    capability!()
    apply(Maxio.ObjectMutation.StorageDisposition, :finalize, [term])
  end

  # --- canonical fixtures，全部由公共 constructor 产出 ---

  defp verified_summary do
    {:ok, {:verified, summary}} =
      PublishedProof.classify(1, [{"local", PublishedProof.verified("local", %{})}])

    summary
  end

  defp degraded_summary do
    {:ok, {:degraded, summary}} =
      PublishedProof.classify(1, [
        {"local", PublishedProof.verified("local", %{})},
        {"ordinal:1", PublishedProof.failed(:unavailable, "ordinal:1", %{owned: true})}
      ])

    summary
  end

  defp superseded_summary do
    {:ok, {:superseded, summary}} =
      PublishedProof.classify(1, [{"local", PublishedProof.superseded("local")}])

    summary
  end

  defp failed_summary(class) do
    {:error, {:published_proof_failed, ^class, summary}} =
      PublishedProof.classify(1, [
        {"local", PublishedProof.failed(class, "local", %{owned: true})}
      ])

    summary
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

  defp finalize_failed_summary(class) do
    {:error, {:published_proof_failed, ^class, summary}} =
      PublishedProof.classify_finalize(1, [
        {"local", PublishedProof.endpoint_finalize_failed(class, "local", %{owned: true})}
      ])

    summary
  end

  # --- §3.2 proof 映射，逐条精确 + summary 严格 === 透传 ---

  @tag :task3_g2_commit_red
  test "g2 red: proof maps every allowed result and passes the summary through identically" do
    verified = verified_summary()
    degraded = degraded_summary()
    superseded = superseded_summary()

    cases = [
      {{:ok, {:verified, verified}}, {:proof_passed, :verified, verified}, verified},
      {{:ok, {:degraded, degraded}}, {:proof_passed, :degraded, degraded}, degraded},
      {{:ok, {:superseded, superseded}}, {:superseded, superseded}, superseded}
    ]

    for {input, expected, summary} <- cases do
      result = proof(input)
      assert result == expected, "proof 映射必须精确：#{inspect(input)}"

      # summary 必须是**同一个 term**，绝不被校验、裁剪、重排、复制或编码。
      assert elem(result, tuple_size(result) - 1) === summary
    end
  end

  @tag :task3_g2_commit_red
  test "g2 red: proof partitions retryable and integrity failures with identical summaries" do
    unavailable = failed_summary(:unavailable)

    assert proof({:error, {:published_proof_failed, :unavailable, unavailable}}) ==
             {:retryable_failure, :unavailable, unavailable}

    assert elem(proof({:error, {:published_proof_failed, :unavailable, unavailable}}), 2) ===
             unavailable

    for class <- [:mismatch, :corrupt, :placement_drift] do
      summary = failed_summary(class)
      result = proof({:error, {:published_proof_failed, class, summary}})

      assert result == {:integrity_failure, class, summary},
             "integrity class #{class} 必须精确分类"

      assert elem(result, 2) === summary
    end
  end

  @tag :task3_g2_commit_red
  test "g2 red: proof folds its own contract violation to the fixed scalar" do
    assert proof({:error, {:published_proof_contract_violation, :proof}}) == @proof_violation
  end

  # --- §3.2 finalize 映射 ---

  @tag :task3_g2_commit_red
  test "g2 red: finalize maps every allowed success and passes the summary through identically" do
    finalized = finalized_summary()
    cleanup = cleanup_pending_summary()
    superseded = finalize_superseded_summary()

    cases = [
      {{:ok, {:finalized, finalized}}, {:finalized, finalized}, finalized},
      {{:ok, {:cleanup_pending, cleanup}}, {:cleanup_pending, cleanup}, cleanup},
      {{:ok, {:superseded, superseded}}, {:superseded, superseded}, superseded}
    ]

    for {input, expected, summary} <- cases do
      result = finalize(input)
      assert result == expected, "finalize 映射必须精确：#{inspect(input)}"
      assert elem(result, tuple_size(result) - 1) === summary
    end
  end

  @tag :task3_g2_commit_red
  test "g2 red: finalize partitions retryable and integrity failures with identical summaries" do
    unavailable = finalize_failed_summary(:unavailable)

    assert finalize({:error, {:published_proof_failed, :unavailable, unavailable}}) ==
             {:retryable_failure, :unavailable, unavailable}

    for class <- [:mismatch, :corrupt, :placement_drift] do
      summary = finalize_failed_summary(class)
      result = finalize({:error, {:published_proof_failed, class, summary}})

      assert result == {:integrity_failure, class, summary}
      assert elem(result, 2) === summary
    end
  end

  @tag :task3_g2_commit_red
  test "g2 red: finalize folds its own contract violation to the fixed scalar" do
    assert finalize({:error, {:published_proof_contract_violation, :finalize}}) ==
             @finalize_violation
  end

  # --- fail-closed：跨 mode、旧 atom tuple、伪造 fenced、任意 term ---

  @tag :task3_g2_commit_red
  test "g2 red: cross-mode values fail closed in both directions" do
    # finalize-only outcome 送进 proof。
    assert proof({:ok, {:finalized, finalized_summary()}}) == @proof_violation
    assert proof({:ok, {:cleanup_pending, cleanup_pending_summary()}}) == @proof_violation
    assert proof({:error, {:published_proof_contract_violation, :finalize}}) == @proof_violation

    # proof-only outcome 送进 finalize。
    assert finalize({:ok, {:verified, verified_summary()}}) == @finalize_violation
    assert finalize({:ok, {:degraded, degraded_summary()}}) == @finalize_violation

    assert finalize({:error, {:published_proof_contract_violation, :proof}}) ==
             @finalize_violation
  end

  @tag :task3_g2_commit_red
  test "g2 red: retired atom tuples and forged fenced class fail closed" do
    retired = [
      {:ok, :finalized},
      {:ok, :superseded},
      {:ok, :verified},
      {:ok, :cleanup_pending}
    ]

    for term <- retired do
      assert proof(term) == @proof_violation, "retired atom tuple 必须 fail closed：#{inspect(term)}"
      assert finalize(term) == @finalize_violation
    end

    # `:fenced` 永远不是合法 failed class：它只能表达为 superseded。
    forged = {:error, {:published_proof_failed, :fenced, verified_summary()}}
    assert proof(forged) == @proof_violation
    assert finalize(forged) == @finalize_violation
  end

  @tag :task3_g2_commit_red
  test "g2 red: arbitrary maps, tuples, scalars and exception-like terms fail closed without leaking" do
    hostile = [
      nil,
      :ok,
      @raw_sentinel,
      42,
      "published",
      %{},
      %{"scope" => "aggregate"},
      {:ok, @raw_sentinel},
      {:error, @raw_sentinel},
      {:error, {:published_proof_failed, :unavailable}},
      {:error, {:published_proof_contract_violation, :restore}},
      {:ok, {:verified, verified_summary(), :extra}},
      %RuntimeError{message: to_string(@raw_sentinel)},
      {:EXIT, @raw_sentinel},
      [{:ok, {:verified, verified_summary()}}]
    ]

    for term <- hostile do
      proof_result = proof(term)
      finalize_result = finalize(term)

      assert proof_result == @proof_violation, "hostile term 必须 fail closed：#{inspect(term)}"
      assert finalize_result == @finalize_violation

      # 未知 term 绝不被返回或 inspect 进结果。
      refute String.contains?(inspect(proof_result), to_string(@raw_sentinel))
      refute String.contains?(inspect(finalize_result), to_string(@raw_sentinel))
    end
  end

  # --- 控制：fixtures 本身是活的 canonical 值 ---

  @tag :task3_g2_commit_red
  test "g2 control: every disposition fixture is a live canonical aggregate summary" do
    assert verified_summary()["status"] == "verified"
    assert degraded_summary()["status"] == "degraded"
    assert superseded_summary()["status"] == "superseded"
    assert finalized_summary()["status"] == "finalized"
    assert cleanup_pending_summary()["status"] == "cleanup_pending"
    assert finalize_superseded_summary()["status"] == "superseded"

    for class <- [:unavailable, :mismatch, :corrupt, :placement_drift] do
      assert failed_summary(class)["class"] == Atom.to_string(class)
      assert finalize_failed_summary(class)["class"] == Atom.to_string(class)
    end

    # 这些 fixture 全部经 Storage facade 的既有 trust boundary 判定为合法 callback 结果，
    # 因此 StorageDisposition 收到的确实是「已规范化的公共返回」。
    assert PublishedProof.validate_callback_result(:proof, {:ok, {:verified, verified_summary()}}) ==
             :ok

    assert PublishedProof.validate_callback_result(
             :finalize,
             {:ok, {:finalized, finalized_summary()}}
           ) == :ok
  end
end
