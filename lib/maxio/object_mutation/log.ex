defmodule Maxio.ObjectMutation.Log do
  @moduledoc """
  ObjectMutation 协议统一结构化日志（协议 §7 固定字段；AGENTS.md 铁律 4：无 GUI 也必须
  凭日志完整定位一次 mutation 的全生命周期）。

  固定字段白名单：action / request_id / mutation_id / mutation_generation /
  mutation_operation / mutation_phase / authority_mode / backend / bucket / key /
  version_id / placement_set_id / outcome / reason，以及 G2 的九个有界 proof 标量
  proof_mode / proof_class / proof_required / proof_verified / proof_finalized /
  proof_debt / proof_unavailable / proof_omitted / proof_orphaned。`request_id` 依赖 S3 管线已注入的
  进程 Logger metadata（Commit 在请求进程内执行，自动串联）；本模块只放行白名单键——
  **绝不记录对象 body、密钥或 SSE envelope**（字段硬性白名单保证）。

  关键事件（协议 §7）：claim、publish quorum、metadata committed、rollback
  requested/result、finalize result、recovery decision、quarantine。
  """

  require Logger

  alias Maxio.ObjectMutation.Journal

  @md_keys [
    :action,
    :request_id,
    :mutation_id,
    :mutation_generation,
    :mutation_operation,
    :mutation_phase,
    :authority_mode,
    :backend,
    :bucket,
    :key,
    :version_id,
    :placement_set_id,
    :outcome,
    :reason,
    # G2 §3.4：proof/finalize 的**有界标量**取证字段。只放行这九个数值/枚举键；
    # raw summary、endpoint、node、drive、path、backup path、sidecar、token、placement
    # payload 与 inspected reason 一律不在白名单内，因此永远进不了日志。
    :proof_mode,
    :proof_class,
    :proof_required,
    :proof_verified,
    :proof_finalized,
    :proof_debt,
    :proof_unavailable,
    :proof_omitted,
    :proof_orphaned
  ]

  @doc "把关键字参数中协议固定字段提取为 Logger metadata（白名单外的键一律丢弃）。"
  @spec context(keyword()) :: keyword()
  def context(fields) when is_list(fields) do
    Enum.filter(fields, fn {k, _v} -> k in @md_keys end)
  end

  @doc """
  从 journal 行派生固定字段（mutation_id/generation/operation/phase/authority_mode/
  backend/bucket/key/version_id/placement_set_id），`extra` 覆盖同名键（action/outcome/
  reason 等事件级字段由调用点补充）。
  """
  @spec journal_fields(Journal.t(), keyword()) :: keyword()
  def journal_fields(%Journal{} = journal, extra \\ []) when is_list(extra) do
    Keyword.merge(
      [
        mutation_id: journal.id,
        mutation_generation: journal.generation,
        mutation_operation: journal.operation,
        mutation_phase: journal.phase,
        authority_mode: journal.authority_mode,
        backend: journal.backend,
        bucket: journal.bucket_name,
        key: journal.object_key,
        version_id: journal.version_id,
        placement_set_id: placement_set_id(journal.placement_snapshot)
      ],
      extra
    )
  end

  @doc "info 级结构化日志（claim / publish / metadata committed / finalize 成功等）。"
  @spec info(String.t(), keyword()) :: :ok
  def info(message, fields) when is_list(fields) do
    Logger.info(message, context(fields))
  end

  @doc "warning 级结构化日志（rollback requested / superseded / 可重试错误等非静默场景）。"
  @spec warn(String.t(), keyword()) :: :ok
  def warn(message, fields) when is_list(fields) do
    Logger.warning(message, context(fields))
  end

  @doc "error 级结构化日志（finalize/restore 失败、quarantine、契约违约兜底）。"
  @spec error(String.t(), keyword()) :: :ok
  def error(message, fields) when is_list(fields) do
    Logger.error(message, context(fields))
  end

  defp placement_set_id(%{"set_id" => set_id}), do: set_id
  defp placement_set_id(_snapshot), do: nil
end
