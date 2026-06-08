defmodule Maxio.Storage do
  @moduledoc """
  存储门面：按 `config :maxio, :storage_backend` 派发到具体 Backend 实现。
  上层（Object/Bucket handler）调本模块，不直接耦合 FS。
  """

  @doc "当前配置的存储后端模块。"
  @spec backend() :: module()
  def backend, do: Application.fetch_env!(:maxio, :storage_backend)

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
end
