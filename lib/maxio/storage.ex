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

  @spec get(String.t(), String.t(), String.t(), Maxio.Storage.Backend.range()) ::
          {:ok, Enumerable.t()} | {:error, term()}
  def get(bucket, key, version_id \\ "null", range \\ nil),
    do: backend().get(bucket, key, version_id, range)

  @spec stat(String.t(), String.t(), String.t()) ::
          {:ok, %{size: non_neg_integer()}} | {:error, :enoent}
  def stat(bucket, key, version_id \\ "null"), do: backend().stat(bucket, key, version_id)

  @spec delete(String.t(), String.t(), String.t()) :: :ok | {:error, term()}
  def delete(bucket, key, version_id \\ "null"), do: backend().delete(bucket, key, version_id)

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
  `{:error, :write_quorum}`；FS 后端 `{:error, :not_supported}`）。见 `Maxio.Storage.Backend.put_delete_marker/5`。
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
end
