defmodule Maxio.Storage.MutationContext do
  @moduledoc """
  backend `restore_if_current/2`、`finalize_if_current/2` 的纯数据执行上下文（协议 §3.3）。

  由 journal 行确定性派生（orchestration 与 recovery 共用 `from_journal/1`），后端单测
  可直接以 struct 构造。所有字段均为可 erpc 序列化的纯数据；Distributed 后端的恢复端点
  解析只认 `placement_snapshot`（journal 保存的历史 placement），绝不按当前 router 猜测。
  本模块不读写磁盘。
  """

  alias Maxio.Cluster.Paths
  alias Maxio.ObjectMutation.Journal
  alias Maxio.Storage.ObjectEpoch

  @enforce_keys [:mutation_id, :target, :token, :operation, :authority_mode, :backend, :final_rel]
  defstruct [
    :mutation_id,
    :target,
    :token,
    :operation,
    :authority_mode,
    :backend,
    :final_rel,
    :bucket,
    :key,
    :version_id,
    :placement_snapshot,
    :previous_epoch,
    :published_fingerprint
  ]

  @type t :: %__MODULE__{}

  @doc """
  从 journal 行派生执行上下文：target/token/final_rel 均由 journal 字段重建
  （mutation_id 即 journal id；final_rel 为 target 在每个 drive 下的相对落点路径）。
  """
  @spec from_journal(Journal.t()) :: {:ok, t()} | {:error, term()}
  def from_journal(%Journal{} = journal) do
    with {:ok, target} <- journal_target(journal),
         {:ok, token} <- ObjectEpoch.token(journal.generation, journal.id),
         {:ok, final_rel} <- journal_final_rel(journal) do
      {:ok,
       %__MODULE__{
         mutation_id: token["mutation_id"],
         target: target,
         token: token,
         operation: journal.operation,
         authority_mode: journal.authority_mode,
         backend: journal.backend,
         final_rel: final_rel,
         bucket: journal.bucket_name,
         key: journal.object_key,
         version_id: journal.version_id,
         placement_snapshot: journal.placement_snapshot,
         previous_epoch: journal.previous_epoch,
         published_fingerprint: journal.published_fingerprint
       }}
    end
  end

  defp journal_target(%Journal{target_kind: "object_version"} = journal),
    do:
      ObjectEpoch.object_target(
        journal.bucket_name,
        journal.object_key,
        journal.version_id
      )

  defp journal_target(%Journal{target_kind: "multipart_upload"} = journal),
    do:
      ObjectEpoch.upload_target(
        journal.bucket_name,
        journal.object_key,
        journal.upload_id
      )

  defp journal_target(%Journal{target_kind: "multipart_part"} = journal),
    do:
      ObjectEpoch.part_target(
        journal.bucket_name,
        journal.object_key,
        journal.upload_id,
        journal.part_number
      )

  defp journal_target(%Journal{target_kind: kind}), do: {:error, {:invalid_target_kind, kind}}

  defp journal_final_rel(%Journal{target_kind: "object_version"} = journal),
    do: Paths.object_rel(journal.bucket_name, journal.object_key, journal.version_id)

  defp journal_final_rel(%Journal{target_kind: "multipart_upload"} = journal),
    do: {:ok, Paths.upload_rel(journal.bucket_name, journal.upload_id)}

  defp journal_final_rel(%Journal{target_kind: "multipart_part"} = journal),
    do: {:ok, Paths.part_rel(journal.bucket_name, journal.upload_id, journal.part_number)}
end
