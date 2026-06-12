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
  @m2_subresources ~w(website
                      notification replication object-lock legal-hold retention
                      attributes select torrent restore accelerate analytics inventory metrics
                      ownershipcontrols requestpayment logging)

  @spec resolve(level(), String.t(), MapSet.t()) ::
          {:ok, action()} | {:error, :method_not_allowed | :not_implemented}
  def resolve(level, method, query_keys) do
    cond do
      multipart_action(level, method, query_keys) != nil ->
        {:ok, multipart_action(level, method, query_keys)}

      level == :bucket and method == "POST" and MapSet.member?(query_keys, "delete") ->
        {:ok, :delete_objects}

      level == :bucket and MapSet.member?(query_keys, "policy") ->
        case method do
          "PUT" -> {:ok, :put_bucket_policy}
          "GET" -> {:ok, :get_bucket_policy}
          "DELETE" -> {:ok, :delete_bucket_policy}
          _ -> {:error, :method_not_allowed}
        end

      level == :bucket and MapSet.member?(query_keys, "versioning") ->
        case method do
          "PUT" -> {:ok, :put_bucket_versioning}
          "GET" -> {:ok, :get_bucket_versioning}
          _ -> {:error, :method_not_allowed}
        end

      level == :bucket and method == "GET" and MapSet.member?(query_keys, "versions") ->
        {:ok, :list_object_versions}

      level == :bucket and MapSet.member?(query_keys, "encryption") ->
        case method do
          "PUT" -> {:ok, :put_bucket_encryption}
          "GET" -> {:ok, :get_bucket_encryption}
          "DELETE" -> {:ok, :delete_bucket_encryption}
          _ -> {:error, :method_not_allowed}
        end

      level == :bucket and MapSet.member?(query_keys, "publicaccessblock") ->
        case method do
          "PUT" -> {:ok, :put_public_access_block}
          "GET" -> {:ok, :get_public_access_block}
          "DELETE" -> {:ok, :delete_public_access_block}
          _ -> {:error, :method_not_allowed}
        end

      MapSet.member?(query_keys, "publicaccessblock") ->
        {:error, :method_not_allowed}

      level == :bucket and MapSet.member?(query_keys, "lifecycle") ->
        case method do
          "PUT" -> {:ok, :put_bucket_lifecycle}
          "GET" -> {:ok, :get_bucket_lifecycle}
          "DELETE" -> {:ok, :delete_bucket_lifecycle}
          _ -> {:error, :method_not_allowed}
        end

      level == :bucket and MapSet.member?(query_keys, "cors") ->
        case method do
          "PUT" -> {:ok, :put_bucket_cors}
          "GET" -> {:ok, :get_bucket_cors}
          "DELETE" -> {:ok, :delete_bucket_cors}
          _ -> {:error, :method_not_allowed}
        end

      MapSet.member?(query_keys, "tagging") ->
        case {level, method} do
          {:object, "PUT"} -> {:ok, :put_object_tagging}
          {:object, "GET"} -> {:ok, :get_object_tagging}
          {:object, "DELETE"} -> {:ok, :delete_object_tagging}
          {:bucket, "PUT"} -> {:ok, :put_bucket_tagging}
          {:bucket, "GET"} -> {:ok, :get_bucket_tagging}
          {:bucket, "DELETE"} -> {:ok, :delete_bucket_tagging}
          _ -> {:error, :method_not_allowed}
        end

      MapSet.member?(query_keys, "acl") ->
        case {level, method} do
          {:bucket, "GET"} -> {:ok, :get_bucket_acl}
          {:bucket, "PUT"} -> {:ok, :put_bucket_acl}
          {:object, "GET"} -> {:ok, :get_object_acl}
          {:object, "PUT"} -> {:ok, :put_object_acl}
          _ -> {:error, :method_not_allowed}
        end

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
