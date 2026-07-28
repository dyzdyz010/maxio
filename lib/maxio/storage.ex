defmodule Maxio.Storage do
  @moduledoc """
  存储门面：按 `config :maxio, :storage_backend` 派发到具体 Backend 实现。
  上层（Object/Bucket handler）调本模块，不直接耦合 FS。
  """

  @doc "当前配置的存储后端模块。"
  @spec backend() :: module()
  def backend, do: Application.fetch_env!(:maxio, :storage_backend)

  @doc """
  流式写入对象字节并落 sidecar。`opts` 透传给后端；其中 `:object_meta`（map）携带 GET/HEAD/LIST
  所需的富元数据（content_type/tags/sse/acl_canned/storage_class/user_metadata），令纠删/分布式
  后端写出完整 maxio/2 sidecar（见 `Maxio.Storage.Backend` 的 `:object_meta` 契约）。不改 arity。
  """
  @spec put(String.t(), String.t(), String.t(), Enumerable.t(), keyword()) ::
          {:ok, Maxio.Storage.Backend.put_result()} | {:error, term()}
  def put(bucket, key, version_id \\ "null", chunks, opts \\ [])

  def put(bucket, key, version_id, chunks, opts),
    do: backend().put(bucket, key, version_id, chunks, opts)

  @spec get(String.t(), String.t(), String.t(), Maxio.Storage.Backend.range(), keyword()) ::
          {:ok, Enumerable.t()} | {:error, term()}
  def get(bucket, key, version_id \\ "null", range \\ nil, opts \\ []),
    do: backend().get(bucket, key, version_id, range, opts)

  @spec stat(String.t(), String.t(), String.t(), keyword()) ::
          {:ok, %{size: non_neg_integer()}} | {:error, :enoent}
  def stat(bucket, key, version_id \\ "null", opts \\ []),
    do: backend().stat(bucket, key, version_id, opts)

  @spec delete(String.t(), String.t(), String.t(), keyword()) :: :ok | {:error, term()}
  def delete(bucket, key, version_id \\ "null", opts \\ []),
    do: backend().delete(bucket, key, version_id, opts)

  @spec put_bucket(String.t()) :: :ok | {:error, term()}
  def put_bucket(bucket), do: backend().put_bucket(bucket)

  @spec delete_bucket(String.t()) :: :ok | {:error, term()}
  def delete_bucket(bucket), do: backend().delete_bucket(bucket)

  # ── 分段上传 parts 门面（M2-4，转发到 backend）──

  @spec put_part(String.t(), String.t(), String.t(), pos_integer(), Enumerable.t(), keyword()) ::
          {:ok, Maxio.Storage.Backend.part_put_result()} | {:error, term()}
  def put_part(bucket, key, upload_id, part_number, chunks, opts \\ []),
    do: backend().put_part(bucket, key, upload_id, part_number, chunks, opts)

  @spec get_part_stream(String.t(), String.t(), String.t(), pos_integer(), keyword()) ::
          {:ok, Enumerable.t()} | {:error, term()}
  def get_part_stream(bucket, key, upload_id, part_number, opts \\ []),
    do: backend().get_part_stream(bucket, key, upload_id, part_number, opts)

  @spec assemble(String.t(), String.t(), String.t(), [pos_integer()], keyword()) ::
          {:ok, %{size: non_neg_integer()}} | {:error, term()}
  def assemble(bucket, key, upload_id, part_numbers, opts \\ []),
    do: backend().assemble(bucket, key, upload_id, part_numbers, opts)

  @spec abort_upload(String.t(), String.t(), String.t(), keyword()) :: :ok | {:error, term()}
  def abort_upload(bucket, key, upload_id, opts \\ []),
    do: backend().abort_upload(bucket, key, upload_id, opts)

  # ── delete marker 落盘门面（ROUTE B B5-0，转发到 backend）──

  @doc """
  在 `version_id` 盘上路径写纯 delete-marker maxio/2 sidecar（达 write_quorum 才 `:ok`，否则
  `{:error, :write_quorum}`；FS 后端单盘 quorum=1，B6-1）。见 `Maxio.Storage.Backend.put_delete_marker/5`。
  `entry_opts` 携版本头覆盖（默认空全默认）；`opts` 透传给后端（test 经 `:transport`/`:topology` 注入）。
  """
  @spec put_delete_marker(String.t(), String.t(), String.t(), keyword(), keyword()) ::
          :ok | {:error, term()}
  def put_delete_marker(bucket, key, version_id, entry_opts \\ [], opts \\ []),
    do: backend().put_delete_marker(bucket, key, version_id, entry_opts, opts)

  @doc """
  ROUTE B fidelity —— DELETE ?versionId 的**权威盘上版本删除**（quorum 确认才 `:ok`，见
  `Maxio.Storage.Backend.delete_version/4`）。与 `delete/3`（best-effort 清理删除，无 quorum 语义、
  恒 `:ok`）不同：本函数用于 `authoritative_source(:write)=:sidecar` 下「盘上删除即权威提交」，
  quorum 不足 → `{:error, :write_quorum}`（handler 映射 503 SlowDownWrite，绝不静默 204）。
  `opts` 透传给后端（test 经 `:transport`/`:topology` 注入）。
  """
  @spec delete_version(String.t(), String.t(), String.t(), keyword()) :: :ok | {:error, term()}
  def delete_version(bucket, key, version_id, opts \\ []),
    do: backend().delete_version(bucket, key, version_id, opts)

  @doc """
  Persist retained notification ledger entries outside object/version carriers.
  See `Maxio.Storage.Backend.put_notification_ledgers/4`.
  """
  @spec put_notification_ledgers(String.t(), String.t(), [map()], keyword()) ::
          :ok | {:error, term()}
  def put_notification_ledgers(bucket, key, entries, opts \\ []),
    do: backend().put_notification_ledgers(bucket, key, entries, opts)

  @doc """
  List retained notification ledgers for a key or a whole bucket.
  See `Maxio.Storage.Backend.list_notification_ledgers/3`.
  """
  @spec list_notification_ledgers(String.t(), String.t() | :all, keyword()) ::
          {:ok, [map()]} | {:error, term()}
  def list_notification_ledgers(bucket, key_filter, opts \\ []),
    do: backend().list_notification_ledgers(bucket, key_filter, opts)

  @doc """
  Delete retained notification ledgers after replay/prune decisions.
  See `Maxio.Storage.Backend.delete_notification_ledgers/4`.
  """
  @spec delete_notification_ledgers(String.t(), String.t(), [String.t()], keyword()) ::
          :ok | {:error, term()}
  def delete_notification_ledgers(bucket, key, ids, opts \\ []),
    do: backend().delete_notification_ledgers(bucket, key, ids, opts)

  # ── ObjectMutation epoch CAS 门面（协议 §3.3，Phase 1 B5 接线；转发到 backend）──

  @doc """
  以 quorum 语义 claim target 的 fencing epoch（per-endpoint CAS 仅接受严格更大 token）。
  见 `Maxio.Storage.Backend.claim_epoch/4`。
  """
  @spec claim_epoch(
          Maxio.Storage.ObjectEpoch.target(),
          Maxio.Storage.ObjectEpoch.token(),
          String.t(),
          keyword()
        ) ::
          {:ok,
           %{
             :previous => Maxio.Storage.ObjectEpoch.t() | nil,
             :endpoints_ok => non_neg_integer(),
             optional(:placement_snapshot) => map()
           }}
          | {:error, term()}
  def claim_epoch(target, token, operation, opts \\ []),
    do: backend().claim_epoch(target, token, operation, opts)

  @doc "quorum 读 target 当前 epoch（`:absent` 显式区分）。见 `Maxio.Storage.Backend.current_epoch/2`。"
  @spec current_epoch(Maxio.Storage.ObjectEpoch.target(), keyword()) ::
          {:ok, Maxio.Storage.ObjectEpoch.t() | :absent} | {:error, term()}
  def current_epoch(target, opts \\ []), do: backend().current_epoch(target, opts)

  @doc """
  仅当 ctx.token 仍为当前 epoch 时恢复旧值；successor → `{:ok, :superseded}`。
  见 `Maxio.Storage.Backend.restore_if_current/2`。
  """
  @spec restore_if_current(Maxio.Storage.MutationContext.t(), keyword()) ::
          {:ok, :restored | :superseded} | {:error, term()}
  def restore_if_current(ctx, opts \\ []), do: backend().restore_if_current(ctx, opts)

  @doc """
  proof-aware 终结：仅当 ctx.token 仍为当前 epoch 时重新取证并终结；幂等。与
  `verify_published/2` 共用同一个非变异 callback trust boundary，非法/obsolete/跨 mode
  返回折叠为 `{:error, {:published_proof_contract_violation, :finalize}}`。
  见 `Maxio.Storage.Backend.finalize_if_current/2`。
  """
  @spec finalize_if_current(Maxio.Storage.MutationContext.t(), keyword()) ::
          Maxio.Storage.PublishedProof.aggregate_finalize_result()
          | {:error, {:published_proof_contract_violation, :finalize}}
  def finalize_if_current(ctx, opts \\ []) do
    guard_callback_result(:finalize, backend().finalize_if_current(ctx, opts))
  end

  @doc """
  取得已发布 final 的 backend aggregate proof（设计 D1）。本函数是插件 trust boundary：
  backend 返回先经非变异的
  `Maxio.Storage.PublishedProof.validate_callback_result/2` 复核，合法值原样透传，
  非法/obsolete/wrong-mode 值一律折叠为
  `{:error, {:published_proof_contract_violation, :proof}}`。raw callback term 绝不
  被持久化、记录或对外暴露；调用方按 integrity fail closed 处理，不得当作可重试的
  unavailable，也不得删除 backup。
  """
  @spec verify_published(Maxio.Storage.MutationContext.t(), keyword()) ::
          Maxio.Storage.PublishedProof.aggregate_proof_result()
          | {:error, {:published_proof_contract_violation, :proof}}
  def verify_published(ctx, opts \\ []) do
    guard_callback_result(:proof, backend().verify_published(ctx, opts))
  end

  defp guard_callback_result(mode, result) do
    case Maxio.Storage.PublishedProof.validate_callback_result(mode, result) do
      :ok -> result
      {:error, :invalid_proof_result} -> {:error, {:published_proof_contract_violation, mode}}
    end
  end
end
