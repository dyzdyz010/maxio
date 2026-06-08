defmodule Maxio.S3.Handlers.Acl do
  @moduledoc """
  ?acl 子资源 handler：GetBucketAcl/PutBucketAcl/GetObjectAcl/PutObjectAcl。
  Get → AccessControlPolicy XML（canned 展开）。Put → 接受 x-amz-acl 头或 XML body（互斥），
  归一化为 canned 名存元数据。email grantee → 400 InvalidArgument（defer）。
  """
  import Plug.Conn
  alias Maxio.{Buckets, Objects}
  alias Maxio.Policy.ACL
  alias Maxio.S3.{Error, Log}
  alias Maxio.S3.Views.AccessControlPolicy, as: AclView
  alias Maxio.S3.RequestParsers.AccessControlPolicy, as: AclParser

  @owner_id "maxio"
  @owner_display "maxio"
  @acl_limit 1_048_576

  @spec get_bucket_acl(Plug.Conn.t()) :: Plug.Conn.t()
  def get_bucket_acl(conn) do
    bucket = conn.assigns.s3_bucket
    b = ensure_bucket!(bucket)
    render_acl(conn, b.acl_canned)
  end

  @spec put_bucket_acl(Plug.Conn.t()) :: Plug.Conn.t()
  def put_bucket_acl(conn) do
    bucket = conn.assigns.s3_bucket
    _ = ensure_bucket!(bucket)
    {conn, canned} = resolve_canned!(conn)
    :ok = Buckets.put_acl(bucket, canned)
    Log.info("put bucket acl", action: :put_bucket_acl, bucket: bucket, reason: canned)
    send_resp(conn, 200, "")
  end

  @spec get_object_acl(Plug.Conn.t()) :: Plug.Conn.t()
  def get_object_acl(conn) do
    bucket = conn.assigns.s3_bucket
    key = conn.assigns.s3_key
    _ = ensure_bucket!(bucket)

    case Objects.get_metadata(bucket, key) do
      {:ok, obj} -> render_acl(conn, obj.acl_canned)
      {:error, :not_found} -> raise Error.new(:no_such_key, resource: "/#{bucket}/#{key}")
    end
  end

  @spec put_object_acl(Plug.Conn.t()) :: Plug.Conn.t()
  def put_object_acl(conn) do
    bucket = conn.assigns.s3_bucket
    key = conn.assigns.s3_key
    _ = ensure_bucket!(bucket)
    {conn, canned} = resolve_canned!(conn)

    case Objects.put_acl(bucket, key, canned) do
      :ok ->
        Log.info("put object acl", action: :put_object_acl, bucket: bucket, key: key, reason: canned)
        send_resp(conn, 200, "")

      {:error, :not_found} ->
        raise Error.new(:no_such_key, resource: "/#{bucket}/#{key}")
    end
  end

  # ── helpers ──
  defp render_acl(conn, canned) do
    body = AclView.render(%{canned: canned, owner_id: @owner_id, owner_display: @owner_display})

    conn
    |> put_resp_content_type("application/xml")
    |> send_resp(200, body)
  end

  # 归一化 ACL 输入为 canned 名。x-amz-acl 头与 XML body 互斥（官方）。
  # 头优先；无头则读 XML body 分类；email grantee → 400。
  defp resolve_canned!(conn) do
    header_acl = header(conn, "x-amz-acl")

    cond do
      is_binary(header_acl) ->
        unless ACL.known?(header_acl) do
          raise Error.new(:invalid_argument, message: "Unsupported x-amz-acl: #{header_acl}")
        end

        {conn, header_acl}

      grant_headers?(conn) ->
        # x-amz-grant-* 头细粒度评估 defer：接受但退化为 private（不静默放行更多权限）。
        Log.warn("x-amz-grant-* headers not fully evaluated; treated as private", action: :put_acl)
        {conn, "private"}

      true ->
        {conn, xml} = read_small_body!(conn)

        if xml =~ "AmazonCustomerByEmail" or xml =~ "EmailAddress" do
          raise Error.new(:invalid_argument, message: "Email grantee ACLs are not supported")
        end

        case AclParser.parse(xml) do
          {:ok, canned} -> {conn, canned}
          {:error, :malformed_xml} -> raise Error.new(:malformed_xml)
        end
    end
  end

  defp grant_headers?(conn) do
    Enum.any?(conn.req_headers, fn {k, _} ->
      String.starts_with?(String.downcase(k), "x-amz-grant-")
    end)
  end

  defp ensure_bucket!(bucket) do
    case Buckets.lookup(bucket) do
      {:ok, b} -> b
      {:error, :not_found} -> raise Error.new(:no_such_bucket, resource: "/" <> bucket)
    end
  end

  defp read_small_body!(conn) do
    case read_body(conn, length: @acl_limit, read_length: @acl_limit) do
      {:ok, body, conn} -> {conn, body}
      {:more, _partial, _conn} -> raise Error.new(:entity_too_large, message: "ACL document too large")
      {:error, _} -> raise Error.new(:malformed_xml)
    end
  end

  defp header(conn, name), do: conn |> get_req_header(name) |> List.first()
end
