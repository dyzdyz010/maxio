defmodule Maxio.S3.Handlers.Lifecycle do
  @moduledoc """
  ?lifecycle 子资源 handler：PutBucketLifecycleConfiguration（XML → 校验 → 存，200）、
  GetBucketLifecycleConfiguration（200+XML，无→404 NoSuchLifecycleConfiguration）、
  DeleteBucketLifecycle（204）。

  ⚠️ 本 handler 仅存储 + 校验 + 出站；实际过期/中止 MPU 由 `mix maxio.lifecycle.run`
  或后续后台调度调用 `Maxio.Lifecycle.run/1` 执行。
  校验：至少一个 Rule；每 rule 必须有 Status（Enabled|Disabled）且至少一个 lifecycle action；
  ID 可省略但不能空、不能超过 255 字符、不能重复；legacy Prefix 不能与 Filter 共存；
  Expiration 不能同时 Days+Date；
  ExpiredObjectDeleteMarker 不能与 Days/Date 共存；数值/Tag filter 必须完整且非正数会被拒；
  size filter 同时出现时 GreaterThan 必须小于 LessThan；tag filter 不能用于
  AbortIncompleteMultipartUpload 或 ExpiredObjectDeleteMarker；
  NewerNoncurrentVersions 必须为 1..100 且请求含 Filter；≤1000 rule。违反 → MalformedXML/InvalidRequest 400。
  Transition/NoncurrentVersionTransition 单层 maxio 接受持久化，执行器会更新对象版本的
  S3-visible storage class 元数据；真实 tiering 后端迁移仍显式 defer。
  """
  import Plug.Conn
  alias Maxio.{Buckets, BucketConfigs}
  alias Maxio.S3.{ControlBody, Error, ExpectedBucketOwner, Log, StorageClass}
  alias Maxio.S3.RequestParsers.Lifecycle, as: Parser
  alias Maxio.S3.Views.Lifecycle, as: View

  @limit 1_048_576

  @spec put(Plug.Conn.t()) :: Plug.Conn.t()
  def put(conn) do
    bucket = conn.assigns.s3_bucket
    _ = ensure_bucket!(bucket)
    :ok = ExpectedBucketOwner.verify!(conn, bucket)
    {conn, xml} = read_small_body!(conn)

    case Parser.parse(xml) do
      {:ok, rules} ->
        :ok = validate!(rules)
        :ok = BucketConfigs.put(bucket, :lifecycle, rules)

        Log.info(
          "put bucket lifecycle (config stored; execution handled by lifecycle runner)",
          action: :put_bucket_lifecycle,
          bucket: bucket,
          reason: :runner_required
        )

        send_resp(conn, 200, "")

      {:error, :malformed_xml} ->
        raise Error.new(:malformed_xml, resource: "/" <> bucket)
    end
  end

  @spec get(Plug.Conn.t()) :: Plug.Conn.t()
  def get(conn) do
    bucket = conn.assigns.s3_bucket
    _ = ensure_bucket!(bucket)
    :ok = ExpectedBucketOwner.verify!(conn, bucket)

    case BucketConfigs.get(bucket, :lifecycle) do
      {:ok, rules} ->
        conn |> put_resp_content_type("application/xml") |> send_resp(200, View.render(rules))

      :none ->
        raise Error.new(:no_such_lifecycle_configuration, resource: "/" <> bucket)
    end
  end

  @spec delete(Plug.Conn.t()) :: Plug.Conn.t()
  def delete(conn) do
    bucket = conn.assigns.s3_bucket
    _ = ensure_bucket!(bucket)
    :ok = ExpectedBucketOwner.verify!(conn, bucket)
    :ok = BucketConfigs.delete(bucket, :lifecycle)
    Log.info("delete bucket lifecycle", action: :delete_bucket_lifecycle, bucket: bucket)
    send_resp(conn, 204, "")
  end

  # ── 校验 ──
  @spec validate!(term()) :: :ok
  def validate!(rules) when is_list(rules) do
    cond do
      rules == [] ->
        raise(
          Error.new(:malformed_xml,
            message: "Lifecycle configuration requires at least one rule"
          )
        )

      length(rules) > 1000 ->
        raise Error.new(:invalid_request, message: "Too many lifecycle rules (max 1000)")

      not lifecycle_ids_ok?(rules) ->
        raise Error.new(:malformed_xml, message: "Invalid lifecycle rule ID")

      Enum.all?(rules, &valid_rule?/1) ->
        :ok

      true ->
        raise Error.new(:malformed_xml, message: "Invalid lifecycle rule")
    end
  end

  def validate!(_rules),
    do: raise(Error.new(:malformed_xml, message: "Invalid lifecycle configuration"))

  defp valid_rule?(r) when is_map(r) do
    status_ok = r["status"] in ["Enabled", "Disabled"]
    not_both_days_date = not (r["expiration_days"] != nil and r["expiration_date"] != nil)
    no_parse_errors = (r["parse_errors"] || []) == []
    scalar_fields_ok = scalar_fields_ok?(r)

    eodm_exclusive =
      if r["expired_object_delete_marker"] != nil do
        r["expiration_days"] == nil and r["expiration_date"] == nil
      else
        true
      end

    status_ok and action_configured?(r) and not_both_days_date and eodm_exclusive and
      no_parse_errors and scalar_fields_ok and numbers_ok?(r) and newer_noncurrent_filter_ok?(r) and
      tags_ok?(r) and selector_ok?(r) and size_filter_range_ok?(r) and
      tag_filter_action_ok?(r) and transition_fields_ok?(r)
  end

  defp valid_rule?(_r), do: false

  defp lifecycle_ids_ok?(rules) do
    ids =
      rules
      |> Enum.map(&Map.get(&1, "id"))
      |> Enum.reject(&is_nil/1)

    Enum.all?(ids, fn id -> is_binary(id) and id != "" and String.length(id) <= 255 end) and
      length(ids) == length(Enum.uniq(ids))
  end

  defp action_configured?(r) do
    r["expired_object_delete_marker"] == true or
      Enum.any?(
        ~w(expiration_days expiration_date
           noncurrent_days newer_noncurrent_versions abort_days_after_initiation
           transition_days transition_date transition_storage_class
           noncurrent_transition_days noncurrent_transition_newer_noncurrent_versions
           noncurrent_transition_storage_class),
        fn field -> r[field] != nil and r[field] != "" end
      )
  end

  defp scalar_fields_ok?(r) do
    string_fields =
      ~w(id prefix filter_prefix expiration_date transition_date transition_storage_class
         noncurrent_transition_storage_class)

    Enum.all?(string_fields, &optional_string?(r[&1])) and
      optional_boolean?(r["expired_object_delete_marker"])
  end

  defp optional_string?(nil), do: true
  defp optional_string?(value), do: is_binary(value)

  defp optional_boolean?(nil), do: true
  defp optional_boolean?(value), do: is_boolean(value)

  defp numbers_ok?(r) do
    [
      {"expiration_days", 1, nil},
      {"noncurrent_days", 1, nil},
      {"newer_noncurrent_versions", 1, 100},
      {"abort_days_after_initiation", 1, nil},
      {"transition_days", 0, nil},
      {"noncurrent_transition_days", 0, nil},
      {"noncurrent_transition_newer_noncurrent_versions", 1, 100},
      {"filter_size_gt", 0, nil},
      {"filter_size_lt", 1, nil}
    ]
    |> Enum.all?(fn {field, min, max} -> number_ok?(r[field], min, max) end)
  end

  defp number_ok?(nil, _min, _max), do: true

  defp number_ok?(value, min, nil) when is_integer(value),
    do: value >= min

  defp number_ok?(value, min, max) when is_integer(value),
    do: value >= min and value <= max

  defp number_ok?(_value, _min, _max), do: false

  defp newer_noncurrent_filter_ok?(r) do
    (Map.get(r, "newer_noncurrent_versions") == nil and
       Map.get(r, "noncurrent_transition_newer_noncurrent_versions") == nil) or
      r["has_filter"] == true
  end

  defp selector_ok?(r) do
    cond do
      is_binary(r["prefix"]) and r["has_filter"] == true -> false
      is_binary(r["prefix"]) -> true
      r["has_filter"] == true -> true
      true -> false
    end
  end

  defp size_filter_range_ok?(r) do
    case {r["filter_size_gt"], r["filter_size_lt"]} do
      {gt, lt} when is_integer(gt) and is_integer(lt) -> gt < lt
      _other -> true
    end
  end

  defp tag_filter_action_ok?(r) do
    not (tag_filter?(r) and
           (r["abort_days_after_initiation"] != nil or
              r["expired_object_delete_marker"] != nil))
  end

  defp tags_ok?(r) do
    case r["filter_tags"] || [] do
      tags when is_list(tags) ->
        Enum.all?(tags, fn
          %{"key" => key, "value" => value} when is_binary(key) and is_binary(value) ->
            key != ""

          %{"Key" => key, "Value" => value} when is_binary(key) and is_binary(value) ->
            key != ""

          _other ->
            false
        end)

      _other ->
        false
    end
  end

  defp tag_filter?(r) do
    case r["filter_tags"] || [] do
      tags when is_list(tags) -> tags != []
      _other -> false
    end
  end

  defp transition_fields_ok?(r) do
    current_transition_ok?(r) and noncurrent_transition_ok?(r)
  end

  defp current_transition_ok?(r) do
    configured? =
      r["transition_days"] != nil or r["transition_date"] != nil or
        r["transition_storage_class"] != nil

    cond do
      not configured? ->
        true

      r["transition_days"] != nil and r["transition_date"] != nil ->
        false

      r["transition_days"] == nil and r["transition_date"] in [nil, ""] ->
        false

      true ->
        current_transition_target_ok?(r)
    end
  end

  defp current_transition_target_ok?(r) do
    storage_class = r["transition_storage_class"]

    lifecycle_transition_storage_class_exact?(storage_class) and
      (r["transition_days"] == nil or
         StorageClass.lifecycle_transition_days_valid?(storage_class, r["transition_days"]))
  end

  defp noncurrent_transition_ok?(r) do
    configured? =
      r["noncurrent_transition_days"] != nil or
        r["noncurrent_transition_newer_noncurrent_versions"] != nil or
        r["noncurrent_transition_storage_class"] != nil

    cond do
      not configured? ->
        true

      r["noncurrent_transition_days"] == nil ->
        false

      true ->
        lifecycle_transition_storage_class_exact?(r["noncurrent_transition_storage_class"]) and
          StorageClass.lifecycle_transition_days_valid?(
            r["noncurrent_transition_storage_class"],
            r["noncurrent_transition_days"]
          )
    end
  end

  defp lifecycle_transition_storage_class_exact?(value) when is_binary(value),
    do: value in StorageClass.lifecycle_transition_values()

  defp lifecycle_transition_storage_class_exact?(_value), do: false

  defp ensure_bucket!(bucket) do
    case Buckets.lookup(bucket) do
      {:ok, b} -> b
      {:error, :not_found} -> raise Error.new(:no_such_bucket, resource: "/" <> bucket)
    end
  end

  defp read_small_body!(conn) do
    ControlBody.read_and_verify!(conn, @limit, "Lifecycle config too large")
  end
end
