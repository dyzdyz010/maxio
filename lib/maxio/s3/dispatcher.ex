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

  # M2+ 子资源标记（出现即 not_implemented）。
  # 注：uploads/uploadid/partnumber 已从本表移除，由 multipart_action/3 分发到具体 multipart 动作（M2-5）。
  @m2_subresources ~w(acl tagging versioning cors policy lifecycle website
                      versions notification replication encryption object-lock legal-hold retention
                      attributes select torrent restore accelerate analytics inventory metrics
                      ownershipcontrols publicaccessblock requestpayment logging)

  @spec resolve(level(), String.t(), MapSet.t()) ::
          {:ok, action()} | {:error, :method_not_allowed | :not_implemented}
  def resolve(level, method, query_keys) do
    cond do
      multipart_action(level, method, query_keys) != nil ->
        {:ok, multipart_action(level, method, query_keys)}

      level == :bucket and method == "POST" and MapSet.member?(query_keys, "delete") ->
        {:ok, :delete_objects}

      m2_subresource?(query_keys) ->
        {:error, :not_implemented}

      level == :bucket and method == "GET" and MapSet.member?(query_keys, "location") ->
        {:ok, :get_bucket_location}

      true ->
        dispatch(level, method)
    end
  end

  # multipart 子资源分发（nil = 非 multipart）。query key 已小写。
  defp multipart_action(:object, "POST", qk) do
    cond do
      MapSet.member?(qk, "uploads") -> :create_multipart_upload
      MapSet.member?(qk, "uploadid") -> :complete_multipart_upload
      true -> nil
    end
  end

  defp multipart_action(:object, "PUT", qk) do
    if MapSet.member?(qk, "partnumber") and MapSet.member?(qk, "uploadid"),
      do: :upload_part,
      else: nil
  end

  defp multipart_action(:object, "DELETE", qk) do
    if MapSet.member?(qk, "uploadid"), do: :abort_multipart_upload, else: nil
  end

  defp multipart_action(:object, "GET", qk) do
    if MapSet.member?(qk, "uploadid"), do: :list_parts, else: nil
  end

  defp multipart_action(:bucket, "GET", qk) do
    if MapSet.member?(qk, "uploads"), do: :list_multipart_uploads, else: nil
  end

  defp multipart_action(_level, _method, _qk), do: nil

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
