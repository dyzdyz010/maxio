defmodule Maxio.S3.Dispatcher do
  @moduledoc """
  动作分发判定表（S3 是 RPC over query-string，Router 表达不了 ?uploads vs ?acl）。
  resolve(level, method, query_keys) -> {:ok, action} | {:error, :method_not_allowed | :not_implemented}。
  query_keys: MapSet of 出现的子资源 query key（已小写）。
  M1 支持：list_buckets / create_bucket / delete_bucket / head_bucket / list_objects_v2 /
  get_bucket_location / put_object / get_object / head_object / delete_object。
  其余（multipart / delete-objects / acl / tagging / versioning ...）→ :not_implemented（M2+）。
  """

  @type level :: :service | :bucket | :object
  @type action :: atom()

  # M2+ 子资源标记（出现即 not_implemented）
  @m2_subresources ~w(uploads uploadid delete acl tagging versioning cors policy lifecycle website
                      versions notification replication encryption object-lock legal-hold retention
                      attributes select torrent restore accelerate analytics inventory metrics
                      ownershipcontrols publicaccessblock requestpayment logging partnumber)

  @spec resolve(level(), String.t(), MapSet.t()) ::
          {:ok, action()} | {:error, :method_not_allowed | :not_implemented}
  def resolve(level, method, query_keys) do
    cond do
      m2_subresource?(query_keys) ->
        {:error, :not_implemented}

      level == :bucket and method == "GET" and MapSet.member?(query_keys, "location") ->
        {:ok, :get_bucket_location}

      true ->
        dispatch(level, method)
    end
  end

  defp m2_subresource?(query_keys) do
    Enum.any?(@m2_subresources, &MapSet.member?(query_keys, &1))
  end

  # ── M1 动作表 ──
  defp dispatch(:service, "GET"), do: {:ok, :list_buckets}

  defp dispatch(:bucket, "PUT"), do: {:ok, :create_bucket}
  defp dispatch(:bucket, "DELETE"), do: {:ok, :delete_bucket}
  defp dispatch(:bucket, "HEAD"), do: {:ok, :head_bucket}
  defp dispatch(:bucket, "GET"), do: {:ok, :list_objects_v2}

  defp dispatch(:object, "PUT"), do: {:ok, :put_object}
  defp dispatch(:object, "GET"), do: {:ok, :get_object}
  defp dispatch(:object, "HEAD"), do: {:ok, :head_object}
  defp dispatch(:object, "DELETE"), do: {:ok, :delete_object}

  defp dispatch(_level, _method), do: {:error, :method_not_allowed}
end
