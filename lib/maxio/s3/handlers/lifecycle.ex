defmodule Maxio.S3.Handlers.Lifecycle do
  @moduledoc """
  ?lifecycle 子资源 handler：PutBucketLifecycleConfiguration（XML → 校验 → 存，200）、
  GetBucketLifecycleConfiguration（200+XML，无→404 NoSuchLifecycleConfiguration）、
  DeleteBucketLifecycle（204）。

  ⚠️ 仅存储 + 校验 + 出站；后台过期执行 DEFER（未实现，见 README + mix maxio.lifecycle.run stub）。
  校验：每 rule 必须有 Status（Enabled|Disabled）；Expiration 不能同时 Days+Date；
  ExpiredObjectDeleteMarker 不能与 Days/Date 共存；≤1000 rule。违反 → MalformedXML/InvalidRequest 400。
  Transition/NoncurrentVersionTransition 单层 maxio 接受持久化但 no-op（文档化）。
  """
  import Plug.Conn
  alias Maxio.{Buckets, BucketConfigs}
  alias Maxio.S3.{Error, Log}
  alias Maxio.S3.RequestParsers.Lifecycle, as: Parser
  alias Maxio.S3.Views.Lifecycle, as: View

  @limit 1_048_576

  @spec put(Plug.Conn.t()) :: Plug.Conn.t()
  def put(conn) do
    bucket = conn.assigns.s3_bucket
    _ = ensure_bucket!(bucket)
    {conn, xml} = read_small_body!(conn)

    case Parser.parse(xml) do
      {:ok, rules} ->
        :ok = validate!(rules)
        :ok = BucketConfigs.put(bucket, :lifecycle, rules)

        Log.warn(
          "put bucket lifecycle (config stored; expiration execution NOT implemented — defer)",
          action: :put_bucket_lifecycle,
          bucket: bucket,
          reason: :execution_deferred
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
    :ok = BucketConfigs.delete(bucket, :lifecycle)
    Log.info("delete bucket lifecycle", action: :delete_bucket_lifecycle, bucket: bucket)
    send_resp(conn, 204, "")
  end

  # ── 校验 ──
  defp validate!(rules) do
    cond do
      length(rules) > 1000 ->
        raise Error.new(:invalid_request, message: "Too many lifecycle rules (max 1000)")

      Enum.all?(rules, &valid_rule?/1) ->
        :ok

      true ->
        raise Error.new(:malformed_xml, message: "Invalid lifecycle rule")
    end
  end

  defp valid_rule?(r) do
    status_ok = r["status"] in ["Enabled", "Disabled"]
    not_both_days_date = not (r["expiration_days"] != nil and r["expiration_date"] != nil)

    eodm_exclusive =
      if r["expired_object_delete_marker"] == true do
        r["expiration_days"] == nil and r["expiration_date"] == nil
      else
        true
      end

    status_ok and not_both_days_date and eodm_exclusive
  end

  defp ensure_bucket!(bucket) do
    case Buckets.lookup(bucket) do
      {:ok, b} -> b
      {:error, :not_found} -> raise Error.new(:no_such_bucket, resource: "/" <> bucket)
    end
  end

  defp read_small_body!(conn) do
    case read_body(conn, length: @limit, read_length: @limit) do
      {:ok, body, conn} ->
        {conn, body}

      {:more, _partial, _conn} ->
        raise Error.new(:malformed_xml, message: "Lifecycle config too large")

      {:error, _} ->
        raise Error.new(:malformed_xml)
    end
  end
end
