defmodule Maxio.S3.Handlers.Tagging do
  @moduledoc """
  ?tagging 子资源 handler：Put/Get/Delete Object/BucketTagging。
  Put：XML body → 解析 → Maxio.Tags.validate（InvalidTag 400）→ 存（覆盖整集）。
  对象 Put 200；对象 Delete 204；桶 Put 204；Get 200 + Tagging XML。?versionId 作用于指定版本（对象）。
  XML body 走带上限整读（铁律 4）。
  """
  import Plug.Conn
  alias Maxio.{Buckets, Objects, Tags}
  alias Maxio.S3.{Authz, Error, Log}
  alias Maxio.S3.RequestParsers.Tagging, as: Parser
  alias Maxio.S3.Views.Tagging, as: View
  alias Maxio.Versioning.VersionId

  @limit 1_048_576

  # ── Object ──
  @spec put_object_tagging(Plug.Conn.t()) :: Plug.Conn.t()
  def put_object_tagging(conn) do
    {bucket, key, vid, conn} = obj_ctx(conn)
    {conn, xml} = read_small_body!(conn)
    tags = parse_validate!(xml, :object)
    :ok = Authz.authorize_put_object_tagging(conn, bucket, key, vid, tags)

    case Objects.put_tags(bucket, key, tags, vid) do
      :ok ->
        Log.info("put object tagging", action: :put_object_tagging, bucket: bucket, key: key)
        conn |> maybe_vid(vid) |> send_resp(200, "")

      {:error, :not_found} ->
        raise Error.new(:no_such_key, resource: "/#{bucket}/#{key}")
    end
  end

  @spec get_object_tagging(Plug.Conn.t()) :: Plug.Conn.t()
  def get_object_tagging(conn) do
    {bucket, key, vid, conn} = obj_ctx(conn)

    case Objects.get_tags(bucket, key, vid) do
      {:ok, tags} ->
        conn
        |> maybe_vid(vid)
        |> put_resp_content_type("application/xml")
        |> send_resp(200, View.render(tags))

      {:error, :not_found} ->
        raise Error.new(:no_such_key, resource: "/#{bucket}/#{key}")
    end
  end

  @spec delete_object_tagging(Plug.Conn.t()) :: Plug.Conn.t()
  def delete_object_tagging(conn) do
    {bucket, key, vid, conn} = obj_ctx(conn)

    case Objects.put_tags(bucket, key, [], vid) do
      :ok ->
        Log.info("delete object tagging",
          action: :delete_object_tagging,
          bucket: bucket,
          key: key
        )

        conn |> maybe_vid(vid) |> send_resp(204, "")

      {:error, :not_found} ->
        raise Error.new(:no_such_key, resource: "/#{bucket}/#{key}")
    end
  end

  # ── Bucket ──
  @spec put_bucket_tagging(Plug.Conn.t()) :: Plug.Conn.t()
  def put_bucket_tagging(conn) do
    bucket = conn.assigns.s3_bucket
    _ = ensure_bucket!(bucket)
    {conn, xml} = read_small_body!(conn)
    tags = parse_validate!(xml, :bucket)
    :ok = Buckets.put_tags(bucket, tags)
    Log.info("put bucket tagging", action: :put_bucket_tagging, bucket: bucket)
    send_resp(conn, 204, "")
  end

  @spec get_bucket_tagging(Plug.Conn.t()) :: Plug.Conn.t()
  def get_bucket_tagging(conn) do
    bucket = conn.assigns.s3_bucket
    _ = ensure_bucket!(bucket)
    {:ok, tags} = Buckets.get_tags(bucket)

    conn
    |> put_resp_content_type("application/xml")
    |> send_resp(200, View.render(tags))
  end

  @spec delete_bucket_tagging(Plug.Conn.t()) :: Plug.Conn.t()
  def delete_bucket_tagging(conn) do
    bucket = conn.assigns.s3_bucket
    _ = ensure_bucket!(bucket)
    :ok = Buckets.put_tags(bucket, [])
    send_resp(conn, 204, "")
  end

  # ── helpers ──
  defp obj_ctx(conn) do
    bucket = conn.assigns.s3_bucket
    key = conn.assigns.s3_key
    conn = fetch_query_params(conn)
    _ = ensure_bucket!(bucket)

    # B6-2a：tagging 三操作（Get/Put/DeleteObjectTagging 的 ?versionId）接入 B5-4 入口守卫
    # （此前漏接：畸形 versionId 走老路径直达查找层）。空 `?versionId=` 归一化为 absent
    # （= current 版本，AWS/MinIO 语义）；非法形状 → 400 InvalidArgument，先于任何查找。
    # 单一来源 = VersionId.normalize_param/1 + valid?/1（与 Handlers.Object 同源，铁律 2）。
    vid = conn.query_params |> Map.get("versionId") |> VersionId.normalize_param()
    :ok = validate_version_id!(bucket, key, vid)
    {bucket, key, vid, conn}
  end

  # B5-4/B6-2a —— 客户端 ?versionId 入口守卫（与 Handlers.Object.validate_version_id!/3 同构）：
  # 单一事实来源 = VersionId.valid?/1，handler 仅做错误映射——非法形状 → 400 InvalidArgument
  # "Invalid version id specified"（对齐 AWS/MinIO ErrInvalidVersionID，逐字）。
  defp validate_version_id!(_bucket, _key, nil), do: :ok

  defp validate_version_id!(bucket, key, version_id) do
    if VersionId.valid?(version_id) do
      :ok
    else
      raise Error.new(:invalid_argument,
              message: "Invalid version id specified",
              resource: "/#{bucket}/#{key}"
            )
    end
  end

  defp parse_validate!(xml, scope) do
    case Parser.parse(xml) do
      {:ok, tags} ->
        case Tags.validate(tags, scope) do
          :ok -> tags
          {:error, :invalid_tag} -> raise Error.new(:invalid_tag)
        end

      {:error, :malformed_xml} ->
        raise Error.new(:malformed_xml)
    end
  end

  defp maybe_vid(conn, nil), do: conn
  defp maybe_vid(conn, "null"), do: conn
  defp maybe_vid(conn, vid), do: put_resp_header(conn, "x-amz-version-id", vid)

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
        raise Error.new(:entity_too_large, message: "Tagging document too large")

      {:error, _} ->
        raise Error.new(:malformed_xml)
    end
  end
end
