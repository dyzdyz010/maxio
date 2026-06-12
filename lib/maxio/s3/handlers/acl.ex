defmodule Maxio.S3.Handlers.Acl do
  @moduledoc """
  ?acl 子资源 handler：GetBucketAcl/PutBucketAcl/GetObjectAcl/PutObjectAcl。
  Get → AccessControlPolicy XML（canned 或显式 grants 展开）。Put → 接受 x-amz-acl 头、
  x-amz-grant-* 头或 XML body（互斥），归一化为 ACL 元数据。email grantee → 400 InvalidArgument。
  """
  import Plug.Conn
  alias Maxio.{Buckets, ObjectAclSidecar, ObjectMeta, Objects}
  alias Maxio.Policy.ACL
  alias Maxio.Versioning.VersionId
  alias Maxio.S3.{Error, Log, PublicAccessBlock}
  alias Maxio.S3.Views.AccessControlPolicy, as: AclView
  alias Maxio.S3.RequestParsers.AccessControlPolicy, as: AclParser

  @owner_id "maxio"
  @owner_display "maxio"
  @acl_limit 1_048_576

  @spec get_bucket_acl(Plug.Conn.t()) :: Plug.Conn.t()
  def get_bucket_acl(conn) do
    bucket = conn.assigns.s3_bucket
    b = ensure_bucket!(bucket)
    render_acl(conn, b.acl_canned, b.acl_grants)
  end

  @spec put_bucket_acl(Plug.Conn.t()) :: Plug.Conn.t()
  def put_bucket_acl(conn) do
    bucket = conn.assigns.s3_bucket
    _ = ensure_bucket!(bucket)
    {conn, %{canned: canned, grants_doc: grants_doc}} = resolve_acl!(conn)

    :ok =
      PublicAccessBlock.reject_public_acl_write!(bucket, %{canned: canned, grants_doc: grants_doc})

    :ok = Buckets.put_acl(bucket, canned, grants_doc)
    Log.info("put bucket acl", action: :put_bucket_acl, bucket: bucket, reason: canned)
    send_resp(conn, 200, "")
  end

  @spec get_object_acl(Plug.Conn.t()) :: Plug.Conn.t()
  def get_object_acl(conn) do
    conn = fetch_query_params(conn)
    bucket = conn.assigns.s3_bucket
    key = conn.assigns.s3_key
    version_id = version_id!(conn, bucket, key)
    _ = ensure_bucket!(bucket)

    case object_for_acl(bucket, key, version_id) do
      %Objects.Object{} = obj -> render_acl(conn, obj.acl_canned, obj.acl_grants)
      {:error, :not_found} -> raise Error.new(:no_such_key, resource: "/#{bucket}/#{key}")
      {:error, :read_quorum} -> raise Error.new(:slow_down_read, resource: "/#{bucket}/#{key}")
    end
  end

  @spec put_object_acl(Plug.Conn.t()) :: Plug.Conn.t()
  def put_object_acl(conn) do
    conn = fetch_query_params(conn)
    bucket = conn.assigns.s3_bucket
    key = conn.assigns.s3_key
    version_id = version_id!(conn, bucket, key)
    _ = ensure_bucket!(bucket)
    {conn, %{canned: canned, grants_doc: grants_doc}} = resolve_acl!(conn)

    :ok =
      PublicAccessBlock.reject_public_acl_write!(bucket, %{canned: canned, grants_doc: grants_doc})

    commit_result =
      Maxio.Lock.with_object_lock({bucket, key}, fn ->
        target = object_for_acl!(bucket, key, version_id)
        commit_object_acl!(bucket, key, target.version_id, canned, grants_doc)
      end)

    case commit_result do
      {:ok, :ok} ->
        Log.info("put object acl",
          action: :put_object_acl,
          bucket: bucket,
          key: key,
          reason: canned
        )

        send_resp(conn, 200, "")

      {:error, :locked} ->
        raise Error.new(:request_timeout, resource: "/#{bucket}/#{key}")
    end
  end

  # ── helpers ──
  defp object_for_acl(bucket, key, version_id) do
    case ObjectMeta.get(bucket, key, version_id, []) do
      %Objects.Object{} = obj -> obj
      {:error, :not_found} -> {:error, :not_found}
      {:error, :read_quorum} -> {:error, :read_quorum}
    end
  end

  defp object_for_acl!(bucket, key, version_id) do
    case object_for_acl(bucket, key, version_id) do
      %Objects.Object{is_delete_marker: true} ->
        raise Error.new(:no_such_key, resource: "/#{bucket}/#{key}")

      %Objects.Object{} = obj ->
        obj

      {:error, :not_found} ->
        raise Error.new(:no_such_key, resource: "/#{bucket}/#{key}")

      {:error, :read_quorum} ->
        raise Error.new(:slow_down_read, resource: "/#{bucket}/#{key}")
    end
  end

  defp commit_object_acl!(bucket, key, version_id, canned, grants_doc) do
    case ObjectMeta.authoritative_source(:write) do
      :sidecar -> commit_object_acl_sidecar!(bucket, key, version_id, canned, grants_doc)
      _pg -> commit_object_acl_pg!(bucket, key, version_id, canned, grants_doc)
    end
  end

  defp commit_object_acl_sidecar!(bucket, key, version_id, canned, grants_doc) do
    case ObjectAclSidecar.update(bucket, key, version_id, canned, grants_doc) do
      {:ok, generation} ->
        best_effort_object_acl_index_update(
          bucket,
          key,
          version_id,
          canned,
          grants_doc,
          generation
        )

      {:error, :not_found} ->
        raise Error.new(:no_such_key, resource: "/#{bucket}/#{key}")

      {:error, :read_quorum} ->
        raise Error.new(:slow_down_read, resource: "/#{bucket}/#{key}")

      {:error, reason} when reason in [:write_quorum, :no_topology] ->
        raise Error.new(:slow_down_write, resource: "/#{bucket}/#{key}")

      {:error, :invalid_key} ->
        raise Error.new(:invalid_object_name, resource: "/#{bucket}/#{key}")
    end
  end

  defp commit_object_acl_pg!(bucket, key, version_id, canned, grants_doc) do
    case Objects.put_acl_version(bucket, key, version_id, canned, grants_doc) do
      :ok ->
        mirror_object_acl_sidecar(bucket, key, version_id, canned, grants_doc)
        :ok

      {:error, :not_found} ->
        raise Error.new(:no_such_key, resource: "/#{bucket}/#{key}")
    end
  end

  defp best_effort_object_acl_index_update(
         bucket,
         key,
         version_id,
         canned,
         grants_doc,
         generation
       ) do
    case Objects.put_acl_version(bucket, key, version_id, canned, grants_doc, generation) do
      :ok ->
        :ok

      {:error, reason} ->
        Log.error("pg index acl update failed (object ACL durably stored in sidecar)",
          action: :put_object_acl,
          bucket: bucket,
          key: key,
          reason: inspect(reason)
        )

        :ok
    end
  end

  defp mirror_object_acl_sidecar(bucket, key, version_id, canned, grants_doc) do
    try do
      case ObjectAclSidecar.update(bucket, key, version_id, canned, grants_doc) do
        {:ok, generation} ->
          case Objects.put_acl_version(bucket, key, version_id, canned, grants_doc, generation) do
            :ok ->
              :ok

            {:error, reason} ->
              Log.warn("pg acl generation sync failed after sidecar mirror",
                action: :put_object_acl,
                bucket: bucket,
                key: key,
                reason: inspect(reason)
              )
          end

        {:error, reason} ->
          Log.warn("sidecar acl mirror failed (PG remains authoritative)",
            action: :put_object_acl,
            bucket: bucket,
            key: key,
            reason: inspect(reason)
          )
      end
    rescue
      e ->
        Log.warn("sidecar acl mirror raised (PG remains authoritative)",
          action: :put_object_acl,
          bucket: bucket,
          key: key,
          reason: inspect(e)
        )
    catch
      kind, reason ->
        Log.warn("sidecar acl mirror caught (PG remains authoritative)",
          action: :put_object_acl,
          bucket: bucket,
          key: key,
          reason: inspect({kind, reason})
        )
    end
  end

  defp render_acl(conn, canned, grants_doc) do
    bucket = conn.assigns.s3_bucket
    {canned, grants_doc} = PublicAccessBlock.effective_acl(bucket, canned, grants_doc)

    body =
      AclView.render(%{
        canned: canned,
        grants: grants_doc,
        owner_id: @owner_id,
        owner_display: @owner_display
      })

    conn
    |> put_resp_content_type("application/xml")
    |> send_resp(200, body)
  end

  # 归一化 ACL 输入。x-amz-acl / x-amz-grant-* / XML body 三类输入互斥。
  defp resolve_acl!(conn) do
    header_acl = header(conn, "x-amz-acl")
    grant_headers? = ACL.grant_headers?(conn.req_headers)

    cond do
      is_binary(header_acl) and grant_headers? ->
        raise Error.new(:invalid_request,
                message: "Cannot specify both x-amz-acl and x-amz-grant-*"
              )

      is_binary(header_acl) ->
        unless ACL.known?(header_acl) do
          raise Error.new(:invalid_argument, message: "Unsupported x-amz-acl: #{header_acl}")
        end

        {conn, %{canned: header_acl, grants_doc: ACL.empty_grants_doc()}}

      grant_headers? ->
        reject_grant_headers_with_body!(conn)

        grants =
          conn.req_headers
          |> parse_grant_headers!()
          |> ACL.drop_owner_grants(@owner_id)

        canned = ACL.classify_grants(grants)
        {conn, %{canned: canned, grants_doc: ACL.grants_doc(grants)}}

      true ->
        {conn, xml} = read_small_body!(conn)

        case AclParser.parse_grants(xml) do
          {:ok, grants} ->
            grants = ACL.drop_owner_grants(grants, @owner_id)
            canned = ACL.classify_grants(grants)
            {conn, %{canned: canned, grants_doc: ACL.grants_doc(grants)}}

          {:error, :unsupported_email} ->
            raise Error.new(:invalid_argument, message: "Email grantee ACLs are not supported")

          {:error, :invalid_grant} ->
            raise Error.new(:invalid_argument, message: "Invalid ACL grant")

          {:error, :too_many_grants} ->
            raise Error.new(:invalid_argument, message: "ACL can contain at most 100 grants")

          {:error, :malformed_xml} ->
            raise Error.new(:malformed_xml)
        end
    end
  end

  defp parse_grant_headers!(headers) do
    case ACL.parse_grant_headers(headers) do
      {:ok, grants} ->
        grants

      {:error, :unsupported_email} ->
        raise Error.new(:invalid_argument, message: "Email grantee ACLs are not supported")

      {:error, :too_many_grants} ->
        raise Error.new(:invalid_argument, message: "ACL can contain at most 100 grants")

      {:error, :invalid_grant} ->
        raise Error.new(:invalid_argument, message: "Invalid ACL grant")
    end
  end

  defp reject_grant_headers_with_body!(conn) do
    if not body_empty?(conn) do
      raise Error.new(:invalid_request, message: "Cannot specify x-amz-grant-* with ACL XML body")
    end
  end

  defp body_empty?(conn) do
    case get_req_header(conn, "content-length") do
      [] -> true
      ["0"] -> true
      _ -> false
    end
  end

  defp ensure_bucket!(bucket) do
    case Buckets.lookup(bucket) do
      {:ok, b} -> b
      {:error, :not_found} -> raise Error.new(:no_such_bucket, resource: "/" <> bucket)
    end
  end

  defp read_small_body!(conn) do
    case read_body(conn, length: @acl_limit, read_length: @acl_limit) do
      {:ok, body, conn} ->
        {conn, body}

      {:more, _partial, _conn} ->
        raise Error.new(:entity_too_large, message: "ACL document too large")

      {:error, _} ->
        raise Error.new(:malformed_xml)
    end
  end

  defp header(conn, name), do: conn |> get_req_header(name) |> List.first()

  defp version_id!(conn, bucket, key) do
    version_id =
      conn.query_params
      |> Map.get("versionId")
      |> VersionId.normalize_param()

    if is_nil(version_id) or VersionId.valid?(version_id) do
      version_id
    else
      raise Error.new(:invalid_argument,
              message: "Invalid version id specified",
              resource: "/#{bucket}/#{key}"
            )
    end
  end
end
