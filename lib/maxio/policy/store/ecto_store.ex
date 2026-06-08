defmodule Maxio.Policy.Store.EctoStore do
  @moduledoc """
  Postgres 策略后端（实现 Maxio.Policy.Store behaviour）。document 存 jsonb（解析后的 map），
  get 时 Jason.encode! 回放为 JSON 字节（round-trip 语义等价）。principal_policies MVP 恒 []（defer）。
  """
  @behaviour Maxio.Policy.Store

  alias Maxio.Repo
  alias Maxio.Policy.BucketPolicy

  @impl true
  def get_bucket_policy(bucket) do
    case Repo.get_by(BucketPolicy, bucket_name: bucket) do
      nil -> :none
      %BucketPolicy{document: doc} -> {:ok, Jason.encode!(doc)}
    end
  end

  @impl true
  def put_bucket_policy(bucket, json) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, %{} = doc} ->
        %BucketPolicy{}
        |> BucketPolicy.changeset(%{bucket_name: bucket, document: doc})
        |> Repo.insert(
          on_conflict: {:replace, [:document, :updated_at]},
          conflict_target: :bucket_name
        )
        |> case do
          {:ok, _} -> :ok
          {:error, cs} -> {:error, cs}
        end

      _ ->
        {:error, :malformed}
    end
  end

  @impl true
  def delete_bucket_policy(bucket) do
    import Ecto.Query
    Repo.delete_all(from p in BucketPolicy, where: p.bucket_name == ^bucket)
    :ok
  end

  @impl true
  def principal_policies(_principal), do: []
end
