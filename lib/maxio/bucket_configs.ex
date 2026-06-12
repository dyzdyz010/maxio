defmodule Maxio.BucketConfigs do
  @moduledoc """
  桶高级特性配置上下文（CORS / Lifecycle / 默认加密 / PublicAccessBlock）。
  每桶至多一行 bucket_configs；
  按 kind 读/写/删单个配置字段。get 返回已解析的结构（list 或 map）或 :none。
  """
  alias Maxio.Repo
  alias Maxio.Cluster.Notify
  alias Maxio.BucketConfigs.BucketConfig

  @type kind :: :cors | :lifecycle | :encryption | :public_access_block
  @kinds [:cors, :lifecycle, :encryption, :public_access_block]

  @doc "取某桶某类配置。未配置（行不存在或该列为 nil）→ :none。"
  @spec get(String.t(), kind()) :: {:ok, list() | map()} | :none
  def get(bucket, kind) when kind in @kinds do
    case Repo.get_by(BucketConfig, bucket_name: bucket) do
      nil ->
        :none

      %BucketConfig{} = row ->
        case Map.get(row, kind) do
          nil -> :none
          value -> {:ok, value}
        end
    end
  end

  @doc "写入/覆盖某桶某类配置（按 bucket_name upsert，只更新该列）。"
  @spec put(String.t(), kind(), list() | map()) :: :ok | {:error, term()}
  def put(bucket, kind, value) when kind in @kinds do
    attrs = %{:bucket_name => bucket, kind => value}

    %BucketConfig{}
    |> BucketConfig.changeset(attrs)
    |> Repo.insert(
      on_conflict: {:replace, [kind, :updated_at]},
      conflict_target: :bucket_name
    )
    |> case do
      {:ok, _} ->
        Notify.broadcast({:bucket_config_changed, bucket, kind})
        :ok

      {:error, cs} ->
        {:error, cs}
    end
  end

  @doc "删除某桶某类配置（把该列置 nil；幂等）。行不存在 → :ok。"
  @spec delete(String.t(), kind()) :: :ok
  def delete(bucket, kind) when kind in @kinds do
    case Repo.get_by(BucketConfig, bucket_name: bucket) do
      nil ->
        Notify.broadcast({:bucket_config_changed, bucket, kind})
        :ok

      %BucketConfig{} = row ->
        row |> BucketConfig.changeset(%{:bucket_name => bucket, kind => nil}) |> Repo.update!()
        Notify.broadcast({:bucket_config_changed, bucket, kind})
        :ok
    end
  end
end
