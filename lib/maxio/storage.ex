defmodule Maxio.Storage do
  @moduledoc """
  存储门面：按 `config :maxio, :storage_backend` 派发到具体 Backend 实现。
  上层（Object/Bucket handler）调本模块，不直接耦合 FS。
  """

  @doc "当前配置的存储后端模块。"
  @spec backend() :: module()
  def backend, do: Application.fetch_env!(:maxio, :storage_backend)

  @spec put(String.t(), String.t(), Enumerable.t(), keyword()) ::
          {:ok, Maxio.Storage.Backend.put_result()} | {:error, term()}
  def put(bucket, key, chunks, opts \\ []), do: backend().put(bucket, key, chunks, opts)

  @spec get(String.t(), String.t(), Maxio.Storage.Backend.range()) ::
          {:ok, Enumerable.t()} | {:error, term()}
  def get(bucket, key, range \\ nil), do: backend().get(bucket, key, range)

  @spec stat(String.t(), String.t()) :: {:ok, %{size: non_neg_integer()}} | {:error, :enoent}
  def stat(bucket, key), do: backend().stat(bucket, key)

  @spec delete(String.t(), String.t()) :: :ok | {:error, term()}
  def delete(bucket, key), do: backend().delete(bucket, key)

  @spec put_bucket(String.t()) :: :ok | {:error, term()}
  def put_bucket(bucket), do: backend().put_bucket(bucket)

  @spec delete_bucket(String.t()) :: :ok | {:error, term()}
  def delete_bucket(bucket), do: backend().delete_bucket(bucket)
end
