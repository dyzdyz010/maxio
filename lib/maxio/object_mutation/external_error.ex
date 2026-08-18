defmodule Maxio.ObjectMutation.ExternalError do
  @moduledoc """
  对象变更提交/恢复**稳定外层错误信封**到外部安全投影的唯一纯映射。

  这是 G4 里唯一允许匹配稳定外层信封的模块：HTTP、CLI、日志与异步 sink 只消费本模块
  返回的 `category` 与 `safe_code`，绝不自行匹配内部信封，也绝不从中推导 proof
  mode/class、可重试性或 cleanup debt。

  本模块只有一个公共函数：

      project(reason)

  返回：

      {:ok, :retryable, safe_code}
      {:ok, :internal, safe_code}
      :unrelated

  `safe_code` 是逐字冻结的 binary，可安全进入公共错误映射、结构化日志、durable
  `error_reason` 与 CLI 文本。

  ## 不变量

  1. **opaque summary 是内部能力**：只绑定为 `_opaque`，绝不 inspect、遍历、校验、
     编码、记录、持久化、调用或回显；投影结果里绝不含它。
  2. **fail closed**：首元素属于保留 tag 但形态不符合精确契约的元组（错误 arity、
     未知/伪造 class、错误 mode、未知 stage、多余载荷），一律折叠成固定的
     `<tag>:invalid` internal code，绝不退化成 `:unrelated`，也绝不回显原始值。
     伪造的 aggregate class `:fenced` 因此是 internal invalid。
  3. **保留 tag 只对元组生效**：独立的 epoch fence `{:fenced, token}`、裸保留原子、
     历史 storage 错误与任意其它 term 保持 `:unrelated`，既有映射路径原样保留。
  4. **纯粹**：无 Storage / PublishedProof / StorageDisposition / ObjectMutation /
     Commit / Recovery / S3 / Logger / Repo / Ecto / Jason / 配置 / 时间 / 重试 /
     backend / placement / quorum 依赖，也无 IO 与副作用。
  """

  # 精确投影（逐字冻结）。
  @proof_failed_unavailable "published_proof_failed:unavailable"
  @proof_failed_mismatch "published_proof_failed:mismatch"
  @proof_failed_corrupt "published_proof_failed:corrupt"
  @proof_failed_placement_drift "published_proof_failed:placement_drift"
  @proof_superseded "published_proof_superseded"
  @contract_violation_proof "published_proof_contract_violation:proof"
  @contract_violation_finalize "published_proof_contract_violation:finalize"
  @journal_publish_transition "object_mutation_journal:publish_transition"
  @journal_finalize_outcome "object_mutation_journal:finalize_outcome"

  # 保留 tag 的 fail-closed 固定 internal code（逐字冻结）。
  @proof_failed_invalid "published_proof_failed:invalid"
  @proof_superseded_invalid "published_proof_superseded:invalid"
  @contract_violation_invalid "published_proof_contract_violation:invalid"
  @journal_invalid "object_mutation_journal:invalid"

  @typedoc "外部类别：`:retryable` 交给公共重试语义，`:internal` 一律内部错误。"
  @type category :: :retryable | :internal

  @typedoc "可安全外泄的固定标量错误码。"
  @type safe_code :: binary()

  @doc """
  把一个内部 reason 投影成外部安全类别与固定 code；无关 term 返回 `:unrelated`。
  """
  @spec project(term()) :: {:ok, category(), safe_code()} | :unrelated

  # --- 精确稳定信封 ---

  def project({:published_proof_failed, :unavailable, _opaque}),
    do: {:ok, :retryable, @proof_failed_unavailable}

  def project({:published_proof_failed, :mismatch, _opaque}),
    do: {:ok, :internal, @proof_failed_mismatch}

  def project({:published_proof_failed, :corrupt, _opaque}),
    do: {:ok, :internal, @proof_failed_corrupt}

  def project({:published_proof_failed, :placement_drift, _opaque}),
    do: {:ok, :internal, @proof_failed_placement_drift}

  def project({:published_proof_superseded, _opaque}),
    do: {:ok, :retryable, @proof_superseded}

  def project({:published_proof_contract_violation, :proof}),
    do: {:ok, :internal, @contract_violation_proof}

  def project({:published_proof_contract_violation, :finalize}),
    do: {:ok, :internal, @contract_violation_finalize}

  def project({:object_mutation_journal, :internal, :publish_transition}),
    do: {:ok, :internal, @journal_publish_transition}

  def project({:object_mutation_journal, :internal, :finalize_outcome}),
    do: {:ok, :internal, @journal_finalize_outcome}

  # --- 保留 tag 的畸形信封：fail closed，只读首元素 ---

  def project(reason) when is_tuple(reason) and tuple_size(reason) > 0 do
    case elem(reason, 0) do
      :published_proof_failed -> {:ok, :internal, @proof_failed_invalid}
      :published_proof_superseded -> {:ok, :internal, @proof_superseded_invalid}
      :published_proof_contract_violation -> {:ok, :internal, @contract_violation_invalid}
      :object_mutation_journal -> {:ok, :internal, @journal_invalid}
      _other_tag -> :unrelated
    end
  end

  # --- 其余一切（含 `{:fenced, token}`、裸保留原子、历史 storage 错误） ---

  def project(_reason), do: :unrelated
end
