defmodule Maxio.ObjectMutation.StorageDisposition do
  @moduledoc """
  纯粹、authority-neutral 的 backend 结果**事实分类器**（G2 设计 §3.2）。

  它只接收 `Maxio.Storage` 已经规范化的公共返回值，把它分类成一组固定的事实标签，并把
  canonical aggregate summary **严格 term-identically** 透传出去。

  它刻意**不做**任何决策：不碰 journal / HTTP / retry / backoff，不校验、不裁剪、不重排、
  不复制、不编码、不投影 `summary`。Commit 与后续 Recovery 因此共享同一份 backend 结果
  划分，不需要各自维护一份副本。

  ## 依赖边界

  本模块不依赖 Repo/Ecto、Journal/ObjectMutation、Commit/Recovery、HTTP/S3、Logger、
  时间/重试、任何 backend 实现、placement/layout/shard/quorum、PublishedProof 合并或
  DurableJSON。它只做模式匹配。

  ## 失败关闭

  任何 obsolete、malformed、跨 mode 或未知 term 一律折叠为该 mode 的固定 contract
  violation。未知 term 绝不被 inspect、记录、持久化或返回。
  """

  @type summary :: map()

  @type proof_disposition ::
          {:proof_passed, :verified | :degraded, summary()}
          | {:superseded, summary()}
          | {:retryable_failure, :unavailable, summary()}
          | {:integrity_failure, :mismatch | :corrupt | :placement_drift, summary()}
          | {:contract_violation, :proof}

  @type finalize_disposition ::
          {:finalized, summary()}
          | {:cleanup_pending, summary()}
          | {:superseded, summary()}
          | {:retryable_failure, :unavailable, summary()}
          | {:integrity_failure, :mismatch | :corrupt | :placement_drift, summary()}
          | {:contract_violation, :finalize}

  @integrity_classes [:mismatch, :corrupt, :placement_drift]

  @doc """
  分类 `Maxio.Storage.verify_published/2` 的已规范化返回。

  `summary` 原样透传；任何非 proof-mode canonical 值折叠为
  `{:contract_violation, :proof}`。
  """
  @spec proof(term()) :: proof_disposition()
  def proof({:ok, {:verified, summary}}) when is_map(summary),
    do: {:proof_passed, :verified, summary}

  def proof({:ok, {:degraded, summary}}) when is_map(summary),
    do: {:proof_passed, :degraded, summary}

  def proof({:ok, {:superseded, summary}}) when is_map(summary),
    do: {:superseded, summary}

  def proof({:error, {:published_proof_failed, :unavailable, summary}}) when is_map(summary),
    do: {:retryable_failure, :unavailable, summary}

  def proof({:error, {:published_proof_failed, class, summary}})
      when class in @integrity_classes and is_map(summary),
      do: {:integrity_failure, class, summary}

  def proof({:error, {:published_proof_contract_violation, :proof}}),
    do: {:contract_violation, :proof}

  def proof(_term), do: {:contract_violation, :proof}

  @doc """
  分类 `Maxio.Storage.finalize_if_current/2` 的已规范化返回。

  `summary` 原样透传；任何非 finalize-mode canonical 值折叠为
  `{:contract_violation, :finalize}`。
  """
  @spec finalize(term()) :: finalize_disposition()
  def finalize({:ok, {:finalized, summary}}) when is_map(summary),
    do: {:finalized, summary}

  def finalize({:ok, {:cleanup_pending, summary}}) when is_map(summary),
    do: {:cleanup_pending, summary}

  def finalize({:ok, {:superseded, summary}}) when is_map(summary),
    do: {:superseded, summary}

  def finalize({:error, {:published_proof_failed, :unavailable, summary}}) when is_map(summary),
    do: {:retryable_failure, :unavailable, summary}

  def finalize({:error, {:published_proof_failed, class, summary}})
      when class in @integrity_classes and is_map(summary),
      do: {:integrity_failure, class, summary}

  def finalize({:error, {:published_proof_contract_violation, :finalize}}),
    do: {:contract_violation, :finalize}

  def finalize(_term), do: {:contract_violation, :finalize}
end
