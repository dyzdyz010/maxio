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
  @m2_subresources ~w(torrent)

  @spec resolve(level(), String.t(), MapSet.t() | map()) ::
          {:ok, action()} | {:error, :method_not_allowed | :not_implemented}
  def resolve(level, method, query_input) do
    query = normalize_query(query_input)
    query_keys = query |> Map.keys() |> MapSet.new()

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

      level == :bucket and MapSet.member?(query_keys, "ownershipcontrols") ->
        case method do
          "PUT" -> {:ok, :put_bucket_ownership_controls}
          "GET" -> {:ok, :get_bucket_ownership_controls}
          "DELETE" -> {:ok, :delete_bucket_ownership_controls}
          _ -> {:error, :method_not_allowed}
        end

      MapSet.member?(query_keys, "ownershipcontrols") ->
        {:error, :method_not_allowed}

      level == :bucket and MapSet.member?(query_keys, "website") ->
        case method do
          "PUT" -> {:ok, :put_bucket_website}
          "GET" -> {:ok, :get_bucket_website}
          "DELETE" -> {:ok, :delete_bucket_website}
          _ -> {:error, :method_not_allowed}
        end

      MapSet.member?(query_keys, "website") ->
        {:error, :method_not_allowed}

      level == :bucket and MapSet.member?(query_keys, "requestpayment") ->
        case method do
          "PUT" -> {:ok, :put_bucket_request_payment}
          "GET" -> {:ok, :get_bucket_request_payment}
          _ -> {:error, :method_not_allowed}
        end

      MapSet.member?(query_keys, "requestpayment") ->
        {:error, :method_not_allowed}

      level == :bucket and MapSet.member?(query_keys, "accelerate") ->
        case method do
          "PUT" -> {:ok, :put_bucket_accelerate_configuration}
          "GET" -> {:ok, :get_bucket_accelerate_configuration}
          _ -> {:error, :method_not_allowed}
        end

      MapSet.member?(query_keys, "accelerate") ->
        {:error, :method_not_allowed}

      level == :bucket and MapSet.member?(query_keys, "logging") ->
        case method do
          "PUT" -> {:ok, :put_bucket_logging}
          "GET" -> {:ok, :get_bucket_logging}
          _ -> {:error, :method_not_allowed}
        end

      MapSet.member?(query_keys, "logging") ->
        {:error, :method_not_allowed}

      level == :bucket and MapSet.member?(query_keys, "notification") ->
        case method do
          "PUT" -> {:ok, :put_bucket_notification}
          "GET" -> {:ok, :get_bucket_notification}
          _ -> {:error, :method_not_allowed}
        end

      MapSet.member?(query_keys, "notification") ->
        {:error, :method_not_allowed}

      level == :bucket and MapSet.member?(query_keys, "metrics") ->
        case method do
          "PUT" ->
            {:ok, :put_bucket_metrics_configuration}

          "GET" ->
            if Map.has_key?(query, "id"),
              do: {:ok, :get_bucket_metrics_configuration},
              else: {:ok, :list_bucket_metrics_configurations}

          "DELETE" ->
            {:ok, :delete_bucket_metrics_configuration}

          _ ->
            {:error, :method_not_allowed}
        end

      MapSet.member?(query_keys, "metrics") ->
        {:error, :method_not_allowed}

      level == :bucket and MapSet.member?(query_keys, "analytics") ->
        case method do
          "PUT" ->
            {:ok, :put_bucket_analytics_configuration}

          "GET" ->
            if Map.has_key?(query, "id"),
              do: {:ok, :get_bucket_analytics_configuration},
              else: {:ok, :list_bucket_analytics_configurations}

          "DELETE" ->
            {:ok, :delete_bucket_analytics_configuration}

          _ ->
            {:error, :method_not_allowed}
        end

      MapSet.member?(query_keys, "analytics") ->
        {:error, :method_not_allowed}

      level == :bucket and MapSet.member?(query_keys, "inventory") ->
        case method do
          "PUT" ->
            {:ok, :put_bucket_inventory_configuration}

          "GET" ->
            if Map.has_key?(query, "id"),
              do: {:ok, :get_bucket_inventory_configuration},
              else: {:ok, :list_bucket_inventory_configurations}

          "DELETE" ->
            {:ok, :delete_bucket_inventory_configuration}

          _ ->
            {:error, :method_not_allowed}
        end

      MapSet.member?(query_keys, "inventory") ->
        {:error, :method_not_allowed}

      level == :bucket and MapSet.member?(query_keys, "replication") ->
        case method do
          "PUT" -> {:ok, :put_bucket_replication}
          "GET" -> {:ok, :get_bucket_replication}
          "DELETE" -> {:ok, :delete_bucket_replication}
          _ -> {:error, :method_not_allowed}
        end

      MapSet.member?(query_keys, "replication") ->
        {:error, :method_not_allowed}

      level == :bucket and MapSet.member?(query_keys, "object-lock") ->
        case method do
          "PUT" -> {:ok, :put_bucket_object_lock_configuration}
          "GET" -> {:ok, :get_bucket_object_lock_configuration}
          _ -> {:error, :method_not_allowed}
        end

      MapSet.member?(query_keys, "object-lock") ->
        {:error, :method_not_allowed}

      level == :object and MapSet.member?(query_keys, "retention") ->
        case method do
          "PUT" -> {:ok, :put_object_retention}
          "GET" -> {:ok, :get_object_retention}
          _ -> {:error, :method_not_allowed}
        end

      MapSet.member?(query_keys, "retention") ->
        {:error, :method_not_allowed}

      level == :object and MapSet.member?(query_keys, "legal-hold") ->
        case method do
          "PUT" -> {:ok, :put_object_legal_hold}
          "GET" -> {:ok, :get_object_legal_hold}
          _ -> {:error, :method_not_allowed}
        end

      MapSet.member?(query_keys, "legal-hold") ->
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

      MapSet.member?(query_keys, "attributes") ->
        case {level, method} do
          {:object, "GET"} -> {:ok, :get_object_attributes}
          _ -> {:error, :method_not_allowed}
        end

      MapSet.member?(query_keys, "restore") ->
        case {level, method} do
          {:object, "POST"} -> {:ok, :restore_object}
          _ -> {:error, :method_not_allowed}
        end

      MapSet.member?(query_keys, "select") ->
        case {level, method} do
          {:object, "POST"} -> {:ok, :select_object_content}
          _ -> {:error, :method_not_allowed}
        end

      m2_subresource?(query_keys) ->
        {:error, :not_implemented}

      level == :bucket and method == "GET" and MapSet.member?(query_keys, "location") ->
        {:ok, :get_bucket_location}

      level == :bucket and method == "GET" and list_type_v2?(query) ->
        {:ok, :list_objects_v2}

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

  defp normalize_query(%MapSet{} = query_keys) do
    Map.new(query_keys, fn key -> {String.downcase(to_string(key)), ""} end)
  end

  defp normalize_query(query) when is_map(query) do
    Map.new(query, fn {key, value} ->
      {String.downcase(to_string(key)), normalize_query_value(value)}
    end)
  end

  defp normalize_query(_query), do: %{}

  defp normalize_query_value([value | _rest]), do: to_string(value)
  defp normalize_query_value(value) when is_binary(value), do: value
  defp normalize_query_value(value), do: to_string(value)

  defp list_type_v2?(query), do: Map.get(query, "list-type") == "2"

  # ── M1 动作表 ──
  defp dispatch(:service, "GET"), do: {:ok, :list_buckets}

  defp dispatch(:bucket, "PUT"), do: {:ok, :create_bucket}
  defp dispatch(:bucket, "DELETE"), do: {:ok, :delete_bucket}
  defp dispatch(:bucket, "HEAD"), do: {:ok, :head_bucket}
  defp dispatch(:bucket, "GET"), do: {:ok, :list_objects}

  defp dispatch(:object, "PUT"), do: {:ok, :put_object}
  defp dispatch(:object, "GET"), do: {:ok, :get_object}
  defp dispatch(:object, "HEAD"), do: {:ok, :head_object}
  defp dispatch(:object, "DELETE"), do: {:ok, :delete_object}

  defp dispatch(_level, _method), do: {:error, :method_not_allowed}
end
