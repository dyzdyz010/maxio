defmodule Maxio.Console.Stats do
  @moduledoc """
  Console Dashboard 廉价聚合（直接 Repo 聚合，无 Prometheus；时序/流量 defer 见计划）。
  object_count/total_size 只算当前版本（is_latest=true 且非 delete marker），与 ListObjectsV2 口径一致。
  """
  import Ecto.Query
  alias Maxio.Repo
  alias Maxio.Buckets.Bucket
  alias Maxio.Objects.Object
  alias Maxio.Multipart.Upload

  @type t :: %{
          bucket_count: non_neg_integer(),
          object_count: non_neg_integer(),
          total_size: non_neg_integer(),
          access_key_count: non_neg_integer(),
          multipart_count: non_neg_integer(),
          per_bucket: [
            %{name: String.t(), object_count: non_neg_integer(), size: non_neg_integer()}
          ]
        }

  @doc "汇总 Dashboard 所需全部计数。"
  @spec dashboard() :: t()
  def dashboard do
    current = from o in Object, where: o.is_latest == true and o.is_delete_marker == false

    %{
      bucket_count: Repo.aggregate(Bucket, :count, :id),
      object_count: Repo.aggregate(current, :count, :id),
      total_size: Repo.aggregate(current, :sum, :size) || 0,
      access_key_count: length(Maxio.IAM.list_access_keys()),
      multipart_count: Repo.aggregate(Upload, :count, :id),
      per_bucket: per_bucket()
    }
  end

  defp per_bucket do
    from(o in Object,
      where: o.is_latest == true and o.is_delete_marker == false,
      group_by: o.bucket_name,
      select: %{
        name: o.bucket_name,
        object_count: count(o.id),
        size: coalesce(sum(o.size), 0)
      },
      order_by: [asc: o.bucket_name]
    )
    |> Repo.all()
  end
end
